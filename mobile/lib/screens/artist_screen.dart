import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../data/database/database.dart';
import '../data/models/track.dart';
import '../providers/player_provider.dart';
import 'album_screen.dart';
import 'widgets/collection_header.dart';
import 'widgets/track_tile.dart';

/// Página do artista: capa, números, os álbuns dele (cada um abre a página do álbum) e as músicas.
class ArtistScreen extends ConsumerStatefulWidget {
  final String artistName;

  const ArtistScreen({super.key, required this.artistName});

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> {
  List<Track> _tracks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    final tracks = await AppDatabase.instance.getTracksForArtist(widget.artistName);
    if (!mounted) return;
    setState(() {
      _tracks = tracks;
      _isLoading = false;
    });
  }

  Future<void> _showMergeDialog() async {
    final textController = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Mesclar artista', style: TextStyle(color: AppColors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Digite o nome do artista com o qual deseja unificar "${widget.artistName}":',
              style: const TextStyle(color: AppColors.textSecond, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: AppTheme.inputDecoration('Nome do artista destino'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Mesclar')),
        ],
      ),
    );

    if (confirm == true && textController.text.trim().isNotEmpty) {
      final target = textController.text.trim();
      await AppDatabase.instance.mergeArtists(widget.artistName, target);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Artista mesclado com sucesso para "$target"')),
        );
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final playable = _tracks.where((t) => t.available).toList();
    final cover = _tracks.map((t) => t.albumArtUrl).firstWhere((u) => u != null, orElse: () => null);
    final albums = _albumsOf(_tracks);

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          actions: [
            IconButton(
              icon: const Icon(Icons.merge_type_rounded),
              tooltip: 'Mesclar artista',
              onPressed: _showMergeDialog,
            ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: CollectionHeader(
                      coverUrl: cover,
                      placeholderIcon: Icons.person_rounded,
                      kind: 'ARTISTA',
                      title: widget.artistName,
                      stats: '${collectionStats(_tracks, playable)} · ${albums.length} álbu${albums.length == 1 ? 'm' : 'ns'}',
                      playable: playable,
                    ),
                  ),
                  if (albums.isNotEmpty) ...[
                    const SliverToBoxAdapter(child: SectionLabel('ÁLBUNS')),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 186,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          itemCount: albums.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 12),
                          itemBuilder: (context, i) => _AlbumChip(album: albums[i]),
                        ),
                      ),
                    ),
                  ],
                  const SliverToBoxAdapter(child: SectionLabel('MÚSICAS')),
                  SliverPadding(
                    padding: const EdgeInsets.only(bottom: 100),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final track = _tracks[index];
                          return TrackTile(
                            track: track,
                            queue: _tracks,
                            onTap: () => ref.read(playerProvider.notifier).playTrack(track, _tracks),
                          );
                        },
                        childCount: _tracks.length,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _ArtistAlbum {
  final String name;
  final String artist;
  final String? cover;
  final String year;
  int count = 0;
  _ArtistAlbum(this.name, this.artist, this.cover, this.year);
}

/// Álbuns das faixas do artista, do mais novo para o mais antigo.
List<_ArtistAlbum> _albumsOf(List<Track> tracks) {
  final byName = <String, _ArtistAlbum>{};
  for (final t in tracks) {
    if (t.album.isEmpty) continue;
    final a = byName.putIfAbsent(t.album.toLowerCase(), () => _ArtistAlbum(t.album, albumArtistOf(t), t.albumArtUrl, t.releaseYear));
    a.count++;
  }
  return byName.values.toList()..sort((a, b) => b.year.compareTo(a.year));
}

class _AlbumChip extends StatelessWidget {
  final _ArtistAlbum album;
  const _AlbumChip({required this.album});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push(albumRoute(album.name, album.artist)),
      child: SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(color: AppColors.surface, border: Border.all(color: AppColors.border)),
              child: album.cover != null
                  ? CachedNetworkImage(imageUrl: album.cover!, fit: BoxFit.cover, memCacheWidth: 260)
                  : const Icon(Icons.album_rounded, color: AppColors.textMuted, size: 40),
            ),
            const SizedBox(height: 6),
            Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w700)),
            Text([if (album.year.isNotEmpty) album.year, '${album.count} música${album.count == 1 ? '' : 's'}'].join(' · '),
                maxLines: 1, style: const TextStyle(color: AppColors.textMuted, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
