import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../providers/player_provider.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track     = ref.watch(currentTrackProvider);
    final isPlaying = ref.watch(isPlayingProvider);
    final position  = ref.watch(playerPositionProvider);
    final duration  = ref.watch(playerDurationProvider);
    final isLoading = ref.watch(playerProvider).isLoading;
    final player    = ref.read(playerProvider.notifier);

    if (track == null) return const SizedBox.shrink();

    final progress = duration.inMilliseconds > 0
        ? position.inMilliseconds / duration.inMilliseconds
        : 0.0;

    return GestureDetector(
      onTap: () => context.push('/player'),
      child: Container(
        color: AppColors.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Progress bar
            LinearProgressIndicator(
              value:            progress.clamp(0.0, 1.0),
              backgroundColor:  AppColors.border,
              color:            AppColors.accent,
              minHeight:        2,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  // Album art
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: track.albumArtUrl != null
                        ? CachedNetworkImage(
                            imageUrl: track.albumArtUrl!,
                            width:    44,
                            height:   44,
                            fit:      BoxFit.cover,
                            errorWidget: (_, __, ___) => _ArtPlaceholder(size: 44),
                          )
                        : _ArtPlaceholder(size: 44),
                  ),
                  const SizedBox(width: 12),

                  // Title + Artist
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.textSecond,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Controls
                  IconButton(
                    icon: const Icon(Icons.skip_previous_rounded),
                    color: AppColors.textSecond,
                    iconSize: 26,
                    onPressed: player.previous,
                  ),
                  GestureDetector(
                    onTap: player.togglePlay,
                    child: Container(
                      width:  38,
                      height: 38,
                      decoration: BoxDecoration(
                        color:  AppColors.accent,
                        shape:  BoxShape.circle,
                      ),
                      child: isLoading
                          ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: CircularProgressIndicator(
                                color: Colors.black,
                                strokeWidth: 2,
                              ),
                            )
                          : Icon(
                              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: Colors.black,
                              size:  22,
                            ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next_rounded),
                    color: AppColors.textSecond,
                    iconSize: 26,
                    onPressed: player.next,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtPlaceholder extends StatelessWidget {
  final double size;
  const _ArtPlaceholder({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Icon(Icons.music_note_rounded, color: AppColors.textMuted, size: 20),
    );
  }
}
