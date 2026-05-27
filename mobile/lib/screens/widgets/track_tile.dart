import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models/track.dart';
import '../../data/services/sync_service.dart';
import '../../data/services/search_service.dart';
import '../../data/database/database.dart';
import '../../providers/player_provider.dart';
import '../../providers/library_provider.dart';

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

enum _TrackMenuAction { addToQueue, redownload, removeFromPlaylist }

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
        const PopupMenuItem(
          value: _TrackMenuAction.removeFromPlaylist,
          child: Row(children: [
            Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent),
            SizedBox(width: 10),
            Text('Remover da playlist', style: TextStyle(color: Colors.redAccent, fontSize: 14)),
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
        break;

      case _TrackMenuAction.redownload:
        _showVisualRedownloadSheet(context, ref);
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

  void _showVisualRedownloadSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _VisualRedownloadSheet(track: track),
    );
  }
}

class _VisualRedownloadSheet extends ConsumerStatefulWidget {
  final Track track;
  const _VisualRedownloadSheet({required this.track});

  @override
  ConsumerState<_VisualRedownloadSheet> createState() => _VisualRedownloadSheetState();
}

class _VisualRedownloadSheetState extends ConsumerState<_VisualRedownloadSheet> {
  late final TextEditingController _searchController;
  final SearchService _searchService = SearchService();
  
  List<RemoteTrack> _results = [];
  bool _isLoading = false;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: '${widget.track.artist} ${widget.track.title}',
    );
    // Dispara a busca automaticamente ao abrir
    _performSearch();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMsg = null;
    });

    try {
      final res = await _searchService.search(query);
      if (mounted) {
        setState(() {
          _results = res;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMsg = e.toString().replaceAll('Exception:', '').trim();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Para posicionar o sheet corretamente acima do teclado
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, bottomInset + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle / Header
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textMuted.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Baixar Versão Alternativa',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Pesquise e selecione a versão correta de "${widget.track.title}" no YouTube.',
            style: const TextStyle(
              color: AppColors.textSecond,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 16),
          
          // Campo de busca
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Digite o termo de busca...',
                    hintStyle: const TextStyle(color: AppColors.textMuted),
                    filled: true,
                    fillColor: AppColors.surfaceHigh,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _performSearch(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.all(10),
                ),
                icon: const Icon(Icons.search_rounded, size: 20),
                onPressed: _performSearch,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Área de resultados
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 350),
            child: _buildResultsContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsContent() {
    if (_isLoading) {
      return SizedBox(
        height: 150,
        child: Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
      );
    }

    if (_errorMsg != null) {
      return SizedBox(
        height: 150,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 36),
              const SizedBox(height: 8),
              Text(
                'Erro ao buscar:\n$_errorMsg',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    if (_results.isEmpty) {
      return const SizedBox(
        height: 120,
        child: Center(
          child: Text(
            'Nenhum resultado encontrado.',
            style: TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const ClampingScrollPhysics(),
      itemCount: _results.length,
      separatorBuilder: (_, __) => Divider(color: AppColors.border.withOpacity(0.3), height: 1),
      itemBuilder: (context, index) {
        final result = _results[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Row(
            children: [
              // Thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: result.thumbnail,
                  width: 56,
                  height: 42,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(color: AppColors.surfaceHigh),
                  errorWidget: (_, __, ___) => Container(
                    color: AppColors.surfaceHigh,
                    child: const Icon(Icons.music_note_rounded, size: 16, color: AppColors.textMuted),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              
              // Título / Canal / Duração
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      result.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${result.artist} • ${result.durationFormatted}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),

              // Botão Selecionar
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent.withOpacity(0.15),
                  foregroundColor: AppColors.accent,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                onPressed: () => _selectAlternative(result),
                child: const Text(
                  'Escolher',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _selectAlternative(RemoteTrack result) {
    Navigator.pop(context); // Fecha o modal sheet

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Baixando versão selecionada: "${result.title}"...'),
        duration: const Duration(seconds: 4),
        backgroundColor: Colors.orange.shade800,
      ),
    );

    // Inicia download em background
    ref.read(syncProvider.notifier).redownloadSpecificAlternative(
      widget.track,
      result.url,
    ).then((ok) {
      if (mounted) {
        if (ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Música "${widget.track.title}" atualizada com sucesso!'),
              backgroundColor: Colors.green.shade800,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Falha ao baixar versão selecionada de "${widget.track.title}".'),
              backgroundColor: Colors.red.shade800,
            ),
          );
        }
      }
    });
  }
}
