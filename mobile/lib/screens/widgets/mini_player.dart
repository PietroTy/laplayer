import 'dart:ui';
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: GestureDetector(
        onTap: () => context.push('/player'),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.glassSurfaceHigh,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
                boxShadow: AppColors.premiumShadow,
              ),
              child: Stack(
                children: [
                  // ── Barra de progresso integrada na base ────────────────
                  Positioned(
                    left: 0, right: 0, bottom: 0,
                    child: SizedBox(
                      height: 3,
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        backgroundColor: Colors.transparent,
                        color: AppColors.accent,
                      ),
                    ),
                  ),
                  
                  // ── Conteúdo do Mini Player ──────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        // Album art animada
                        Hero(
                          tag: 'album_art_${track.id}',
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0.9, end: isPlaying ? 1.0 : 0.95),
                            duration: const Duration(milliseconds: 300),
                            builder: (context, scale, child) {
                              return Transform.scale(
                                scale: scale,
                                child: Container(
                                  width: 44, height: 44,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    boxShadow: [
                                      BoxShadow(color: Colors.black45, blurRadius: 8, offset: Offset(0, 4))
                                    ],
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: track.albumArtUrl != null
                                        ? CachedNetworkImage(
                                            imageUrl: track.albumArtUrl!,
                                            fit: BoxFit.cover,
                                            errorWidget: (_, __, ___) => const _ArtPlaceholder(size: 44),
                                          )
                                        : const _ArtPlaceholder(size: 44),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 14),

                        // Title + Artist
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                track.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.textSecond,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Controls
                        IconButton(
                          icon: const Icon(Icons.skip_previous_rounded),
                          color: Colors.white70,
                          iconSize: 28,
                          onPressed: player.previous,
                        ),
                        GestureDetector(
                          onTap: player.togglePlay,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width:  40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: isPlaying ? AppColors.accent : Colors.white10,
                              shape: BoxShape.circle,
                            ),
                            child: isLoading
                                ? const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                    color: isPlaying ? Colors.black : Colors.white,
                                    size: 24,
                                  ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.skip_next_rounded),
                          color: Colors.white70,
                          iconSize: 28,
                          onPressed: player.next,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
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
