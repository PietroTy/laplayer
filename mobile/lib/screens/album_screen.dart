import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../data/database/database.dart';
import '../data/models/track.dart';
import '../providers/player_provider.dart';
import 'widgets/collection_header.dart';
import 'widgets/track_tile.dart';

/// Artista "dono" do álbum de uma faixa (o do álbum, ou o principal da faixa).
String albumArtistOf(Track t) =>
    t.albumArtist.isNotEmpty ? t.albumArtist : (t.artistNames.isNotEmpty ? t.artistNames.first : t.artist);

String albumRoute(String album, String artist) =>
    '/album?name=${Uri.encodeQueryComponent(album)}&artist=${Uri.encodeQueryComponent(artist)}';

String artistRoute(String artist) => '/artist/${Uri.encodeComponent(artist)}';

/// Página do álbum: capa, artista (abre a página dele), ano, números e as faixas na ordem do disco.
class AlbumScreen extends ConsumerStatefulWidget {
  final String albumName;
  final String artist; // vazio: qualquer artista com um álbum desse nome

  const AlbumScreen({super.key, required this.albumName, this.artist = ''});

  @override
  ConsumerState<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends ConsumerState<AlbumScreen> {
  List<Track> _tracks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var tracks = await AppDatabase.instance.getTracksForAlbum(widget.albumName);
    // Álbuns diferentes com o mesmo nome ("Greatest Hits") ficam separados pelo artista.
    if (widget.artist.isNotEmpty) {
      final a = widget.artist.toLowerCase();
      final same = tracks.where((t) => albumArtistOf(t).toLowerCase() == a || t.artistNames.any((n) => n.toLowerCase() == a)).toList();
      if (same.isNotEmpty) tracks = same;
    }
    // A mesma faixa pode estar em várias playlists: aparece uma vez só.
    final seen = <String>{};
    tracks = tracks.where((t) => seen.add(t.id.isNotEmpty ? t.id : '${t.title}|${t.artist}')).toList()
      ..sort((x, y) => x.discNumber != y.discNumber ? x.discNumber.compareTo(y.discNumber) : x.trackNumber.compareTo(y.trackNumber));
    if (mounted) setState(() { _tracks = tracks; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final playable = _tracks.where((t) => t.available).toList();
    final cover = _tracks.map((t) => t.albumArtUrl).firstWhere((u) => u != null, orElse: () => null);
    final artist = widget.artist.isNotEmpty ? widget.artist : (_tracks.isNotEmpty ? albumArtistOf(_tracks.first) : '');
    final year = _tracks.map((t) => t.releaseYear).firstWhere((y) => y.isNotEmpty, orElse: () => '');

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: CollectionHeader(
                      coverUrl: cover,
                      placeholderIcon: Icons.album_rounded,
                      kind: 'ÁLBUM',
                      title: widget.albumName,
                      subtitle: artist.isEmpty
                          ? null
                          : InkWell(
                              onTap: () => context.push(artistRoute(artist)),
                              child: Text(
                                [artist, if (year.isNotEmpty) year].join(' · '),
                                style: TextStyle(color: AppColors.accent, fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                            ),
                      stats: collectionStats(_tracks, playable),
                      playable: playable,
                    ),
                  ),
                  const SliverToBoxAdapter(child: SectionLabel('FAIXAS')),
                  SliverPadding(
                    padding: const EdgeInsets.only(bottom: 100),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => TrackTile(
                          track: _tracks[i],
                          queue: _tracks,
                          showIndex: false,
                          onTap: () => ref.read(playerProvider.notifier).playTrack(_tracks[i], _tracks),
                        ),
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
