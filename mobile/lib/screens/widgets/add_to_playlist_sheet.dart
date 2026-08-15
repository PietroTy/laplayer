import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme.dart';
import '../../data/database/database.dart';
import '../../data/models/playlist.dart';
import '../../data/models/track.dart';
import '../../providers/library_provider.dart';
import '../../data/services/sync_service.dart';

class AddToPlaylistSheet extends ConsumerStatefulWidget {
  final Track track;

  const AddToPlaylistSheet({super.key, required this.track});

  @override
  ConsumerState<AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends ConsumerState<AddToPlaylistSheet> {
  final _newPlaylistController = TextEditingController();

  @override
  void dispose() {
    _newPlaylistController.dispose();
    super.dispose();
  }

  Future<void> _addToPlaylist(Playlist playlist) async {
    // 1. Descobrir a próxima posição na playlist
    final pos = await AppDatabase.instance.getNextPlaylistPosition(playlist.id);

    // 2. Preparar a track para a playlist
    final updatedTrack = widget.track.copyWith(
      playlistId: playlist.id,
      playlistPosition: pos,
      downloadStatus: 'pending',
      isCached: false,
      available: false,
    );

    // 3. Inserir no banco
    await AppDatabase.instance.upsertTracks([updatedTrack]);

    // 4. Iniciar download de apenas esta música
    ref.read(syncProvider.notifier).retryTrackDownload(updatedTrack);
    
    // 5. Atualizar UI
    ref.invalidate(playlistsProvider);

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Adicionado à ${playlist.name}! Download iniciado.'),
          backgroundColor: AppColors.surfaceHigh,
        ),
      );
    }
  }

  Future<void> _createNewPlaylist(String name) async {
    if (name.trim().isEmpty) return;
    final id = const Uuid().v4();
    final newPlaylist = Playlist(
      id: id,
      name: name.trim(),
      description: 'Criada manualmente',
      imageUrl: widget.track.albumArtUrl ?? '',
      spotifyUrl: '',
      totalTracks: 1,
      downloaded: 0,
      failed: 0,
      path: '',
      snapshotId: '',
    );
    await AppDatabase.instance.upsertPlaylist(newPlaylist);
    await _addToPlaylist(newPlaylist);
  }

  @override
  Widget build(BuildContext context) {
    final playlistsAsync = ref.watch(playlistsProvider);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        top: 20,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.track.albumArtUrl != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(widget.track.albumArtUrl!, width: 48, height: 48, fit: BoxFit.cover),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Adicionar à Playlist', style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(
                      widget.track.title,
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(color: AppColors.border, height: 1),
          const SizedBox(height: 12),

          // Nova Playlist
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newPlaylistController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: 'Nova playlist...',
                    hintStyle: TextStyle(color: AppColors.textMuted),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: _createNewPlaylist,
                ),
              ),
              IconButton(
                icon: Icon(Icons.add_circle_rounded, color: AppColors.accent),
                onPressed: () => _createNewPlaylist(_newPlaylistController.text),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: AppColors.border, height: 1),
          
          // Playlists Locais
          Flexible(
            child: playlistsAsync.when(
              data: (playlists) {
                if (playlists.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: Text('Nenhuma playlist criada.', style: TextStyle(color: AppColors.textMuted))),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: playlists.length,
                  itemBuilder: (context, i) {
                    final p = playlists[i];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: p.imageUrl.isNotEmpty
                          ? ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.network(p.imageUrl, width: 40, height: 40, fit: BoxFit.cover))
                          : Container(width: 40, height: 40, color: AppColors.surfaceHigh, child: const Icon(Icons.queue_music_rounded, color: AppColors.textMuted)),
                      title: Text(p.name, style: const TextStyle(color: Colors.white)),
                      subtitle: Text('${p.totalTracks} músicas', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                      onTap: () => _addToPlaylist(p),
                    );
                  },
                );
              },
              loading: () => const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator())),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}
