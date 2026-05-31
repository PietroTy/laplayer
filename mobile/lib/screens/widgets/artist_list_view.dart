import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/database/database.dart';
import '../../data/models/artist_group.dart';
import '../../data/models/track.dart';
import '../../providers/player_provider.dart';
import '../../data/models/player_state.dart' as app;
import 'track_tile.dart';

class ArtistListView extends ConsumerWidget {
  final List<ArtistGroup> artists;
  final String? playlistId;

  const ArtistListView({
    super.key,
    required this.artists,
    this.playlistId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (artists.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 60),
        child: Center(
          child: Text('Nenhum artista encontrado.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
        ),
      );
    }

    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 100),
      itemCount: artists.length,
      separatorBuilder: (_, __) => Divider(
        color: AppColors.border.withOpacity(0.3), height: 1,
        indent: 72,
      ),
      itemBuilder: (context, i) => _ArtistTile(
        artist: artists[i],
        playlistId: playlistId,
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
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: AppColors.surfaceHigh,
        child: const Icon(Icons.person_rounded, color: AppColors.textMuted, size: 24),
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
      onTap: () => _showArtistSheet(context, ref),
    );
  }

  void _showArtistSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ArtistTracksSheet(artist: artist, playlistId: playlistId),
    );
  }
}

class _ArtistTracksSheet extends ConsumerStatefulWidget {
  final ArtistGroup artist;
  final String? playlistId;
  const _ArtistTracksSheet({required this.artist, this.playlistId});

  @override
  ConsumerState<_ArtistTracksSheet> createState() => _ArtistTracksSheetState();
}

class _ArtistTracksSheetState extends ConsumerState<_ArtistTracksSheet> {
  List<Track> _tracks = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final tracks = await AppDatabase.instance.getTracksForArtist(
      widget.artist.name,
      playlistId: widget.playlistId,
    );
    if (mounted) setState(() { _tracks = tracks; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    final available = _tracks.where((t) => t.isCached).toList();

    // Agrupa por álbum para exibição
    final Map<String, List<Track>> byAlbum = {};
    for (final t in _tracks) {
      (byAlbum[t.album.isNotEmpty ? t.album : 'Sem álbum'] ??= []).add(t);
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      expand: false,
      builder: (_, controller) => Column(
        children: [
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
          // Header do artista
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: AppColors.surfaceHigh,
                  child: const Icon(Icons.person_rounded, color: AppColors.textMuted, size: 32),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.artist.name,
                        style: const TextStyle(
                          color: AppColors.textPrimary, fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${widget.artist.totalTracks} músicas • ${widget.artist.albumCount} álbuns',
                        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                      ),
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
                        shape: BoxShape.circle, color: AppColors.accent,
                      ),
                      child: const Icon(Icons.play_arrow_rounded,
                        color: Colors.black, size: 24),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(color: AppColors.border, height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    controller: controller,
                    padding: const EdgeInsets.only(bottom: 100),
                    children: byAlbum.entries.map((entry) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                          child: Text(entry.key,
                            style: TextStyle(
                              color: AppColors.accent.withOpacity(0.8),
                              fontSize: 11, fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        ...entry.value.map((t) => TrackTile(
                          track: t,
                          queue: available,
                          showIndex: false,
                        )),
                      ],
                    )).toList(),
                  ),
          ),
        ],
      ),
    );
  }
}
