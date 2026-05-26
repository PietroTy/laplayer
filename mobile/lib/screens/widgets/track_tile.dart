import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models/track.dart';
import '../../data/services/sync_service.dart';
import '../../providers/player_provider.dart';

class TrackTile extends ConsumerWidget {
  final Track         track;
  final List<Track>   queue;
  final bool          showIndex;
  final VoidCallback? onTap;

  const TrackTile({
    super.key,
    required this.track,
    required this.queue,
    this.showIndex = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Performance: Só reconstrói se este ID específico for o ativo
    final isActive = ref.watch(currentTrackProvider.select((t) => t?.id == track.id));
    final isPlaying = isActive ? ref.watch(isPlayingProvider) : false;
    
    final isDownloaded = track.isCached;
    final downloadProgress = ref.watch(downloadProgressProvider(track.id));
    final isDownloading = track.downloadStatus == 'downloading';

    final tile = InkWell(
      onTap: isDownloaded 
          ? (onTap ?? () => ref.read(playerProvider.notifier).playTrack(track, queue))
          : (isDownloading
              ? () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Aguarde o download da música concluir.'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              : () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Sincronize primeiro para baixar esta música.'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }),
      borderRadius: BorderRadius.circular(8),
      child: Opacity(
        opacity: isDownloaded ? 1.0 : (isDownloading ? 0.7 : 0.4), // Opacidade dinâmica
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // Leading: index or album art
              if (showIndex)
                SizedBox(
                  width: 36,
                  child: isActive
                      ? _PlayingIndicator(isPlaying: isPlaying)
                      : Text(
                          '${track.playlistPosition}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isActive ? AppColors.accent : AppColors.textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                )
              else
                _AlbumArt(url: track.albumArtUrl, isActive: isActive),

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
                      style: TextStyle(
                        color: isActive ? AppColors.accent : AppColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (track.explicit)
                          Container(
                            margin: const EdgeInsets.only(right: 5),
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.textMuted,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text('E',
                              style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.w800),
                            ),
                          ),
                        Expanded(
                          child: Text(
                            isDownloading
                                ? 'Baixando... ${downloadProgress != null ? (downloadProgress * 100).toStringAsFixed(0) : '0'}%'
                                : track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isDownloading ? AppColors.accent : AppColors.textSecond,
                              fontSize: 12,
                              fontWeight: isDownloading ? FontWeight.w500 : FontWeight.normal,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Duration + availability + 3-dot menu
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    track.durationFormatted,
                    style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  if (isDownloaded)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 14,
                      color: AppColors.accent,
                    )
                  else if (isDownloading)
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: downloadProgress,
                        valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                        backgroundColor: Colors.white10,
                      ),
                    )
                  else
                    GestureDetector(
                      onTap: () => ref.read(syncProvider.notifier).retryTrackDownload(track),
                      child: const Padding(
                        padding: EdgeInsets.only(left: 8, top: 4, bottom: 4),
                        child: Icon(Icons.refresh_rounded, size: 16, color: AppColors.textMuted),
                      ),
                    ),
                ],
              ),

              // 3-dot menu (só mostra se tiver playlist)
              if (track.playlistId.isNotEmpty)
                _TrackMenu(track: track),

            ],
          ),
        ),
      ),
    );

    if (!isDownloaded) return tile;

    return Dismissible(
      key: ValueKey('swipe_queue_${track.id}_${track.playlistPosition}'),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (direction) async {
        await ref.read(playerProvider.notifier).addToQueue(track);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('"${track.title}" adicionada à fila'),
              duration: const Duration(seconds: 1),
              backgroundColor: AppColors.accent,
            ),
          );
        }
        return false;
      },
      background: Container(
        color: AppColors.accent.withOpacity(0.8),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: const Icon(Icons.queue_music_rounded, color: Colors.black),
      ),
      child: tile,
    );
  }
}

