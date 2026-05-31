import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/database/database.dart';
import '../../data/models/album_group.dart';
import '../../data/models/track.dart';
import '../../providers/player_provider.dart';
import '../../data/models/player_state.dart' as app;
import 'track_tile.dart';

class AlbumGridView extends ConsumerWidget {
  final List<AlbumGroup> albums;
  final Map<String, String> playlistNames; // playlistId → name

  const AlbumGridView({
    super.key,
    required this.albums,
    required this.playlistNames,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (albums.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(
          child: Text('Nenhum álbum encontrado.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        shrinkWrap: true,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.78,
        ),
        itemCount: albums.length,
        itemBuilder: (context, i) => _AlbumCard(
          album: albums[i],
          playlistNames: playlistNames,
        ),
      ),
    );
  }
}

class _AlbumCard extends ConsumerWidget {
  final AlbumGroup album;
  final Map<String, String> playlistNames;
  const _AlbumCard({required this.album, required this.playlistNames});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pct = album.downloadProgress;
    final isComplete = pct >= 1.0;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showAlbumSheet(context, ref),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Capa
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: album.albumArtUrl != null
                    ? CachedNetworkImage(
                        imageUrl: album.albumArtUrl!,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => _placeholder(),
                        errorWidget: (_, __, ___) => _placeholder(),
                      )
                    : _placeholder(),
              ),
            ),
            // Info
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(album.albumName,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(album.albumArtist,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                  ),
                  const SizedBox(height: 6),
                  // Barra de progresso de download
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: pct,
                            backgroundColor: AppColors.surfaceHigh,
                            color: isComplete ? AppColors.accent : Colors.orange,
                            minHeight: 3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${album.downloadedTracks}/${album.totalTracks}',
                        style: const TextStyle(color: AppColors.textMuted, fontSize: 9),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder() => Container(
    color: AppColors.surfaceHigh,
    child: const Center(
      child: Icon(Icons.album_rounded, color: AppColors.textMuted, size: 40),
    ),
  );

  void _showAlbumSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AlbumTracksSheet(
        album: album,
        playlistNames: playlistNames,
      ),
    );
  }
}

class _AlbumTracksSheet extends ConsumerStatefulWidget {
  final AlbumGroup album;
  final Map<String, String> playlistNames;
  const _AlbumTracksSheet({required this.album, required this.playlistNames});

  @override
  ConsumerState<_AlbumTracksSheet> createState() => _AlbumTracksSheetState();
}

class _AlbumTracksSheetState extends ConsumerState<_AlbumTracksSheet> {
  List<Track> _tracks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final tracks = await AppDatabase.instance.getTracksForAlbum(widget.album.albumName);
    if (mounted) setState(() { _tracks = tracks; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final available = _tracks.where((t) => t.isCached).toList();
    final playlists = widget.album.playlistIds
        .map((id) => widget.playlistNames[id] ?? id)
        .where((n) => n.isNotEmpty)
        .join(', ');

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      expand: false,
      builder: (_, controller) => Column(
        children: [
          // Handle
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textMuted.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                if (widget.album.albumArtUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: widget.album.albumArtUrl!,
                      width: 60, height: 60, fit: BoxFit.cover,
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.album.albumName,
                        style: const TextStyle(
                          color: AppColors.textPrimary, fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(widget.album.albumArtist,
                        style: const TextStyle(color: AppColors.textSecond, fontSize: 13)),
                      if (widget.album.releaseYear.isNotEmpty)
                        Text(widget.album.releaseYear,
                          style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                      if (playlists.isNotEmpty)
                        Text('em: $playlists',
                          style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                if (available.isNotEmpty)
                  GestureDetector(
                    onTap: () => ref.read(playerProvider.notifier)
                        .playQueueWithShuffle(available, shuffleMode: app.ShuffleMode.random),
                    child: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accent,
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                        color: Colors.black, size: 24),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(color: AppColors.border, height: 1),
          // Tracks
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: controller,
                    itemCount: _tracks.length,
                    itemBuilder: (context, i) => TrackTile(
                      track: _tracks[i],
                      queue: available,
                      showIndex: false,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
