import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/database/database.dart';
import '../data/models/player_state.dart' as app;
import '../data/models/track.dart';
import '../providers/player_provider.dart';
import 'widgets/track_tile.dart';

class ArtistScreen extends ConsumerStatefulWidget {
  final String artistName;

  const ArtistScreen({super.key, required this.artistName});

  @override
  ConsumerState<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends ConsumerState<ArtistScreen> {
  List<Track> _artistTracks = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    final tracks = await AppDatabase.instance.getTracksForArtist(widget.artistName);
    setState(() {
      _artistTracks = tracks;
      _isLoading = false;
    });
  }

  Future<void> _showMergeDialog() async {
    final textController = TextEditingController();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Mesclar artista', style: TextStyle(color: AppColors.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Digite o nome do artista com o qual deseja unificar "${widget.artistName}":',
              style: TextStyle(color: AppColors.textSecond, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              style: TextStyle(color: AppColors.textPrimary),
              decoration: const InputDecoration(
                hintText: 'Nome do artista destino',
                hintStyle: TextStyle(color: Colors.white38),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
            child: const Text('Mesclar', style: TextStyle(color: Colors.black)),
          ),
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
    final downloadedTracks = _artistTracks.where((t) => t.available).toList();
    final coverArt = _artistTracks.firstWhere((t) => t.albumArtUrl != null, orElse: () => _artistTracks.isNotEmpty ? _artistTracks.first : Track(id: '', spotifyUri: '', title: '', artist: '', playlistId: '')).albumArtUrl;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverAppBar(
                  pinned: true,
                  backgroundColor: AppColors.bg,
                  elevation: 0,
                  title: Text(
                    widget.artistName,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  actions: [
                    IconButton(
                      icon: const Icon(Icons.merge_type_rounded, color: AppColors.textPrimary),
                      tooltip: 'Mesclar Artista',
                      onPressed: _showMergeDialog,
                    ),
                  ],
                ),
                SliverToBoxAdapter(
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.bg,
                    ),
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 1. Centered square cover image
                        Center(
                          child: Container(
                            width: 180,
                            height: 180,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: AppColors.accent,
                                width: 2.0,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.accent.withOpacity(0.3),
                                  blurRadius: 20,
                                  spreadRadius: 2,
                                )
                              ],
                            ),
                            child: ClipOval(
                              child: coverArt != null
                                  ? CachedNetworkImage(
                                      imageUrl: coverArt,
                                      fit: BoxFit.cover,
                                    )
                                  : Container(color: AppColors.surface),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),

                        // 2. Action Row: Stats & Green Circular Play/Shuffle Buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Artist Stats info
                            Expanded(
                              child: Text(
                                '${_artistTracks.length} músicas • ${downloadedTracks.length} baixadas',
                                style: const TextStyle(
                                  color: AppColors.textSecond,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            // Spotify-style Green circular Play & Shuffle Buttons
                            if (downloadedTracks.isNotEmpty)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Shuffle Play (Shuffle)
                                  GestureDetector(
                                    onTap: () => ref.read(playerProvider.notifier).playQueueWithShuffle(
                                      downloadedTracks,
                                      shuffleMode: app.ShuffleMode.random,
                                    ),
                                    child: Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(color: AppColors.accent, width: 1.5),
                                        color: Colors.transparent,
                                      ),
                                      child: Center(
                                        child: Icon(
                                          Icons.shuffle_rounded,
                                          size: 20,
                                          color: AppColors.accent,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  // Standard Play
                                  GestureDetector(
                                    onTap: () => ref.read(playerProvider.notifier).playQueueWithShuffle(
                                      downloadedTracks,
                                      shuffleMode: app.ShuffleMode.off,
                                    ),
                                    child: Container(
                                      width: 52,
                                      height: 52,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: AppColors.accent,
                                        boxShadow: [
                                          BoxShadow(
                                            color: AppColors.accent.withOpacity(0.4),
                                            blurRadius: 12,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      child: const Center(
                                        child: Icon(
                                          Icons.play_arrow_rounded,
                                          size: 32,
                                          color: Colors.black,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final track = _artistTracks[index];
                      return TrackTile(
                        track: track,
                        queue: _artistTracks,
                        onTap: () {
                          ref.read(playerProvider.notifier).playTrack(track, _artistTracks);
                        },
                      );
                    },
                    childCount: _artistTracks.length,
                  ),
                ),
              ],
            ),
      ),
    );
  }
}
