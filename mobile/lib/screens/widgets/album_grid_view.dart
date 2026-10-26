import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/models/album_group.dart';
import '../album_screen.dart';

class AlbumGridView extends ConsumerStatefulWidget {
  final List<AlbumGroup> albums;
  final Map<String, String> playlistNames; // playlistId → name
  final String? playlistId;
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final bool isScrolling;

  const AlbumGridView({
    super.key,
    required this.albums,
    required this.playlistNames,
    this.playlistId,
    this.shrinkWrap = false,
    this.physics,
    this.isScrolling = false,
  });

  @override
  ConsumerState<AlbumGridView> createState() => _AlbumGridViewState();
}

class _AlbumGridViewState extends ConsumerState<AlbumGridView> {
  bool _localIsScrolling = false;

  @override
  Widget build(BuildContext context) {
    if (widget.albums.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(
          child: Text('Nenhum álbum encontrado.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
        ),
      );
    }

    final isFastScrolling = widget.isScrolling || _localIsScrolling;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          if (!_localIsScrolling) setState(() => _localIsScrolling = true);
        } else if (notification is ScrollUpdateNotification) {
          final v = notification.scrollDelta?.abs() ?? 0;
          if (v > 40 && !_localIsScrolling) setState(() => _localIsScrolling = true);
        } else if (notification is ScrollEndNotification) {
          if (_localIsScrolling) setState(() => _localIsScrolling = false);
        }
        return false;
      },
      child: GridView.builder(
        shrinkWrap: widget.shrinkWrap,
        physics: widget.physics,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 0.68,
        ),
        itemCount: widget.albums.length,
        itemBuilder: (context, i) {
          if (isFastScrolling) {
            return const _AlbumCardPlaceholder();
          }
          return _AlbumCard(
            album: widget.albums[i],
            playlistNames: widget.playlistNames,
            playlistId: widget.playlistId,
          );
        },
      ),
    );
  }
}

class _AlbumCardPlaceholder extends StatelessWidget {
  const _AlbumCardPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.zero,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: const BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.vertical(top: Radius.zero),
              ),
              child: const Center(
                child: Icon(Icons.album_rounded, color: Colors.white10, size: 40),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 90, height: 10,
                  decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.zero),
                ),
                const SizedBox(height: 6),
                Container(
                  width: 60, height: 8,
                  decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.zero),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumCard extends ConsumerWidget {
  final AlbumGroup album;
  final Map<String, String> playlistNames;
  final String? playlistId;
  const _AlbumCard({
    required this.album,
    required this.playlistNames,
    this.playlistId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pct = album.downloadProgress;
    final isComplete = pct >= 1.0;

    return InkWell(
      borderRadius: BorderRadius.zero,
      onTap: () => context.push(albumRoute(album.albumName, album.albumArtist)),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.zero,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Capa
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.zero),
                child: album.albumArtUrl != null
                    ? CachedNetworkImage(
                        imageUrl: album.albumArtUrl!,
                        memCacheWidth: 250,
                        memCacheHeight: 250,
                        fadeInDuration: const Duration(milliseconds: 100),
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
                          borderRadius: BorderRadius.zero,
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
}
