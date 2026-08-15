import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models/track.dart';
import '../../data/services/sync_service.dart';
import '../../data/database/database.dart';
import '../../providers/player_provider.dart';
import '../../providers/library_provider.dart';
import 'add_to_playlist_sheet.dart';
import 'rematch_audio_sheet.dart';

class TrackTile extends ConsumerStatefulWidget {
  final Track         track;
  final List<Track>   queue;
  final bool          showIndex;
  final VoidCallback? onTap;

  const TrackTile({
    super.key,
    required this.track,
    required this.queue,
    this.showIndex = false,
    this.isHighlighted = false,
    this.onTap,
  });

  final bool isHighlighted;

  @override
  ConsumerState<TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends ConsumerState<TrackTile> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final queue = widget.queue;
    final onTap = widget.onTap;
    final showIndex = widget.showIndex;
    
    // Performance: Só reconstrói se este ID específico for o ativo
    final isActive = ref.watch(currentTrackProvider.select((t) => t?.id == track.id));
    final isPlaying = isActive ? ref.watch(isPlayingProvider) : false;
    
    final isDownloaded = track.isCached;
    final downloadProgress = ref.watch(downloadProgressProvider(track.id));
    final isDownloading = track.downloadStatus == 'downloading';

    final tileContent = GestureDetector(
      onTapDown: (_) { if (isDownloaded) setState(() => _isPressed = true); },
      onTapUp: (_) { if (isDownloaded) setState(() => _isPressed = false); },
      onTapCancel: () { if (isDownloaded) setState(() => _isPressed = false); },
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
                    SnackBar(
                      content: Text('Iniciando download de "${track.title}"...'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                  ref.read(syncProvider.notifier).retryTrackDownload(track);
                }),
      child: AnimatedScale(
        scale: _isPressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeInOut,
        child: Container(
          decoration: BoxDecoration(
            color: widget.isHighlighted
                ? AppColors.accent.withOpacity(0.15)
                : (isActive ? AppColors.surfaceHigh.withValues(alpha: 0.5) : Colors.transparent),
            border: widget.isHighlighted
                ? Border.all(color: AppColors.accent.withOpacity(0.3))
                : null,
            borderRadius: BorderRadius.circular(12),
          ),
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
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Center(
                      child: isDownloaded
                          ? Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: AppColors.accent,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.check_rounded,
                                size: 13,
                                color: Colors.black,
                              ),
                            )
                          : (isDownloading
                              ? SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                    value: downloadProgress,
                                    valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
                                    backgroundColor: Colors.white10,
                                  ),
                                )
                              : GestureDetector(
                                  onTap: () {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Baixando "${track.title}"...'),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                    ref.read(syncProvider.notifier).retryTrackDownload(track);
                                  },
                                  child: Container(
                                    width: 18,
                                    height: 18,
                                    decoration: BoxDecoration(
                                      color: AppColors.accent,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.arrow_downward_rounded,
                                      size: 13,
                                      color: Colors.black,
                                    ),
                                  ),
                                )),
                    ),
                  ),
                ],
              ),

              // 3-dot menu
              _TrackMenu(track: track),

            ],
          ),
        ),
      ),
      ),
      ),
    );

    if (!isDownloaded) return tileContent;

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
      child: tileContent,
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
                  ? 4.0 + (_ctrl.value + i * 0.3).clamp(0, 1) * 14
                  : 4.0;
              return Container(
                width: 4, height: h,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: widget.isPlaying ? [
                    BoxShadow(color: AppColors.accent.withValues(alpha: 0.5), blurRadius: 4, spreadRadius: 1)
                  ] : [],
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

enum _TrackMenuAction { showInfo, downloadSingle, addToQueue, addToPlaylist, rematchAudio, removeFromPlaylist }

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
        PopupMenuItem(
          value: _TrackMenuAction.showInfo,
          child: Row(children: [
            Icon(Icons.info_outline_rounded, size: 18, color: AppColors.accent),
            const SizedBox(width: 10),
            const Text('Sobre a música', style: TextStyle(color: AppColors.textPrimary, fontSize: 14)),
          ]),
        ),
        if (!track.isCached)
          PopupMenuItem(
            value: _TrackMenuAction.downloadSingle,
            child: Row(children: [
              Icon(Icons.download_rounded, size: 18, color: AppColors.accent),
              const SizedBox(width: 10),
              Text('Baixar esta música', style: TextStyle(color: AppColors.accent, fontSize: 14)),
            ]),
          ),
        PopupMenuItem(
          value: _TrackMenuAction.rematchAudio,
          child: Row(children: [
            Icon(Icons.youtube_searched_for_rounded, size: 18, color: Colors.amberAccent),
            const SizedBox(width: 10),
            const Text('Trocar áudio do YouTube', style: TextStyle(color: Colors.amberAccent, fontSize: 14)),
          ]),
        ),
        PopupMenuItem(
          value: _TrackMenuAction.addToQueue,
          child: Row(children: [
            Icon(Icons.queue_music_rounded, size: 18, color: AppColors.textSecond),
            const SizedBox(width: 10),
            const Text('Adicionar à fila', style: TextStyle(color: AppColors.textPrimary, fontSize: 14)),
          ]),
        ),

        PopupMenuItem(
          value: _TrackMenuAction.addToPlaylist,
          child: Row(children: [
            Icon(Icons.playlist_add_rounded, size: 18, color: Colors.greenAccent),
            const SizedBox(width: 10),
            const Text('Adicionar a outra Playlist', style: TextStyle(color: Colors.greenAccent, fontSize: 14)),
          ]),
        ),

        if (track.playlistId.isNotEmpty)
          PopupMenuItem(
            value: _TrackMenuAction.removeFromPlaylist,
            child: Row(children: [
              Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
              const SizedBox(width: 10),
              const Text('Remover da playlist', style: TextStyle(color: Colors.redAccent, fontSize: 14)),
            ]),
          ),
      ],
    );
  }

  void _handleAction(BuildContext context, WidgetRef ref, _TrackMenuAction action) {
    switch (action) {
      case _TrackMenuAction.showInfo:
        showTrackInfoSheet(context, ref, track);
        break;

      case _TrackMenuAction.downloadSingle:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Baixando "${track.title}"...'), duration: const Duration(seconds: 2)),
        );
        ref.read(syncProvider.notifier).retryTrackDownload(track);
        break;

      case _TrackMenuAction.rematchAudio:
        showRematchAudioSheet(context, ref, track);
        break;

      case _TrackMenuAction.addToQueue:
        ref.read(playerProvider.notifier).addToQueue(track);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${track.title} adicionada à fila'),
            duration: const Duration(seconds: 2),
          ),
        );
        break;
      case _TrackMenuAction.addToPlaylist:
        showModalBottomSheet(
          context: context,
          backgroundColor: Colors.transparent,
          isScrollControlled: true,
          builder: (_) => AddToPlaylistSheet(track: track),
        );
        break;

      case _TrackMenuAction.removeFromPlaylist:
        _showRemoveFromPlaylistDialog(context, ref);
        break;
    }
  }

  void _showRemoveFromPlaylistDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remover da Playlist',
            style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(
          'Deseja remover "${track.title}" desta playlist?\nO arquivo de áudio local também será excluído.',
          style: const TextStyle(color: AppColors.textSecond, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              
              // 1. Tenta deletar o arquivo físico local
              try {
                final path = await ref.read(syncProvider.notifier).localPathForTrack(track);
                if (path != null) {
                  final file = File(path);
                  if (await file.exists()) {
                    await file.delete();
                  }
                }
              } catch (e) {
                print('Erro ao deletar arquivo de áudio: $e');
              }

              // 2. Remove do SQLite
              await AppDatabase.instance.deleteTrack(track.id);

              // 3. Atualiza providers para re-renderizar a tela
              ref.invalidate(playlistsProvider);
              ref.invalidate(playlistTracksProvider(track.playlistId));

              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('"${track.title}" removida com sucesso.'),
                    backgroundColor: Colors.red.shade900,
                  ),
                );
              }
            },
            child: const Text('Remover'),
          ),
        ],
      ),
    );
  }
}

