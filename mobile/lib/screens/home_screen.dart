import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shimmer/shimmer.dart';

import '../core/theme.dart';
import '../data/models/playlist.dart';
import '../data/models/track.dart';
import '../data/services/sync_service.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../data/database/database.dart';
import 'widgets/track_tile.dart';
import 'widgets/app_logo.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    final recent    = ref.watch(recentlyPlayedProvider);
    final sync      = ref.watch(syncProvider);
    final dashboardAsync = ref.watch(dashboardDataProvider);
    final currentPeriod = ref.watch(mostPlayedPeriodProvider);

    // Escuta erros de exclusão ou outras ações da biblioteca
    ref.listen<AsyncValue<void>>(libraryProvider, (prev, next) {
      if (next is AsyncError) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro na biblioteca: ${next.error}'), backgroundColor: AppColors.error),
        );
      }
    });

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: CustomScrollView(
        slivers: [
          // ── AppBar ──────────────────────────────────────────────────────
          // ── AppBar Glassmórfico ───────────────────────────────────────────
          SliverAppBar(
            pinned: true,
            backgroundColor: AppColors.bg,
            elevation: 0,
            title: const AppLogo(
              size: 30,
              showText: true,
              textFontSize: 22,
            ),
          ),

          // ── Dashboard de Histórico ───────────────────────────────────────
          dashboardAsync.when(
            loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
            error: (_, __) => const SliverToBoxAdapter(child: SizedBox.shrink()),
            data: (data) {
              if (data.totalStreamsCount == 0) {
                return const SliverToBoxAdapter(child: SizedBox.shrink());
              }
              return SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 16, 20, 12),
                      child: Text(
                        'Meu Dashboard',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 80,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: _buildMetricCard(
                                "Tempo Ouvido",
                                _formatPlayTime(data.totalPlayTimeMs),
                                Icons.access_time_rounded,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _buildMetricCard(
                                "Músicas",
                                "${data.uniqueTracksCount}",
                                Icons.music_note_rounded,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _buildMetricCard(
                                "Streams",
                                "${data.totalStreamsCount}",
                                Icons.play_circle_fill_rounded,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.glassSurface,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
                          boxShadow: AppColors.premiumShadow,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.star_rounded, color: AppColors.accent, size: 20),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'Mais Ouvidas',
                                      style: TextStyle(
                                        color: AppColors.textPrimary,
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                Theme(
                                  data: Theme.of(context).copyWith(
                                    focusColor: Colors.transparent,
                                    hoverColor: Colors.transparent,
                                    splashColor: Colors.transparent,
                                    highlightColor: Colors.transparent,
                                  ),
                                  child: PopupMenuButton<String>(
                                    initialValue: currentPeriod,
                                    onSelected: (value) {
                                      ref.read(mostPlayedPeriodProvider.notifier).state = value;
                                    },
                                    tooltip: 'Filtrar período',
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: AppColors.surfaceHigh,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: AppColors.border, width: 0.8),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            currentPeriod == 'semana'
                                                ? 'Semana'
                                                : currentPeriod == 'mes'
                                                    ? 'Mês'
                                                    : currentPeriod == 'ano'
                                                        ? 'Ano'
                                                        : 'Tudo',
                                            style: TextStyle(
                                              color: AppColors.accent,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          const Icon(
                                            Icons.keyboard_arrow_down_rounded,
                                            color: AppColors.textMuted,
                                            size: 14,
                                          ),
                                        ],
                                      ),
                                    ),
                                    itemBuilder: (ctx) => [
                                      const PopupMenuItem(
                                        value: 'semana',
                                        child: Text('Semana', style: TextStyle(color: Colors.white, fontSize: 13)),
                                      ),
                                      const PopupMenuItem(
                                        value: 'mes',
                                        child: Text('Mês', style: TextStyle(color: Colors.white, fontSize: 13)),
                                      ),
                                      const PopupMenuItem(
                                        value: 'ano',
                                        child: Text('Ano', style: TextStyle(color: Colors.white, fontSize: 13)),
                                      ),
                                      const PopupMenuItem(
                                        value: 'alltime',
                                        child: Text('Tudo', style: TextStyle(color: Colors.white, fontSize: 13)),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (data.mostPlayed.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 24.0),
                                child: Center(
                                  child: Text(
                                    'Nenhuma reprodução este período.',
                                    style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                                  ),
                                ),
                              )
                            else
                              ...List.generate(data.mostPlayed.length, (index) {
                                final entry = data.mostPlayed[index];
                                final track = entry.key;
                                final playCount = entry.value;
                                final queue = data.mostPlayed.map((e) => e.key).toList();
                                return _buildRankingTile(index + 1, track, playCount, ref, queue);
                              }),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          // ── Playlists recentes ───────────────────────────────────────────
          _SectionHeader(title: 'Playlists', onMore: () => context.go('/library')),
          playlists.when(
            loading: () => SliverToBoxAdapter(child: _PlaylistSkeleton()),
            error: (e, _) => SliverToBoxAdapter(
              child: _ErrorCard(message: '$e'),
            ),
            data: (list) => SliverToBoxAdapter(
              child: SizedBox(
                height: 160,
                child: list.isEmpty
                    ? _EmptyState(
                        icon: Icons.library_music_rounded,
                        message: 'Nenhuma playlist.\nFaca um sync para comecar.',
                      )
                    : ListView.builder(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: list.length,
                        itemBuilder: (_, i) => _PlaylistCard(playlist: list[i]),
                      ),
              ),
            ),
          ),

          // ── Tocados recentemente ─────────────────────────────────────────
          _SectionHeader(title: 'Tocados recentemente'),
          recent.when(
            loading: () => SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, __) => _TrackSkeleton(), childCount: 5,
              ),
            ),
            error: (_, __) => const SliverToBoxAdapter(child: SizedBox.shrink()),
            data: (tracks) => tracks.isEmpty
                ? const SliverToBoxAdapter(child: SizedBox.shrink())
                : SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (_, i) {
                        final track = tracks[i];
                        return TrackTile(
                          track: track,
                          queue: tracks,
                          onTap: () async {
                            final idx = tracks.indexWhere((t) => t.id == track.id);
                            if (idx >= 0) {
                              ref.read(playerProvider.notifier).playQueue(tracks, startIndex: idx);
                            } else {
                              ref.read(playerProvider.notifier).playTrack(track, tracks);
                            }
                          },
                        );
                      },
                      childCount: tracks.take(8).length,
                    ),
                  ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 100)),
        ],
      ),
    ),
  );
  }

  String _formatPlayTime(int ms) {
    final minutes = ms ~/ 60000;
    if (minutes < 60) {
      return '$minutes min';
    }
    final hours = minutes / 60.0;
    if (hours < 24) {
      return '${hours.toStringAsFixed(1)} h';
    }
    final days = hours / 24.0;
    return '${days.toStringAsFixed(1)} dias';
  }

  Widget _buildMetricCard(String title, String value, IconData icon) {
    return Container(
      width: 140,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.glassSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border.withValues(alpha: 0.5)),
        boxShadow: AppColors.premiumShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, color: AppColors.accent, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: AppColors.textMuted, fontSize: 10, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildRankingTile(int rank, Track track, int plays, WidgetRef ref, List<Track> queue) {
    return InkWell(
      onTap: () {
        ref.read(playerProvider.notifier).playQueue(queue, startIndex: rank - 1);
      },
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: rank == 1 ? AppColors.accent : AppColors.surfaceHigh,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  '$rank',
                  style: TextStyle(
                    color: rank == 1 ? Colors.black : AppColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: track.albumArtUrl != null
                  ? CachedNetworkImage(
                      imageUrl: track.albumArtUrl!,
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      width: 40,
                      height: 40,
                      color: AppColors.surfaceHigh,
                      child: const Icon(Icons.music_note_rounded, color: AppColors.textMuted, size: 20),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    track.artist,
                    style: const TextStyle(
                      color: AppColors.textSecond,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_arrow_rounded, color: AppColors.accent, size: 14),
                  const SizedBox(width: 2),
                  Text(
                    '$plays',
                    style: TextStyle(
                      color: AppColors.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
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

// ── Sub-widgets ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String    title;
  final VoidCallback? onMore;
  const _SectionHeader({required this.title, this.onMore});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(title,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (onMore != null)
              TextButton(
                onPressed: onMore,
                child: Text('Ver tudo',
                  style: TextStyle(color: AppColors.accent, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistCard extends ConsumerWidget {
  final Playlist playlist;
  const _PlaylistCard({required this.playlist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => context.push(
        '/library/playlist/${playlist.id}?name=${Uri.encodeComponent(playlist.name)}',
      ),
      onLongPress: () {
        showModalBottomSheet(
          context: context,
          backgroundColor: AppColors.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('Playlist: ${playlist.name}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_forever_rounded, color: AppColors.error),
                  title: const Text('Remover Playlist', style: TextStyle(color: AppColors.error)),
                  subtitle: const Text('Apaga arquivos no servidor e no celular'),
                  onTap: () {
                    Navigator.pop(context);
                    _showDeleteConfirm(context, ref);
                  },
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        );
      },
      child: Container(
        width: 130,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 130, height: 130,
                decoration: const BoxDecoration(
                  color: AppColors.surfaceHigh,
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: playlist.imageUrl.isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: playlist.imageUrl,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => _fallbackGradient(),
                            )
                          : _fallbackGradient(),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.65),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${playlist.downloaded}/${playlist.totalTracks}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    if (playlist.totalTracks > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: SizedBox(
                          height: 3,
                          child: LinearProgressIndicator(
                            value: playlist.progress,
                            backgroundColor: Colors.transparent,
                            color: playlist.isComplete ? AppColors.accent : AppColors.accentDim,
                            minHeight: 3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: Text(
                playlist.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fallbackGradient() => Container(
        color: AppColors.surfaceHigh,
        child: Center(
          child: Icon(Icons.library_music_rounded, color: AppColors.accent, size: 36),
        ),
      );

  void _showDeleteConfirm(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        title: const Text('Apagar Playlist?'),
        content: Text('Isso removerá "${playlist.name}" e todos os arquivos baixados permanentemente.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(libraryProvider.notifier).deletePlaylist(playlist.id);
            },
            child: const Text('APAGAR', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String   message;
  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: AppColors.textMuted, size: 32),
          const SizedBox(height: 8),
          Text(message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard({required this.message});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(message,
        style: const TextStyle(color: AppColors.error, fontSize: 13),
      ),
    );
  }
}

class _PlaylistSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 160,
      child: Shimmer.fromColors(
        baseColor: AppColors.surfaceHigh,
        highlightColor: AppColors.border,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: 4,
          itemBuilder: (_, __) => Container(
            width: 130, height: 130,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.surfaceHigh,
      highlightColor: AppColors.border,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const SizedBox(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(height: 14, width: double.infinity, color: Colors.white),
                  const SizedBox(height: 6),
                  Container(height: 12, width: 120, color: Colors.white),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
