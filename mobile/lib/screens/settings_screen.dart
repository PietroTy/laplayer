import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/constants.dart';
import '../core/file_utils.dart';
import '../core/theme.dart';
import '../data/database/database.dart';
import '../data/models/track.dart';
import '../data/models/playlist.dart';
import '../data/services/sync_service.dart';
import '../data/services/manifest_service.dart';
import '../data/services/tts_announcer_service.dart';
import '../data/services/standalone_downloader.dart';
import '../providers/library_provider.dart';
import 'widgets/app_logo.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _accessKeyCtrl = TextEditingController();
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
 
  bool? _isSpotifyConnected;
 
  @override
  void initState() {
    super.initState();
    _checkSpotifyAuth();
    _loadPrefs();
  }
 
  Future<void> _checkSpotifyAuth() async {
    final connected = await StandaloneDownloader().checkAuth();
    if (mounted) {
      setState(() {
        _isSpotifyConnected = connected;
      });
    }
  }
 
  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _accessKeyCtrl.text = prefs.getString('access_key') ?? '';

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
    final oldFormat = prefs.getString('download_audio_format') ?? 'm4a';
    final newFormat = _audioFormat;

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

    if (oldFormat != newFormat) {
      _showReDownloadDialog(context, oldFormat, newFormat);
    }
  }

  void _showReDownloadDialog(BuildContext context, String oldFormat, String newFormat) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Atualizar formato das músicas?',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
        content: Text(
          'Você mudou o formato padrão de $oldFormat para $newFormat.\n\n'
          'Deseja marcar todas as músicas já baixadas para serem baixadas novamente no novo formato ($newFormat)?\n'
          'Os arquivos antigos no formato anterior ($oldFormat) serão apagados para liberar espaço.',
          style: const TextStyle(color: AppColors.textSecond, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Manter antigas', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Limpando músicas no formato antigo...'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }

              // 1. Apaga FISICAMENTE todos os arquivos de áudio e letras do diretório local
              try {
                final musicDirRoot = await AppConstants.getMusicDirectory();
                final dir = Directory(musicDirRoot);
                if (await dir.exists()) {
                  final entities = await dir.list().toList();
                  for (final entity in entities) {
                    if (entity is File) {
                      final ext = entity.path.split('.').last.toLowerCase();
                      if (FileUtils.audioExtensions.contains(ext) || ext == 'lrc') {
                        try {
                          await entity.delete();
                        } catch (e) {
                          debugPrint('Erro ao apagar arquivo ${entity.path}: $e');
                        }
                      }
                    }
                  }
                }
              } catch (e) {
                debugPrint('Erro ao varrer pasta para apagar arquivos antigos: $e');
              }

              // 2. Reseta o status de TODAS as músicas no banco de dados local
              final playlists = await AppDatabase.instance.getPlaylists();
              for (final pl in playlists) {
                final tracks = await AppDatabase.instance.getTracksForPlaylist(pl.id);
                final tracksToReset = tracks.map((t) => t.copyWith(
                  isCached: false,
                  available: false,
                  downloadStatus: 'pending',
                  localFilename: null,
                )).toList();
                
                if (tracksToReset.isNotEmpty) {
                  await AppDatabase.instance.updateTracksCacheStatus(tracksToReset);
                  ref.invalidate(playlistTracksProvider(pl.id));
                }
              }

              // 3. Invalida a lista global de playlists e força atualização imediata na interface
              ref.invalidate(playlistsProvider);

              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Músicas prontas para download em $newFormat!'),
                    backgroundColor: AppColors.accent,
                  ),
                );
              }
            },
            child: const Text('Atualizar Formato'),
          ),
        ],
      ),
    );
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
    await prefs.setString('access_key', _accessKeyCtrl.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Configurações salvas!'),
          backgroundColor: AppColors.accent,
        ),
      );
    }
  }

  Widget _buildThemeItem(AppThemePalette palette) {
    final currentPalette = ref.watch(themePaletteProvider);
    final isSelected = currentPalette == palette;
    return GestureDetector(
      onTap: () => ref.read(themePaletteProvider.notifier).setTheme(palette),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: palette.bg,
              gradient: palette.bgGradient,
              border: Border.all(
                color: isSelected ? palette.accent : AppColors.border,
                width: isSelected ? 2.5 : 1.0,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: palette.accent.withValues(alpha: 0.4),
                        blurRadius: 10,
                        spreadRadius: 2,
                      )
                    ]
                  : null,
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Duo-tone diagonal split accent preview
                Positioned(
                  bottom: 3,
                  right: 3,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: palette.accent,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: const [
                        BoxShadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 1)),
                      ],
                    ),
                    child: isSelected
                        ? const Icon(Icons.check_rounded, color: Colors.black, size: 14)
                        : null,
                  ),
                ),
                Positioned(
                  top: 4,
                  left: 4,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 60,
            child: Text(
              palette.name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isSelected ? AppColors.textPrimary : AppColors.textSecond,
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(syncProvider);
    final lastSync = ref.watch(_lastSyncProvider);

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        title: const Text(
          'Configurações',
          style: TextStyle(
            color: AppColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 1. ── Tema Visual (PRIMEIRO ITEM - 5 em cima, 5 em baixo) ─────────────
          _Section(
            title: 'Tema Visual',
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: AppThemePalette.values.take(5).map((palette) {
                    return _buildThemeItem(palette);
                  }).toList(),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: AppThemePalette.values.skip(5).take(5).map((palette) {
                    return _buildThemeItem(palette);
                  }).toList(),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // 2. ── Anúncio por Voz (Vocaloid TTS) ───────────────────────────────
          _Section(
            title: 'Narrador e Sintetizador de Voz (Vocaloid)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeColor: AppColors.accent,
                  title: const Text(
                    'Anunciar nome da música e artista',
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                  subtitle: const Text(
                    'Usa voz de robô estilo Vocaloid antes de tocar cada música.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  value: TtsAnnouncerService.instance.isEnabled,
                  onChanged: (val) async {
                    await TtsAnnouncerService.instance.setEnabled(val);
                    setState(() {});
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // 3. ── Qualidade e Armazenamento ───────────────────────────────────
          _Section(
            title: 'Qualidade de Áudio & Armazenamento',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Escolha a qualidade das músicas baixadas para economizar memória do celular ou obter áudio em alta fidelidade.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Qualidade (Bitrate):',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Column(
                  children: _qualities.map((q) {
                    final qId = q['id'] as String;
                    final qLabel = q['label'] as String;
                    final qDesc = q['desc'] as String;
                    final qIcon = q['icon'] as IconData;
                    final isSelected = _audioQuality == qId;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: isSelected ? AppColors.accent.withValues(alpha: 0.12) : AppColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected ? AppColors.accent : AppColors.border,
                          width: isSelected ? 1.5 : 1.0,
                        ),
                      ),
                      child: RadioListTile<String>(
                        value: qId,
                        groupValue: _audioQuality,
                        activeColor: AppColors.accent,
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _audioQuality = val);
                            _saveDownloadQuality();
                          }
                        },
                        secondary: Icon(qIcon, color: isSelected ? AppColors.accent : AppColors.textMuted),
                        title: Text(
                          '$qLabel ($qDesc)',
                          style: TextStyle(
                            color: isSelected ? AppColors.accent : AppColors.textPrimary,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            fontSize: 13,
                          ),
                        ),
                        subtitle: Text(
                          qId == 'low'
                              ? 'Economiza até 70% de espaço! (~1.5–2 MB por música)'
                              : qId == 'medium'
                                  ? 'Bom equilíbrio entre espaço e áudio (~3 MB por música)'
                                  : qId == 'high'
                                      ? 'Alta qualidade (~4.5 MB por música)'
                                      : 'Fidelidade máxima (~7–10 MB por música)',
                          style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // 4. ── Diretório de Downloads ─────────────────────────────────────────
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

          // 5. ── Backup & Recuperação ──────────────────────────────────────────
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
                          final shouldProceed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: AppColors.surface,
                              title: Row(
                                children: [
                                  Icon(Icons.backup_rounded, color: AppColors.accent),
                                  const SizedBox(width: 8),
                                  const Text('Exportar Backup Completo', style: TextStyle(color: Colors.white, fontSize: 16)),
                                ],
                              ),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: const [
                                  Text('Passo a Passo:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                                  SizedBox(height: 8),
                                  Text('1. Clique em "Selecionar Pasta" para escolher onde salvar.', style: TextStyle(color: AppColors.textSecond, fontSize: 13)),
                                  SizedBox(height: 6),
                                  Text('2. O app vai clonar TUDO para lá: suas músicas, letras (.lrc), playlists, histórico e todas as suas configurações e temas.', style: TextStyle(color: AppColors.textSecond, fontSize: 13)),
                                  SizedBox(height: 6),
                                  Text('3. Um manifesto de backup (manifest.json) será gravado para garantir que nada se perca.', style: TextStyle(color: AppColors.textSecond, fontSize: 13)),
                                ],
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancelar', style: TextStyle(color: AppColors.textMuted)),
                                ),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Selecionar Pasta', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                          );

                          if (shouldProceed != true) return;

                          final messenger = ScaffoldMessenger.of(context);
                          final selectedDirectory = await FilePicker.platform.getDirectoryPath();
                          if (selectedDirectory == null) return;

                          if (!mounted) return;
                          
                          showDialog(
                            context: context,
                            barrierDismissible: false,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: AppColors.surface,
                              content: Row(
                                children: [
                                  CircularProgressIndicator(color: AppColors.accent),
                                  const SizedBox(width: 16),
                                  const Expanded(child: Text('Clonando dados e arquivos...', style: TextStyle(color: Colors.white))),
                                ],
                              ),
                            ),
                          );

                          try {
                            final result = await ManifestService.instance.exportFullBackup(selectedDirectory);
                            if (mounted) Navigator.pop(context);

                            if (mounted) {
                              showDialog(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: AppColors.surface,
                                  title: Text('Backup Exportado!', style: TextStyle(color: AppColors.accent)),
                                  content: Text(
                                    'Clonado com sucesso:\n'
                                    '• ${result.copiedFiles} arquivos de áudio e letras\n'
                                    '• ${result.playlistCount} playlists e ${result.trackCount} faixas\n'
                                    'Local: ${result.manifestPath}',
                                    style: const TextStyle(color: AppColors.textSecond, fontSize: 13),
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
                          } catch (e) {
                            if (mounted) Navigator.pop(context);
                            if (mounted) {
                              messenger.showSnackBar(
                                SnackBar(content: Text('Erro no backup: $e'), backgroundColor: AppColors.error),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.download_rounded, size: 18),
                        label: const Text('Exportar Backup'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          side: const BorderSide(color: AppColors.border),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: () async {
                          final selectedDirectory = await FilePicker.platform.getDirectoryPath();
                          if (selectedDirectory == null) return;

                          if (!mounted) return;

                          showDialog(
                            context: context,
                            barrierDismissible: false,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: AppColors.surface,
                              content: Row(
                                children: [
                                  CircularProgressIndicator(color: AppColors.accent),
                                  const SizedBox(width: 16),
                                  const Expanded(child: Text('Importando backup...', style: TextStyle(color: Colors.white))),
                                ],
                              ),
                            ),
                          );

                          try {
                            final result = await ManifestService.instance.recoverFromDirectory(selectedDirectory);
                            if (mounted) Navigator.pop(context);

                            if (mounted) {
                              _downloadDirCtrl.text = selectedDirectory;
                              ref.invalidate(playlistsProvider);
                              ref.invalidate(themePaletteProvider);
                              setState(() {});
                              showDialog(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: AppColors.surface,
                                  title: Text('Backup Restaurado!', style: TextStyle(color: AppColors.accent)),
                                  content: Text(
                                    'Importado com sucesso:\n'
                                    '• ${result.playlistsImported} playlists\n'
                                    '• ${result.tracksImported} músicas cadastradas\n'
                                    '• ${result.tracksFound} arquivos vinculados localmente!',
                                    style: const TextStyle(color: AppColors.textSecond, fontSize: 13),
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
                          } catch (e) {
                            if (mounted) Navigator.pop(context);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Erro na importação: $e'), backgroundColor: AppColors.error),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.upload_rounded, size: 18),
                        label: const Text('Importar Backup'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // 6. ── Sobre o LA Player (ÚLTIMO ITEM) ──────────────────────────────
          _Section(
            title: 'Sobre o LA Player',
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
                const _InfoRow(label: 'Versão', value: '2.5.0'),
                const _InfoRow(
                  label: 'Tecnologia',
                  value: 'Flutter & Dart',
                ),
                const _InfoRow(
                  label: 'Metadados',
                  value: 'Spotify & YouTube Engine',
                ),
                const _InfoRow(
                  label: 'Motor de Áudio',
                  value: 'Direct High-Fidelity Audio',
                ),
                const _InfoRow(
                  label: 'Sincronização',
                  value: 'Offline-First & SQLite',
                ),
                const _InfoRow(
                  label: 'Desenvolvedor',
                  value: 'PietroTy',
                ),
                const _InfoRow(
                  label: 'Direitos',
                  value: '© PietroTy. Todos os direitos reservados.',
                ),
                _InfoRowWithAction(
                  label: 'Site',
                  value: 'https://pietroty.github.io/PietroTy/',
                  onTap: () async {
                    final uri = Uri.parse('https://pietroty.github.io/PietroTy/');
                    try {
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri, mode: LaunchMode.externalApplication);
                      } else {
                        await Clipboard.setData(const ClipboardData(text: 'https://pietroty.github.io/PietroTy/'));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Link copiado para a área de transferência!')),
                          );
                        }
                      }
                    } catch (_) {
                      await Clipboard.setData(const ClipboardData(text: 'https://pietroty.github.io/PietroTy/'));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Link copiado para a área de transferência!')),
                        );
                      }
                    }
                  },
                ),
                const SizedBox(height: 16),
                const Text(
                  "if buying isn't owning, pirating isn't stealing. cultura nao é mercadoria. take what you can! give nothing back!",
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),

          const SizedBox(height: 40),
        ],
      ),
    ),
  );
  }


  @override
  void dispose() {
    _accessKeyCtrl.dispose();
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              '$label:',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: AppColors.textSecond, fontSize: 13),
              softWrap: true,
            ),
          ),
        ],
      ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              '$label:',
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(4),
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
                    Icons.open_in_new_rounded,
                    size: 13,
                    color: AppColors.accent,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Provider auxiliar para último sync
final _lastSyncProvider = FutureProvider<DateTime?>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final str   = prefs.getString(AppConstants.keyLastSync);
  return str != null ? DateTime.tryParse(str) : null;
});
