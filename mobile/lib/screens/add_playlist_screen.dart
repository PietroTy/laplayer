import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/theme.dart';
import '../data/services/sync_service.dart';
import '../providers/library_provider.dart';
import 'widgets/app_logo.dart';

class AddPlaylistScreen extends ConsumerStatefulWidget {
  const AddPlaylistScreen({super.key});

  @override
  ConsumerState<AddPlaylistScreen> createState() => _AddPlaylistScreenState();
}

class _AddPlaylistScreenState extends ConsumerState<AddPlaylistScreen> {
  final _urlController = TextEditingController();
  final _clientIdController = TextEditingController();
  final _clientSecretController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSavedKeys();
  }

  Future<void> _loadSavedKeys() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _clientIdController.text = prefs.getString('spotify_client_id') ?? '';
      _clientSecretController.text = prefs.getString('spotify_client_secret') ?? '';
    });
  }

  Future<void> _saveKeys() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('spotify_client_id', _clientIdController.text.trim());
    await prefs.setString('spotify_client_secret', _clientSecretController.text.trim());
  }

  Future<void> _handleAdd() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Insira o link da playlist do Spotify')),
      );
      return;
    }

    await _saveKeys();
    
    // Dispara o fluxo Local-First
    await ref.read(syncProvider.notifier).addNewPlaylist(url);
    
    final state = ref.read(syncProvider);
    if (state.error != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${state.error}'), backgroundColor: AppColors.error),
      );
    } else if (state.message != null && !state.isLoading) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.message!), backgroundColor: AppColors.accent),
      );
      ref.invalidate(playlistsProvider);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncProvider);
    final isLoading = syncState.isLoading;

    return PopScope(
      canPop: !isLoading,
      onPopInvoked: (didPop) {
        if (!didPop && isLoading) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Aguarde a sincronização finalizar para sair.')),
          );
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: const Text('Nova Playlist'),
          backgroundColor: AppColors.bg,
          leading: isLoading ? const SizedBox() : null,
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 32.0),
                  child: AppLogo(
                    size: 64,
                    showText: true,
                    textGap: 14,
                    textFontSize: 24,
                  ),
                ),
              ),
              const Text(
                'Link da Playlist',
                style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _urlController,
                enabled: !isLoading,
                style: const TextStyle(color: Colors.white),
                decoration: AppTheme.inputDecoration('https://open.spotify.com/playlist/...'),
              ),
              const SizedBox(height: 24),
              
              const Text(
                'Credenciais da API (Salvas localmente)',
                style: TextStyle(color: AppColors.textSecond, fontSize: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _clientIdController,
                enabled: !isLoading,
                style: const TextStyle(color: Colors.white),
                decoration: AppTheme.inputDecoration('Spotify Client ID'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _clientSecretController,
                enabled: !isLoading,
                style: const TextStyle(color: Colors.white),
                obscureText: true,
                decoration: AppTheme.inputDecoration('Spotify Client Secret'),
              ),
              
              const SizedBox(height: 40),
              if (isLoading) ...[
                Center(child: CircularProgressIndicator(color: AppColors.accent)),
                const SizedBox(height: 20),
                Center(
                  child: Text(
                    syncState.message ?? 'Processando...',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.accent, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 12),
                const Center(
                  child: Text(
                    'Não feche o app agora.\nProcessando milhares de músicas...',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ),
              ] else
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _handleAdd,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
                    ),
                    child: const Text('SINCRONIZAR PLAYLIST', 
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                ),
              const SizedBox(height: 30),
              const Text(
                'O لاplayer baixará todos os metadados (título, artista, álbum, capa) do Spotify e salvará no banco de dados local.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
