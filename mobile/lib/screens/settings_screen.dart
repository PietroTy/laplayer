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
  final _serverUrlCtrl = TextEditingController();
  final _githubRepoCtrl = TextEditingController();
 
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
    _serverUrlCtrl.text = prefs.getString('server_url') ?? '';
    _githubRepoCtrl.text = prefs.getString('github_repo') ?? '';
    setState(() {});
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
    await prefs.setString('server_url', _serverUrlCtrl.text.trim());
    await prefs.setString('github_repo', _githubRepoCtrl.text.trim());
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

          // ── Servidor de Downloads ───────────────────────────────────────
          _Section(
            title: 'Servidor de Downloads',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Método Principal: GitHub Auto-Discovery ──────────────
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.accent.withOpacity(0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.star_rounded, color: AppColors.accent, size: 12),
                          const SizedBox(width: 4),
                          Text(
                            'RECOMENDADO',
                            style: TextStyle(
                              color: AppColors.accent,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Informe o repositório GitHub (usuario/repositorio) que contém o arquivo server_url.txt. O script start_server atualiza este arquivo automaticamente sempre que o servidor é iniciado — o app sempre encontrará o endereço certo, mesmo que o IP mude.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _githubRepoCtrl,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'Repositório GitHub (ex: PietroTy/localify-url)',
                    labelStyle: TextStyle(color: AppColors.textMuted),
                    prefixIcon: Icon(Icons.hub_rounded, color: AppColors.textMuted),
                    helperText: 'Deixe preenchido para descoberta automática do servidor',
                    helperStyle: TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                ),
                const SizedBox(height: 20),
                const Divider(color: AppColors.border, height: 1),
                const SizedBox(height: 16),
                // ── Método Alternativo: URL Manual ───────────────────────
                const Text(
                  'URL MANUAL (FALLBACK)',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Usado apenas se o repositório GitHub não estiver configurado ou o servidor estiver offline. Insira o IP do seu computador na rede local.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _serverUrlCtrl,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    labelText: 'URL do Servidor (ex: http://192.168.1.5:8000)',
                    labelStyle: TextStyle(color: AppColors.textMuted),
                    prefixIcon: Icon(Icons.dns_rounded, color: AppColors.textMuted),
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
    _serverUrlCtrl.dispose();
    _githubRepoCtrl.dispose();
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
