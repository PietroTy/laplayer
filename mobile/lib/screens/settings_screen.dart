import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../data/services/sync_service.dart';
import '../data/services/manifest_service.dart';
import '../providers/library_provider.dart';
import 'widgets/app_logo.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _spotifyIdCtrl = TextEditingController();
  final _spotifySecretCtrl = TextEditingController();
  final _downloadDirCtrl = TextEditingController();

  // ── Preferências de Download ────────────────────────────────────
  String _audioFormat = 'm4a';
  String _audioQuality = 'high';
  int _concurrency = 3;

  // Formatos disponíveis: id, label, descrição, ícone, tamanho estimado por música (~3 min)
  static const _formats = [
    {'id': 'opus',  'label': 'Opus',  'desc': 'Menor tamanho, ótima qualidade', 'icon': Icons.compress,    'size': '~2–3 MB'},
    {'id': 'm4a',   'label': 'M4A',   'desc': 'Padrão, compatível com tudo',   'icon': Icons.music_note,   'size': '~4–5 MB'},
    {'id': 'mp3',   'label': 'MP3',   'desc': 'Universal, amplo suporte',       'icon': Icons.audio_file,   'size': '~4–6 MB'},
    {'id': 'flac',  'label': 'FLAC',  'desc': 'Lossless, máxima fidelidade',   'icon': Icons.high_quality, 'size': '~25–40 MB'},
  ];

  // Qualidades disponíveis: id, label, descrição
  static const _qualities = [
    {'id': 'low',    'label': 'Econômico', 'desc': '64 kbps',  'icon': Icons.battery_saver},
    {'id': 'medium', 'label': 'Médio',     'desc': '128 kbps', 'icon': Icons.graphic_eq},
    {'id': 'high',   'label': 'Alto',       'desc': '192 kbps', 'icon': Icons.hd},
    {'id': 'best',   'label': 'Máximo',    'desc': 'Original', 'icon': Icons.star},
  ];
 
  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }
 
  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _spotifyIdCtrl.text = prefs.getString('spotify_client_id') ?? '';
    _spotifySecretCtrl.text = prefs.getString('spotify_client_secret') ?? '';

    final customPath = prefs.getString('custom_music_directory') ?? '';
    if (customPath.isNotEmpty) {
      _downloadDirCtrl.text = customPath;
    } else {
      _downloadDirCtrl.text = await AppConstants.getDefaultMusicDirectory();
    }

    _audioFormat = prefs.getString('download_audio_format') ?? 'm4a';
    _audioQuality = prefs.getString('download_audio_quality') ?? 'high';
    _concurrency = prefs.getInt('download_concurrency') ?? 3;
    setState(() {});
  }

  Future<void> _saveDownloadQuality() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('download_audio_format', _audioFormat);
    await prefs.setString('download_audio_quality', _audioQuality);
    await prefs.setInt('download_concurrency', _concurrency);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Preferências de download salvas!'),
          backgroundColor: AppColors.accent,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _saveDownloadDir() async {
    final path = _downloadDirCtrl.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    if (path.isEmpty) {
      await _resetDownloadDir();
      return;
    }
    try {
      // Solicita permissões de armazenamento se for um caminho de armazenamento externo compartilhado
      if (Platform.isAndroid && 
          (path.startsWith('/storage') || path.startsWith('/sdcard') || !path.contains('Android/data'))) {
        PermissionStatus status = PermissionStatus.denied;
        
        // Tenta solicitar o acesso completo aos arquivos (MANAGE_EXTERNAL_STORAGE)
        status = await Permission.manageExternalStorage.request();
        
        // Se não for concedido (ex: em versões antigas do Android), tenta solicitar a permissão de armazenamento padrão
        if (!status.isGranted) {
          status = await Permission.storage.request();
        }

        if (!status.isGranted) {
          if (mounted) {
            messenger.showSnackBar(
              const SnackBar(
                content: Text('Permissão de armazenamento necessária para salvar músicas nesta pasta.'),
                backgroundColor: AppColors.warning,
              ),
            );
          }
          return;
        }
      }

      final dir = Directory(path);
      await dir.create(recursive: true);
      
      final prefs = await SharedPreferences.getInstance();
      final oldPath = prefs.getString('custom_music_directory') ?? '';
      
      // Resolve caminho antigo efetivo
      final oldEffectivePath = oldPath.isNotEmpty 
          ? oldPath 
          : await AppConstants.getDefaultMusicDirectory();

      if (oldEffectivePath != path) {
        if (mounted) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Migrando músicas para a nova pasta...'),
              duration: Duration(seconds: 2),
            ),
          );
        }

        final oldDir = Directory(oldEffectivePath);
        if (await oldDir.exists()) {
          await _copyDirectory(oldDir, dir);
          await _deleteDirectory(oldDir);
        }
      }

      await prefs.setString('custom_music_directory', path);
      
      // Revalida todas as faixas locais com o novo diretório
      await ref.read(syncProvider.notifier).revalidateAllTracks();
      
      if (mounted) {
        setState(() {});
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Diretório de downloads atualizado e músicas migradas!'),
            backgroundColor: AppColors.accent,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Caminho inválido ou sem permissão: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Future<void> _resetDownloadDir() async {
    final messenger = ScaffoldMessenger.of(context);
    final prefs = await SharedPreferences.getInstance();
    final oldPath = prefs.getString('custom_music_directory') ?? '';
    
    final defaultPath = await AppConstants.getDefaultMusicDirectory();
    
    try {
      if (oldPath.isNotEmpty && oldPath != defaultPath) {
        if (mounted) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Restaurando músicas para a pasta padrão...'),
              duration: Duration(seconds: 2),
            ),
          );
        }

        final oldDir = Directory(oldPath);
        if (await oldDir.exists()) {
          await _copyDirectory(oldDir, Directory(defaultPath));
          await _deleteDirectory(oldDir);
        }
      }

      await prefs.remove('custom_music_directory');
      _downloadDirCtrl.text = defaultPath;
      
      // Revalida no banco de dados
      await ref.read(syncProvider.notifier).revalidateAllTracks();

      if (mounted) {
        setState(() {});
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Diretório padrão restaurado e músicas migradas!'),
            backgroundColor: AppColors.accent,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Erro ao restaurar: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(recursive: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        final newDir = Directory(p.join(destination.path, name));
        await _copyDirectory(entity, newDir);
      } else if (entity is File) {
        final newFile = File(p.join(destination.path, name));
        try {
          await entity.copy(newFile.path);
        } catch (e) {
          debugPrint('Erro ao copiar arquivo ${entity.path}: $e');
        }
      }
    }
  }

  Future<void> _deleteDirectory(Directory dir) async {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('Erro ao apagar pasta antiga: $e');
    }
  }

  Future<void> _selectDirectory() async {
    try {
      final String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory != null) {
        setState(() {
          _downloadDirCtrl.text = selectedDirectory;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao abrir seletor de diretório: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('spotify_client_id', _spotifyIdCtrl.text.trim());
    await prefs.setString('spotify_client_secret', _spotifySecretCtrl.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Configurações salvas!'),
          backgroundColor: AppColors.accent,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncProvider);
    final lastSync = ref.watch(_lastSyncProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Configurações'),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text('SALVAR', 
              style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold)
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Spotify ─────────────────────────────────────────────────────
          _Section(
            title: 'Spotify API',
            child: Column(
              children: [
                const Text(
                  'Necessário para sincronizar dados das playlists e descobrir novas músicas.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _spotifyIdCtrl,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Client ID',
                    labelStyle: TextStyle(color: AppColors.textMuted),
                    prefixIcon: Icon(Icons.vpn_key_rounded, color: AppColors.textMuted),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _spotifySecretCtrl,
                  style: const TextStyle(color: AppColors.textPrimary),
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Client Secret',
                    labelStyle: TextStyle(color: AppColors.textMuted),
                    prefixIcon: Icon(Icons.lock_rounded, color: AppColors.textMuted),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── Sincronização ───────────────────────────────────────────────
          _Section(
            title: 'Sincronização',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                lastSync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (dt) => dt != null
                      ? Text(
                          'Último sync: ${_fmtDate(dt)}',
                          style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                        )
                      : const Text(
                          'Nenhum sync realizado ainda.',
                          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                        ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: sync.isLoading
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                        : const Icon(Icons.sync_rounded),
                    label: Text(sync.isLoading ? 'Sincronizando...' : 'Sincronizar tudo'),
                    onPressed: sync.isLoading
                        ? null
                        : () => ref.read(syncProvider.notifier).syncAll().then((_) {
                            ref.invalidate(_lastSyncProvider);
                          }),
                  ),
                ),
                if (sync.isLoading && (sync.message != null && sync.message!.isNotEmpty)) ...[
                  const SizedBox(height: 8),
                  Text(
                     sync.message!,
                     style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── Diretório de Downloads ─────────────────────────────────────────
          _Section(
            title: 'Diretório de Downloads',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Escolha onde salvar as músicas e letras baixadas no celular.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _downloadDirCtrl,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Caminho absoluto do diretório',
                    labelStyle: const TextStyle(color: AppColors.textMuted),
                    hintText: '/storage/emulated/0/Music/la_player',
                    prefixIcon: const Icon(Icons.folder_open_rounded, color: AppColors.textMuted),
                    suffixIcon: IconButton(
                      icon: Icon(Icons.folder_shared_rounded, color: AppColors.accent),
                      tooltip: 'Selecionar Pasta',
                      onPressed: _selectDirectory,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _saveDownloadDir,
                        child: const Text('Salvar'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: _resetDownloadDir,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textSecond,
                        side: const BorderSide(color: AppColors.border),
                      ),
                      child: const Text('Restaurar Padrão'),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── Qualidade de Download ────────────────────────────────────
          _Section(
            title: 'Qualidade de Download',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Escolha o formato e a qualidade das músicas baixadas.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 16),

                // ─ Formato ──────────────────────────────────────────────
                const Text(
                  'FORMATO',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1),
                ),
                const SizedBox(height: 10),
                ...(_formats as List<Map<String, Object>>).map((fmt) {
                  final isSelected = _audioFormat == fmt['id'] as String;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => setState(() => _audioFormat = fmt['id'] as String),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected ? AppColors.accent : AppColors.border,
                            width: isSelected ? 2 : 1,
                          ),
                          color: isSelected ? AppColors.accent.withOpacity(0.08) : Colors.transparent,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              fmt['icon'] as IconData,
                              color: isSelected ? AppColors.accent : AppColors.textMuted,
                              size: 22,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        fmt['label'] as String,
                                        style: TextStyle(
                                          color: isSelected ? AppColors.accent : AppColors.textPrimary,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const Spacer(),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(20),
                                          color: isSelected ? AppColors.accent.withOpacity(0.15) : AppColors.surface,
                                        ),
                                        child: Text(
                                          fmt['size'] as String,
                                          style: TextStyle(
                                            color: isSelected ? AppColors.accent : AppColors.textMuted,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    fmt['desc'] as String,
                                    style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Icon(Icons.check_circle_rounded, color: AppColors.accent, size: 20),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),

                const SizedBox(height: 16),

                // ─ Qualidade (bitrate) ───────────────────────────────────
                const Text(
                  'QUALIDADE (BITRATE)',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1),
                ),
                const SizedBox(height: 10),
                // Nota: qualidade não se aplica ao FLAC (sempre lossless)
                if (_audioFormat == 'flac')
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: AppColors.accent.withOpacity(0.06),
                      border: Border.all(color: AppColors.accent.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline_rounded, color: AppColors.accent, size: 16),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'FLAC é lossless — qualidade sempre máxima.',
                            style: TextStyle(color: AppColors.textSecond, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Row(
                    children: (_qualities as List<Map<String, Object>>).map((q) {
                      final isSelected = _audioQuality == q['id'] as String;
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => setState(() => _audioQuality = q['id'] as String),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isSelected ? AppColors.accent : AppColors.border,
                                  width: isSelected ? 2 : 1,
                                ),
                                color: isSelected ? AppColors.accent.withOpacity(0.08) : Colors.transparent,
                              ),
                              child: Column(
                                children: [
                                  Icon(
                                    q['icon'] as IconData,
                                    color: isSelected ? AppColors.accent : AppColors.textMuted,
                                    size: 18,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    q['label'] as String,
                                    style: TextStyle(
                                      color: isSelected ? AppColors.accent : AppColors.textPrimary,
                                      fontSize: 11,
                                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  Text(
                                    q['desc'] as String,
                                    style: const TextStyle(color: AppColors.textMuted, fontSize: 9),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),

                const SizedBox(height: 20),

                // ─ Downloads em Paralelo ────────────────────────────────
                const Text(
                  'DOWNLOADS EM PARALELO',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.1),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Quantidade de músicas baixadas simultaneamente.',
                            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '$_concurrency downloads simultâneos',
                            style: TextStyle(color: AppColors.accent, fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Seletor de Concorrência
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.border),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_rounded),
                            color: _concurrency > 1 ? Colors.white : Colors.white24,
                            onPressed: _concurrency > 1 ? () => setState(() => _concurrency--) : null,
                          ),
                          Text('$_concurrency', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          IconButton(
                            icon: const Icon(Icons.add_rounded),
                            color: _concurrency < 6 ? Colors.white : Colors.white24,
                            onPressed: _concurrency < 6 ? () => setState(() => _concurrency++) : null,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.save_alt_rounded, size: 18),
                    label: const Text('Salvar Preferências de Download'),
                    onPressed: _saveDownloadQuality,
                  ),
                ),

                // Aviso sobre músicas já baixadas
                const SizedBox(height: 10),
                const Text(
                  '⚠️ Músicas já baixadas não serão refeitas automaticamente.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── Tema Visual ──────────────────────────────────────────────────
          _Section(
            title: 'Tema Visual',
            child: SizedBox(
              height: 80,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: AppThemePalette.values.length,
                itemBuilder: (context, index) {
                  final palette = AppThemePalette.values[index];
                  final currentPalette = ref.watch(themePaletteProvider);
                  final isSelected = currentPalette == palette;
                  return Padding(
                    padding: const EdgeInsets.only(right: 16.0),
                    child: GestureDetector(
                      onTap: () => ref.read(themePaletteProvider.notifier).setTheme(palette),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: palette.bg,
                              border: Border.all(
                                color: isSelected ? palette.accent : AppColors.border,
                                width: isSelected ? 3 : 1.5,
                              ),
                            ),
                            child: Center(
                              child: isSelected
                                  ? Icon(Icons.check_rounded, color: palette.accent, size: 24)
                                  : Container(
                                      width: 20,
                                      height: 20,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: palette.accent,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            palette.name,
                            style: TextStyle(
                              color: isSelected ? AppColors.textPrimary : AppColors.textSecond,
                              fontSize: 10,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),


          const SizedBox(height: 20),

          // ── Backup & Recuperação ──────────────────────────────────────────
          _Section(
            title: 'Backup & Recuperação',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Portabilidade total: seus dados de playlist e arquivos de áudio são mantidos juntos. Salve um manifesto ou restaure tudo a partir de qualquer pasta que já possua músicas.',
                  style: TextStyle(color: AppColors.textSecond, fontSize: 13),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.surfaceHigh,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: AppColors.border),
                          ),
                        ),
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final file = await ManifestService.instance.saveNow();
                          if (file != null) {
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('Manifesto exportado com sucesso em: ${file.path}'),
                                backgroundColor: AppColors.accent,
                              ),
                            );
                          } else {
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('Falha ao exportar manifesto.'),
                                backgroundColor: AppColors.error,
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.backup_rounded, size: 18),
                        label: const Text('Exportar Backup', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
                            if (selectedDirectory == null) return;

                            // Verifica se há manifest.json
                            final preview = await ManifestService.instance.previewManifest(selectedDirectory);
                            if (preview == null) {
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text('Nenhum manifest.json válido foi encontrado nesta pasta.'),
                                  backgroundColor: AppColors.warning,
                                ),
                              );
                              return;
                            }

                            // Mostra confirmação
                            if (!mounted) return;
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                backgroundColor: AppColors.surface,
                                title: const Text('Importar Backup?', style: TextStyle(color: Colors.white)),
                                content: Text(
                                  'Encontrado backup de ${preview.playlistCount} playlists e ${preview.trackCount} músicas.\nDeseja importar estes metadados e usar esta pasta?\n\nExportado em: ${preview.exportedAt}',
                                  style: const TextStyle(color: AppColors.textSecond),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Cancelar', style: TextStyle(color: AppColors.textMuted)),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Importar', style: TextStyle(color: Colors.black)),
                                  ),
                                ],
                              ),
                            );

                            if (confirm == true) {
                              final result = await ManifestService.instance.recoverFromDirectory(selectedDirectory);
                              // Atualiza o controller da UI também para bater com o novo caminho
                              _downloadDirCtrl.text = selectedDirectory;
                              // Recarrega as playlists do riverpod
                              ref.invalidate(playlistsProvider);
                              
                              if (mounted) {
                                setState(() {});
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    backgroundColor: AppColors.surface,
                                    title: Text('Sucesso!', style: TextStyle(color: AppColors.accent)),
                                    content: Text(
                                      'Importado com sucesso:\n'
                                      '• ${result.playlistsImported} playlists\n'
                                      '• ${result.tracksImported} músicas descritas\n'
                                      '• ${result.tracksFound} músicas encontradas e vinculadas localmente!',
                                      style: const TextStyle(color: Colors.white),
                                    ),
                                    actions: [
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text('OK', style: TextStyle(color: Colors.black)),
                                      ),
                                    ],
                                  ),
                                );
                              }
                            }
                          } catch (e) {
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text('Erro ao importar backup: $e'),
                                backgroundColor: AppColors.error,
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.restore_rounded, size: 18),
                        label: const Text('Importar / Recuperar', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── Sobre ────────────────────────────────────────────────────────
          _Section(
            title: 'Sobre',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Center(
                  child: AppLogo(
                    size: 56,
                    showText: true,
                    textGap: 12,
                    textFontSize: 22,
                  ),
                ),
                const SizedBox(height: 20),
                const Divider(color: AppColors.border, height: 1),
                const SizedBox(height: 16),
                const _InfoRow(label: 'App', value: AppConstants.appName),
                const SizedBox(height: 8),
                const _InfoRow(label: 'Versão', value: AppConstants.appVersion),
                const SizedBox(height: 8),
                const _InfoRow(
                  label: 'Motor',
                  value: 'Servidor de Download Externo (FastAPI)',
                ),
                const SizedBox(height: 8),
                const _InfoRow(
                  label: 'Direitos',
                  value: '© PietroTy. Todos os direitos reservados.',
                ),
                const SizedBox(height: 8),
                _InfoRowWithAction(
                  label: 'Site',
                  value: 'https://pietroty.github.io/PietroTy/',
                  onTap: () {
                    Clipboard.setData(
                      const ClipboardData(
                        text: 'https://pietroty.github.io/PietroTy/',
                      ),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text(
                          'Link copiado para a área de transferência!',
                          style: TextStyle(color: Colors.white),
                        ),
                        backgroundColor: AppColors.accentDim,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  String _fmtDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2,'0')}/'
           '${dt.month.toString().padLeft(2,'0')}/'
           '${dt.year}  '
           '${dt.hour.toString().padLeft(2,'0')}:'
           '${dt.minute.toString().padLeft(2,'0')}';
  }

  @override
  void dispose() {
    _spotifyIdCtrl.dispose();
    _spotifySecretCtrl.dispose();
    _downloadDirCtrl.dispose();
    super.dispose();
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$label: ',
          style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        Text(value,
          style: const TextStyle(color: AppColors.textSecond, fontSize: 13),
        ),
      ],
    );
  }
}

class _InfoRowWithAction extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;
  const _InfoRowWithAction({required this.label, required this.value, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$label: ',
          style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        value,
                        style: TextStyle(
                          color: AppColors.accent,
                          fontSize: 13,
                          decoration: TextDecoration.underline,
                          decorationColor: AppColors.accent,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.copy_rounded,
                      size: 13,
                      color: AppColors.accent,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Provider auxiliar para último sync
final _lastSyncProvider = FutureProvider<DateTime?>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final str   = prefs.getString(AppConstants.keyLastSync);
  return str != null ? DateTime.tryParse(str) : null;
});
