import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../data/models/artist_group.dart';
import '../album_screen.dart';

class ArtistListView extends ConsumerStatefulWidget {
  final List<ArtistGroup> artists;
  final String? playlistId;
  final bool shrinkWrap;
  final ScrollPhysics? physics;
  final bool isScrolling;

  const ArtistListView({
    super.key,
    required this.artists,
    this.playlistId,
    this.shrinkWrap = false,
    this.physics,
    this.isScrolling = false,
  });

  @override
  ConsumerState<ArtistListView> createState() => _ArtistListViewState();
}

class _ArtistListViewState extends ConsumerState<ArtistListView> {
  bool _localIsScrolling = false;

  @override
  Widget build(BuildContext context) {
    if (widget.artists.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(
          child: Text('Nenhum artista encontrado.',
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
      child: ListView.separated(
        shrinkWrap: widget.shrinkWrap,
        physics: widget.physics,
        padding: const EdgeInsets.only(bottom: 100),
        itemCount: widget.artists.length,
        separatorBuilder: (_, __) => Divider(
          color: AppColors.border.withOpacity(0.3), height: 1,
          indent: 72,
        ),
        itemBuilder: (context, i) {
          if (isFastScrolling) {
            return const _ArtistTilePlaceholder();
          }
          return _ArtistTile(
            artist: widget.artists[i],
            playlistId: widget.playlistId,
          );
        },
      ),
    );
  }
}

class _ArtistTilePlaceholder extends StatelessWidget {
  const _ArtistTilePlaceholder();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 48, height: 48,
        color: AppColors.surfaceHigh,
        child: const Icon(Icons.person_rounded, color: Colors.white10, size: 24),
      ),
      title: Container(
        width: 100, height: 12,
        decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.zero),
      ),
      subtitle: Container(
        width: 150, height: 10,
        margin: const EdgeInsets.only(top: 4),
        decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.zero),
      ),
    );
  }
}

class _ArtistTile extends ConsumerWidget {
  final ArtistGroup artist;
  final String? playlistId;
  const _ArtistTile({required this.artist, this.playlistId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 48, height: 48,
        color: AppColors.surfaceHigh,
        child: artist.coverArtUrl != null
            ? CachedNetworkImage(imageUrl: artist.coverArtUrl!, fit: BoxFit.cover, memCacheWidth: 150)
            : const Icon(Icons.person_rounded, color: AppColors.textMuted, size: 24),
      ),
      title: Text(
        artist.name,
        style: const TextStyle(
          color: AppColors.textPrimary, fontSize: 14, fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${artist.totalTracks} músicas • ${artist.albumCount} álbum${artist.albumCount == 1 ? '' : 'ns'} • ${artist.downloadedTracks} baixadas',
        style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
      ),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
      onTap: () => context.push(artistRoute(artist.name)),
    );
  }
}