class _AlbumArt extends StatelessWidget {
  final String? url;
  final bool    isActive;
  const _AlbumArt({this.url, required this.isActive});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: url != null
          ? CachedNetworkImage(
              imageUrl:   url!,
              width:  44, height: 44, fit: BoxFit.cover,
              memCacheWidth: 100,  // Reduz drasticamente o uso de RAM
              memCacheHeight: 100,
              errorWidget: (_, __, ___) => _placeholder(),
            )
          : _placeholder(),
    );
  }

  Widget _placeholder() => Container(
    width: 44, height: 44,
    color: AppColors.surfaceHigh,
    child: Icon(Icons.music_note_rounded, color: AppColors.textMuted, size: 18),
  );
}

class _PlayingIndicator extends StatefulWidget {
  final bool isPlaying;
  const _PlayingIndicator({required this.isPlaying});
  @override
  State<_PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<_PlayingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36, height: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) {
              final h = widget.isPlaying
                  ? 4.0 + (_ctrl.value + i * 0.3).clamp(0, 1) * 12
                  : 4.0;
              return Container(
                width: 3, height: h,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

// ── Menu de 3 pontinhos da track ───────────────────────────────────────────

enum _TrackMenuAction { addToQueue, redownload }

class _TrackMenu extends ConsumerWidget {
  final Track track;
  const _TrackMenu({required this.track});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_TrackMenuAction>(
      icon: const Icon(Icons.more_vert_rounded, size: 18, color: AppColors.textMuted),
      padding: EdgeInsets.zero,
      color: AppColors.surfaceHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (action) => _handleAction(context, ref, action),
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _TrackMenuAction.addToQueue,
          child: Row(children: [
            Icon(Icons.queue_music_rounded, size: 18, color: AppColors.textSecond),
            SizedBox(width: 10),
            Text('Adicionar à fila', style: TextStyle(color: AppColors.textPrimary, fontSize: 14)),
          ]),
        ),
        if (track.isCached)
          const PopupMenuItem(
            value: _TrackMenuAction.redownload,
            child: Row(children: [
              Icon(Icons.swap_horiz_rounded, size: 18, color: Colors.orange),
              SizedBox(width: 10),
              Text('Baixar versão alternativa', style: TextStyle(color: Colors.orange, fontSize: 14)),
            ]),
          ),
      ],
    );
  }

  void _handleAction(BuildContext context, WidgetRef ref, _TrackMenuAction action) {
    switch (action) {
      case _TrackMenuAction.addToQueue:
        ref.read(playerProvider.notifier).addToQueue(track);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${track.title} adicionada à fila'),
            duration: const Duration(seconds: 2),
          ),
        );

      case _TrackMenuAction.redownload:
        _showRedownloadDialog(context, ref);
    }
  }

  void _showRedownloadDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Baixar versão alternativa',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(
          'A versão atual de "${track.title}" será substituída pela próxima melhor correspondência no YouTube.\n\nUse isso se a versão baixada estiver errada (ao contrário, cover, etc).',
          style: const TextStyle(color: AppColors.textSecond, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: const Icon(Icons.swap_horiz_rounded, size: 16),
            label: const Text('Rebaixar'),
            onPressed: () async {
              Navigator.pop(ctx);
              if (!context.mounted) return;

              final currentSkip = ref.read(trackSkipMatchesProvider(track.id));
              final nextSkip = currentSkip + 1;
              ref.read(trackSkipMatchesProvider(track.id).notifier).state = nextSkip;

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Buscando versão alternativa $nextSkip de "${track.title}"...'),
                  duration: const Duration(seconds: 4),
                  backgroundColor: Colors.orange.shade800,
                ),
              );

              try {
                // Usa o downloader nativo (no celular, sem precisar do servidor PC)
                final ok = await ref.read(syncProvider.notifier).redownloadAlternative(
                  track,
                  skipMatch: nextSkip,
                );

                if (context.mounted) {
                  if (ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Versão alternativa de "${track.title}" baixada!'),
                        duration: const Duration(seconds: 4),
                        backgroundColor: Colors.green.shade800,
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Nenhuma versão alternativa encontrada no YouTube.'),
                        duration: Duration(seconds: 4),
                      ),
                    );
                  }
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Erro: $e'),
                      duration: const Duration(seconds: 5),
                      backgroundColor: Colors.red.shade800,
                    ),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }
}