// ── Método de Exibição das Informações Completas da Música ─────────────────
void showTrackInfoSheet(BuildContext context, WidgetRef ref, Track track) async {
  final path = await ref.read(syncProvider.notifier).localPathForTrack(track);

  if (!context.mounted) return;

  showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) {
      final formattedDuration = () {
        final d = Duration(milliseconds: track.durationMs);
        final min = d.inMinutes;
        final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
        return '$min:$sec';
      }();

      return DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          return SingleChildScrollView(
            controller: scrollController,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Barra de arraste superior
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Header da música (Capa, Título, Artista, Álbum)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 80, height: 80,
                          color: AppColors.bg,
                          child: track.albumArtUrl != null && track.albumArtUrl!.isNotEmpty
                              ? Image.network(
                                  track.albumArtUrl!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => const Icon(Icons.music_note_rounded, color: AppColors.textMuted),
                                )
                              : const Icon(Icons.music_note_rounded, color: AppColors.textMuted),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.textSecond,
                                fontSize: 14,
                              ),
                            ),
                            if (track.album.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                track.album,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppColors.textMuted,
                                  fontSize: 12,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Divider(color: Colors.white12, height: 1),
                  const SizedBox(height: 16),

                  // ── INFORMAÇÕES DO ARQUIVO (IO/FÍSICO) ─────────────────
                  _buildSectionHeader('Arquivos e Armazenamento'),
                  _buildInfoRow(
                    icon: Icons.sd_storage_rounded,
                    label: 'Status do arquivo',
                    value: track.isCached ? 'Salvo localmente (Offline)' : 'Não instalado (Pendente)',
                    valueColor: track.isCached ? AppColors.accent : Colors.redAccent,
                  ),
                  if (track.isCached) ...[
                    _buildInfoRow(
                      icon: Icons.file_present_rounded,
                      label: 'Nome do arquivo',
                      value: track.localFilename ?? 'Não disponível',
                    ),
                    _buildInfoRow(
                      icon: Icons.folder_open_rounded,
                      label: 'Diretório completo',
                      value: path ?? 'Não disponível',
                      isPath: true,
                    ),
                  ],
                  _buildInfoRow(
                    icon: Icons.timer_rounded,
                    label: 'Duração',
                    value: '$formattedDuration (${track.durationMs} ms)',
                  ),
                  const SizedBox(height: 16),

                  // ── INFORMAÇÕES DO SPOTIFY (METADADOS) ────────────────
                  _buildSectionHeader('Metadados do Spotify'),
                  _buildInfoRow(
                    icon: Icons.fingerprint_rounded,
                    label: 'ISRC (Código de Registro)',
                    value: track.isrc.isNotEmpty ? track.isrc : 'Não disponível',
                  ),
                  _buildInfoRow(
                    icon: Icons.perm_identity_rounded,
                    label: 'Artista Primário',
                    value: track.primaryArtist.isNotEmpty ? track.primaryArtist : track.artist,
                  ),
                  _buildInfoRow(
                    icon: Icons.art_track_rounded,
                    label: 'Artista do Álbum',
                    value: track.albumArtist.isNotEmpty ? track.albumArtist : 'Não disponível',
                  ),
                  _buildInfoRow(
                    icon: Icons.date_range_rounded,
                    label: 'Data de Lançamento',
                    value: track.releaseDate.isNotEmpty ? track.releaseDate : (track.releaseYear.isNotEmpty ? track.releaseYear : 'Não disponível'),
                  ),
                  _buildInfoRow(
                    icon: Icons.numbers_rounded,
                    label: 'Faixa nº / Total',
                    value: '${track.trackNumber} de ${track.totalTracks}',
                  ),
                  if (track.discNumber > 1)
                    _buildInfoRow(
                      icon: Icons.album_rounded,
                      label: 'Volume / Disco nº',
                      value: 'Disco ${track.discNumber}',
                    ),
                  _buildInfoRow(
                    icon: Icons.explicit_rounded,
                    label: 'Conteúdo explícito',
                    value: track.explicit ? 'Sim' : 'Não',
                    valueColor: track.explicit ? Colors.redAccent : Colors.greenAccent,
                  ),
                  _buildInfoRow(
                    icon: Icons.link_rounded,
                    label: 'Spotify URI',
                    value: track.spotifyUri,
                  ),
                  const SizedBox(height: 16),

                  // ── GÊNEROS (TAGS COLORIDAS) ─────────────────────────
                  if (track.genres.isNotEmpty) ...[
                    _buildSectionHeader('Gêneros Musicais'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: track.genres.map((g) {
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.accent.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.accent.withOpacity(0.3), width: 1),
                          ),
                          child: Text(
                            g,
                            style: TextStyle(
                              color: AppColors.accent,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 24),
                  ],
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

Widget _buildSectionHeader(String title) {
  return Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 12),
    child: Text(
      title,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    ),
  );
}

Widget _buildInfoRow({
  required IconData icon,
  required String label,
  required String value,
  Color? valueColor,
  bool isPath = false,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppColors.textMuted),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  color: valueColor ?? AppColors.textPrimary,
                  fontSize: 13,
                  fontFamily: isPath ? 'monospace' : null,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
