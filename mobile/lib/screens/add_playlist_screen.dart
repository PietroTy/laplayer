import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/theme.dart';
import '../data/database/database.dart';
import '../data/models/playlist.dart';
import '../data/services/sync_service.dart';
import '../providers/library_provider.dart';
import 'widgets/app_logo.dart';

// ── Modos de criação ──────────────────────────────────────────────────────────

enum _CreateMode { choose, blank, spotify }

class AddPlaylistScreen extends ConsumerStatefulWidget {
  const AddPlaylistScreen({super.key});

  @override
  ConsumerState<AddPlaylistScreen> createState() => _AddPlaylistScreenState();
}

class _AddPlaylistScreenState extends ConsumerState<AddPlaylistScreen> {
  _CreateMode _mode = _CreateMode.choose;

  // Spotify fields
  final _urlController = TextEditingController();

  // Blank playlist fields
  final _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }



  // ── Criar playlist em branco ──────────────────────────────────────────────

  Future<void> _createBlankPlaylist() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dê um nome para a playlist.')),
      );
      return;
    }

    try {
      final id = const Uuid().v4();
      final playlist = Playlist(
        id: id,
        name: name,
        totalTracks: 0,
        downloaded: 0,
      );
      await AppDatabase.instance.upsertPlaylist(playlist);
      ref.invalidate(playlistsProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Playlist "$name" criada!'),
            backgroundColor: AppColors.accent,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  // ── Importar do Spotify ───────────────────────────────────────────────────

  Future<void> _handleSpotifyImport() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Insira o link da playlist do Spotify')),
      );
      return;
    }
    await ref.read(syncProvider.notifier).addNewPlaylist(url);

    final state = ref.read(syncProvider);
    if (!mounted) return;
    if (state.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${state.error}'), backgroundColor: AppColors.error),
      );
    } else if (state.message != null && !state.isLoading) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(state.message!), backgroundColor: AppColors.accent),
      );
      ref.invalidate(playlistsProvider);
      Navigator.pop(context);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return switch (_mode) {
      _CreateMode.choose  => _buildChoose(),
      _CreateMode.blank   => _buildBlankForm(),
      _CreateMode.spotify => _buildSpotifyForm(),
    };
  }

  // Tela de escolha
  Widget _buildChoose() {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Nova Playlist'),
        backgroundColor: AppColors.bg,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: 36),
                child: AppLogo(size: 56, showText: true, textGap: 12, textFontSize: 22),
              ),
            ),
            const Text(
              'Como deseja criar?',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),

            // Opção: Playlist em Branco
            _ChoiceCard(
              icon: Icons.add_box_rounded,
              iconColor: AppColors.accent,
              title: 'Playlist em Branco',
              subtitle: 'Crie uma playlist vazia para adicionar suas músicas favoritas.',
              onTap: () => setState(() => _mode = _CreateMode.blank),
            ),
            const SizedBox(height: 16),

            // Opção: Importar do Spotify
            _ChoiceCard(
              icon: Icons.podcasts_rounded,
              iconColor: const Color(0xFF1DB954),
              title: 'Importar do Spotify',
              subtitle: 'Sincronize uma playlist do Spotify como fonte de metadados.',
              onTap: () => setState(() => _mode = _CreateMode.spotify),
            ),
          ],
        ),
      ),
    );
  }

  // Formulário: Playlist em branco
  Widget _buildBlankForm() {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Playlist em Branco'),
        backgroundColor: AppColors.bg,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => setState(() => _mode = _CreateMode.choose),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.queue_music_rounded, color: AppColors.accent, size: 56),
            const SizedBox(height: 24),
            const Text(
              'Nome da Playlist',
              style: TextStyle(color: AppColors.textSecond, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              textCapitalization: TextCapitalization.sentences,
              decoration: AppTheme.inputDecoration('Ex: Minhas favoritas'),
              onSubmitted: (_) => _createBlankPlaylist(),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: _createBlankPlaylist,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.black,
                minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
              ),
              child: const Text('CRIAR PLAYLIST',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            ),
            const SizedBox(height: 20),
            const Text(
              'Após criar, busque suas músicas favoritas para adicioná-las.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  // Formulário: Spotify
  Widget _buildSpotifyForm() {
    final syncState = ref.watch(syncProvider);
    final isLoading = syncState.isLoading;

    return PopScope(
      canPop: !isLoading,
      onPopInvoked: (didPop) {
        if (!didPop) return;
        if (!isLoading) setState(() => _mode = _CreateMode.choose);
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: const Text('Importar do Spotify'),
          backgroundColor: AppColors.bg,
          leading: isLoading
              ? const SizedBox()
              : IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => setState(() => _mode = _CreateMode.choose),
                ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 24),
                  child: Icon(Icons.podcasts_rounded,
                      color: Color(0xFF1DB954), size: 56),
                ),
              ),
              const Text('Link da Playlist',
                  style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _urlController,
                enabled: !isLoading,
                style: const TextStyle(color: Colors.white),
                decoration: AppTheme.inputDecoration('https://open.spotify.com/playlist/...'),
              ),
              const SizedBox(height: 24),
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
                    'Não feche o app agora.\nProcessando músicas...',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                ),
              ] else
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _handleSpotifyImport,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1DB954),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(25)),
                    ),
                    child: const Text('SINCRONIZAR PLAYLIST',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Widget de opção de escolha ────────────────────────────────────────────────

class _ChoiceCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ChoiceCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: iconColor, size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 12)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
