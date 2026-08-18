import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/database/database.dart';
import '../data/models/album_group.dart';
import '../data/models/artist_group.dart';
import '../data/models/player_state.dart' as app;
import '../data/models/playlist.dart';
import '../data/models/track.dart';
import '../data/services/sync_service.dart';
import '../data/services/manifest_service.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import 'widgets/track_tile.dart';
import 'widgets/album_grid_view.dart';
import 'widgets/artist_list_view.dart';

class PlaylistScreen extends ConsumerStatefulWidget {
  final String playlistId;
  final String playlistName;
  final String? highlightTrackId;
  const PlaylistScreen({
    super.key,
    required this.playlistId,
    required this.playlistName,
    this.highlightTrackId,
  });

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

enum _SearchFilter { all, downloaded, pending, albums, artists }

const _filterLabels = {
  _SearchFilter.all:        ('Todos',     Icons.library_music_rounded),
  _SearchFilter.downloaded: ('Baixadas',  Icons.check_circle_rounded),
  _SearchFilter.pending:    ('Pendentes', Icons.schedule_rounded),
  _SearchFilter.albums:     ('Álbuns',    Icons.album_rounded),
  _SearchFilter.artists:    ('Artistas',  Icons.person_rounded),
};

class _PlaylistScreenState extends ConsumerState<PlaylistScreen>
    with SingleTickerProviderStateMixin {
  bool _hasScrolledToHighlight = false;
  final ScrollController _scrollController = ScrollController();
  String _searchQuery = '';
  bool _isScrolling = false;
  double _velocity = 0;
  Timer? _debounce;
  _SearchFilter _activeFilter = _SearchFilter.all;

  // Para vistas de álbuns/artistas
  List<AlbumGroup> _albumResults = [];
  List<ArtistGroup> _artistResults = [];
  bool _groupLoading = false;

  // Reordenação por arrastar e auto-scroll acelerado nas bordas
  Timer? _autoScrollTimer;
  double _currentPointerY = 0;
  bool _isReordering = false;
  List<Track>? _localTracks;
  String? _loadedPlaylistId;

  void _startAutoScrollTimer() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!_isReordering || !mounted) {
        timer.cancel();
        return;
      }
      
      final screenHeight = MediaQuery.of(context).size.height;
      final topThreshold = screenHeight * 0.25; // 25% do topo
      final bottomThreshold = screenHeight * 0.85; // 85% da base
      
      if (_currentPointerY > bottomThreshold) {
        // Arrasta para baixo -> desce rápido
        final proximity = (_currentPointerY - bottomThreshold) / (screenHeight - bottomThreshold);
        // Velocidade máxima de 50px por frame (cerca de 3000px por segundo!)
        final scrollDelta = 12.0 + (proximity * 38.0); 
        final target = _scrollController.offset + scrollDelta;
        _scrollController.jumpTo(target.clamp(0.0, _scrollController.position.maxScrollExtent));
      } else if (_currentPointerY < topThreshold && _currentPointerY > 80) {
        // Arrasta para cima -> sobe rápido
        final proximity = (topThreshold - _currentPointerY) / (topThreshold - 80);
        final scrollDelta = 12.0 + (proximity * 38.0);
        final target = _scrollController.offset - scrollDelta;
        _scrollController.jumpTo(target.clamp(0.0, _scrollController.position.maxScrollExtent));
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _debounce?.cancel();
    _autoScrollTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) {
        setState(() => _searchQuery = query);
        _loadGroupedResults(query);
      }
    });
  }

  void _setFilter(_SearchFilter filter) {
    setState(() => _activeFilter = filter);
    _loadGroupedResults(_searchQuery);
  }

  Future<void> _loadGroupedResults(String query) async {
    if (_activeFilter != _SearchFilter.albums &&
        _activeFilter != _SearchFilter.artists) return;
    setState(() => _groupLoading = true);
    if (_activeFilter == _SearchFilter.albums) {
      final res = await AppDatabase.instance.searchAlbums(
        query.isEmpty ? '' : query,
        playlistId: widget.playlistId,
      );
      if (mounted) setState(() { _albumResults = res; _groupLoading = false; });
    } else if (_activeFilter == _SearchFilter.artists) {
      final res = await AppDatabase.instance.searchArtists(
        query.isEmpty ? '' : query,
        playlistId: widget.playlistId,
      );
      if (mounted) setState(() { _artistResults = res; _groupLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracksAsync = ref.watch(playlistTracksProvider(widget.playlistId));
    final tracksVal = tracksAsync.value;
    if (tracksVal != null) {
      final contentEqual = _localTracks != null &&
          _localTracks!.length == tracksVal.length &&
          _localTracks!.asMap().entries.every((entry) {
            final t1 = entry.value;
            final t2 = tracksVal[entry.key];
            return t1.id == t2.id &&
                t1.isCached == t2.isCached &&
                t1.available == t2.available &&
                t1.downloadStatus == t2.downloadStatus;
          });

      if (_loadedPlaylistId != widget.playlistId || _localTracks == null || !contentEqual) {
        _localTracks = List<Track>.from(tracksVal);
        _loadedPlaylistId = widget.playlistId;
      }
    }
    final syncState   = ref.watch(syncProvider);
    final playlistDetailsAsync = ref.watch(playlistDetailsProvider(widget.playlistId));
    final playlistDetails = playlistDetailsAsync.value;

    // Escuta mudanças no sync para mostrar SnackBars de erro ou sucesso e invalidar lista
    ref.listen<SyncState>(syncProvider, (prev, next) {
      if (next.error != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: ${next.error}'), backgroundColor: AppColors.error),
        );
      } else if (next.message != null && !next.isLoading && mounted) {
        ref.invalidate(playlistTracksProvider(widget.playlistId)); // Garante atualização final
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.message!), backgroundColor: AppColors.accent, duration: const Duration(seconds: 2)),
        );
      }
    });

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
      body: tracksAsync.when(
        loading: () => Center(child: CircularProgressIndicator(color: AppColors.accent)),
        error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: AppColors.error))),
        data: (ignoredTracks) {
          final tracks = _localTracks ?? ignoredTracks;
          final filteredTracks = _searchQuery.isEmpty
              ? tracks
              : tracks.where((t) =>
                  t.title.toLowerCase().contains(_searchQuery.toLowerCase()) || 
                  t.artist.toLowerCase().contains(_searchQuery.toLowerCase())
                ).toList();
          final availableTracks = filteredTracks.where((t) => t.isCached).toList();
          final allAvailableTracks = tracks.where((t) => t.isCached).toList();

          // Rolagem automática para a faixa destacada (highlightTrackId)
          if (widget.highlightTrackId != null && !_hasScrolledToHighlight && filteredTracks.isNotEmpty) {
            final index = filteredTracks.indexWhere((t) => t.id == widget.highlightTrackId);
            if (index != -1) {
              _hasScrolledToHighlight = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scrollController.hasClients) {
                  const headerHeight = 360.0;
                  const itemHeight = 72.0;
                  final targetOffset = headerHeight + (itemHeight * index) - 250.0;
                  _scrollController.animateTo(
                    targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeInOut,
                  );
                }
              });
            }
          }

          return Listener(
            onPointerDown: (event) {
              _currentPointerY = event.position.dy;
            },
            onPointerMove: (event) {
              _currentPointerY = event.position.dy;
            },
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification) {
                  setState(() => _isScrolling = true);
                } else if (notification is ScrollUpdateNotification) {
                  final v = notification.scrollDelta?.abs() ?? 0;
                  if (v > 50 && !_isScrolling) setState(() => _isScrolling = true);
                  _velocity = v;
                } else if (notification is ScrollEndNotification) {
                  setState(() { _isScrolling = false; _velocity = 0; });
                }
                return false;
              },
              child: RawScrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                thickness: 12,
                padding: const EdgeInsets.only(top: 100, bottom: 100, right: 2),
                radius: const Radius.circular(6),
                thumbColor: AppColors.accent.withOpacity(0.7),
                interactive: true,
                child: CustomScrollView(
                  controller: _scrollController,
                  slivers: [
                  // ── Header ────────────────────────────────────────────────
                  SliverAppBar(
                    pinned: true,
                    backgroundColor: AppColors.bg,
                    elevation: 0,
                    title: Text(
                      playlistDetails?.name ?? widget.playlistName,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    actions: [
                      if (playlistDetails != null)
                        IconButton(
                          tooltip: 'Editar Playlist',
                          icon: const Icon(Icons.edit_rounded, color: AppColors.textPrimary),
                          onPressed: () => _showEditPlaylistDialog(context, playlistDetails),
                        ),
                      if (playlistDetails != null && !playlistDetails.syncDisabled)
                        IconButton(
                          tooltip: 'Sincronizar Playlist (Spotify)',
                          icon: syncState.isLoading 
                              ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent))
                              : const Icon(Icons.sync_rounded, color: AppColors.textPrimary),
                          onPressed: syncState.isLoading ? null : () => _confirmAndSyncPlaylist(context, ref, widget.playlistId, playlistDetails.name),
                        ),
                      IconButton(
                        tooltip: syncState.isLoading ? 'Parar Download' : 'Baixar Músicas (Servidor)',
                        icon: Icon(
                          syncState.isLoading ? Icons.stop_circle_rounded : Icons.download_for_offline_rounded, 
                          color: syncState.isLoading ? AppColors.error : AppColors.accent
                        ),
                        onPressed: () {
                          if (syncState.isLoading) {
                            ref.read(syncProvider.notifier).cancelSync();
                          } else {
                            ref.read(syncProvider.notifier).syncAudio(widget.playlistId);
                          }
                        },
                      ),
                    ],
                    bottom: PreferredSize(
                      preferredSize: const Size.fromHeight(98),
                      child: Container(
                        color: AppColors.bg,
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Barra de busca
                            SizedBox(
                              height: 40,
                              child: TextField(
                                onChanged: _onSearchChanged,
                                style: const TextStyle(color: Colors.white, fontSize: 13),
                                decoration: InputDecoration(
                                  hintText: 'Buscar na playlist...',
                                  hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                                  prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.textMuted),
                                  filled: true,
                                  fillColor: AppColors.surface,
                                  contentPadding: EdgeInsets.zero,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            // Chips de filtro
                            SizedBox(
                              height: 32,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: _SearchFilter.values.map((filter) {
                                  final (label, icon) = _filterLabels[filter]!;
                                  final isSelected = _activeFilter == filter;
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 180),
                                      child: FilterChip(
                                        showCheckmark: false,
                                        avatar: Icon(icon, size: 14,
                                          color: isSelected ? Colors.black : AppColors.textMuted,
                                        ),
                                        label: Text(label, style: TextStyle(
                                          fontSize: 12,
                                          color: isSelected ? Colors.black : AppColors.textSecond,
                                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
                                        )),
                                        selected: isSelected,
                                        onSelected: (_) => _setFilter(filter),
                                        selectedColor: AppColors.accent,
                                        backgroundColor: AppColors.surface,
                                        checkmarkColor: Colors.black,
                                        side: BorderSide(
                                          color: isSelected ? AppColors.accent : AppColors.border,
                                          width: 1,
                                        ),
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // ── Rich Header Card ──────────────────────────────────────
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
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: Colors.black,
                                  width: 2.0,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: playlistDetails != null && playlistDetails.imageUrl.isNotEmpty
                                    ? CachedNetworkImage(
                                        imageUrl: playlistDetails.imageUrl,
                                        fit: BoxFit.cover,
                                        placeholder: (context, url) => _coverPlaceholder(),
                                        errorWidget: (context, url, error) => _coverPlaceholder(),
                                      )
                                    : _coverPlaceholder(),
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),

                          // 2. Playlist description
                          if (playlistDetails != null && playlistDetails.description.isNotEmpty) ...[
                            Text(
                              playlistDetails.description,
                              style: const TextStyle(
                                color: AppColors.textSecond,
                                fontSize: 13,
                                height: 1.4,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 16),
                          ],

                          // 3. Dynamic Sync State Progress Bar (if loading)
                          if (syncState.isLoading)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    syncState.message ?? 'Sincronizando...',
                                    style: TextStyle(color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 6),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(2),
                                    child: LinearProgressIndicator(
                                      value: syncState.progress > 0 ? syncState.progress : null,
                                      backgroundColor: Colors.white10,
                                      color: AppColors.accent,
                                      minHeight: 4,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                          // 4. Action Row: Stats & Green Circular Play/Shuffle Buttons
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              // Playlist Stats info
                              Expanded(
                                child: Text(
                                  '${tracks.length} músicas • ${tracks.where((t) => t.isCached).length} baixadas',
                                  style: const TextStyle(
                                    color: AppColors.textSecond,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              // Spotify-style Green circular Play & Shuffle Buttons
                              if (allAvailableTracks.isNotEmpty)
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Shuffle Play (Shuffle)
                                    GestureDetector(
                                      onTap: () => ref.read(playerProvider.notifier).playQueueWithShuffle(
                                        allAvailableTracks,
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
                                        allAvailableTracks,
                                        shuffleMode: app.ShuffleMode.off,
                                      ),
                                      child: Container(
                                        width: 48,
                                        height: 48,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: AppColors.accent,
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

                  // ── List or Group View ────────────────────────────────────
                  if (_activeFilter == _SearchFilter.albums)
                    SliverToBoxAdapter(
                      child: _groupLoading
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 40),
                              child: Center(child: CircularProgressIndicator()),
                            )
                          : AlbumGridView(
                              albums: _albumResults,
                              playlistNames: {widget.playlistId: widget.playlistName},
                              playlistId: widget.playlistId,
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              isScrolling: _isScrolling && _velocity > 200,
                            ),
                    )
                  else if (_activeFilter == _SearchFilter.artists)
                    SliverToBoxAdapter(
                      child: _groupLoading
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 40),
                              child: Center(child: CircularProgressIndicator()),
                            )
                          : ArtistListView(
                              artists: _artistResults,
                              playlistId: widget.playlistId,
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              isScrolling: _isScrolling && _velocity > 200,
                            ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.only(bottom: 100),
                      sliver: () {
                        final visibleTracks = _activeFilter == _SearchFilter.downloaded
                            ? filteredTracks.where((t) => t.isCached).toList()
                            : _activeFilter == _SearchFilter.pending
                                ? filteredTracks.where((t) => !t.isCached).toList()
                                : filteredTracks;
                        final isDefaultView = _activeFilter == _SearchFilter.all && _searchQuery.isEmpty;
                        if (isDefaultView) {
                          return SliverReorderableList(
                            itemBuilder: (context, i) {
                              final track = visibleTracks[i];
                              if (_isScrolling && _velocity > 250) {
                                return _TrackPlaceholder(
                                  key: ValueKey(track.id),
                                );
                              }
                              return ReorderableDelayedDragStartListener(
                                index: i,
                                key: ValueKey(track.id),
                                child: TrackTile(
                                  key: ValueKey(track.id),
                                  track: track,
                                  queue: allAvailableTracks,
                                  showIndex: true,
                                  isHighlighted: widget.highlightTrackId == track.id,
                                ),
                              );
                            },
                            itemCount: visibleTracks.length,
                            onReorderStart: (index) {
                              setState(() {
                                _isReordering = true;
                              });
                              _startAutoScrollTimer();
                            },
                            onReorderEnd: (index) {
                              setState(() {
                                _isReordering = false;
                              });
                              _autoScrollTimer?.cancel();
                            },
                            onReorder: (oldIndex, newIndex) async {
                              if (oldIndex == newIndex) return;
                              if (newIndex > oldIndex) {
                                newIndex -= 1;
                              }
                              
                              if (_localTracks != null) {
                                setState(() {
                                  final movedTrack = _localTracks!.removeAt(oldIndex);
                                  _localTracks!.insert(newIndex, movedTrack);
                                });
                                
                                // Persistência das posições
                                final ids = _localTracks!.map((t) => t.id).toList();
                                await AppDatabase.instance.updateTrackPositions(widget.playlistId, ids);
                                
                                // Salva manifesto no disco
                                ManifestService.instance.scheduleSave();
                                
                                ref.invalidate(playlistTracksProvider(widget.playlistId));
                              }
                            },
                          );
                        } else {
                          return SliverFixedExtentList(
                            itemExtent: 72,
                            delegate: SliverChildBuilderDelegate(
                              (context, i) {
                                if (_isScrolling && _velocity > 250) return const _TrackPlaceholder();
                                if (i >= visibleTracks.length) return null;
                                return TrackTile(
                                  key: ValueKey(visibleTracks[i].id),
                                  track: visibleTracks[i],
                                  queue: allAvailableTracks,
                                  showIndex: true,
                                );
                              },
                              childCount: visibleTracks.length,
                            ),
                          );
                        }
                      }(),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  ),
);
}

  void _confirmAndSyncPlaylist(BuildContext context, WidgetRef ref, String playlistId, String playlistName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.sync_rounded, color: AppColors.accent),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Sincronizar Playlist',
                style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(
          'Esta ação irá consultar o Spotify para sincronizar e atualizar as faixas de "$playlistName".\n\n'
          'ATENÇÃO: Músicas que não estão mais presentes na playlist do Spotify serão removidas do aplicativo para manter a sincronização exata.\n\n'
          'Tem certeza que deseja continuar?',
          style: const TextStyle(color: AppColors.textSecond, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: AppColors.textMuted)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(syncProvider.notifier).syncMetadata(playlistId);
            },
            child: const Text('Sincronizar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder() => Container(
        color: AppColors.surfaceHigh,
        child: Center(
          child: Icon(
            Icons.library_music_rounded,
            size: 64,
            color: AppColors.accent,
          ),
        ),
      );

  void _showEditPlaylistDialog(BuildContext context, Playlist playlist) {
    final nameController = TextEditingController(text: playlist.name);
    final descController = TextEditingController(text: playlist.description);
    final urlController = TextEditingController(text: playlist.imageUrl);
    bool syncDisabledVal = playlist.syncDisabled;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: AppColors.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text(
                'Editar Playlist',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Nome', style: TextStyle(color: AppColors.textSecond, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: nameController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Minha super playlist',
                        hintStyle: const TextStyle(color: AppColors.textMuted),
                        filled: true,
                        fillColor: AppColors.bg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Descrição', style: TextStyle(color: AppColors.textSecond, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: descController,
                      maxLines: 3,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Uma playlist incrível...',
                        hintStyle: const TextStyle(color: AppColors.textMuted),
                        filled: true,
                        fillColor: AppColors.bg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('URL da Foto (Capa)', style: TextStyle(color: AppColors.textSecond, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: urlController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'https://exemplo.com/foto.jpg',
                        hintStyle: const TextStyle(color: AppColors.textMuted),
                        filled: true,
                        fillColor: AppColors.bg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Desativar Sync do Spotify',
                                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                              SizedBox(height: 2),
                              Text('Impede que atualizações do Spotify sobrescrevam suas faixas locais.',
                                  style: TextStyle(color: AppColors.textMuted, fontSize: 10)),
                            ],
                          ),
                        ),
                        Switch(
                          value: syncDisabledVal,
                          activeColor: AppColors.accent,
                          onChanged: (val) {
                            setDialogState(() {
                              syncDisabledVal = val;
                            });
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancelar', style: TextStyle(color: AppColors.textMuted)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () async {
                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('O nome da playlist não pode ser vazio.'), backgroundColor: AppColors.error),
                      );
                      return;
                    }

                    Navigator.pop(context);

                    // Mostra indicador de carregamento
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Salvando alterações...'), duration: Duration(milliseconds: 500)),
                    );

                    await ref.read(libraryProvider.notifier).updatePlaylistDetails(
                      playlistId: playlist.id,
                      name: name,
                      description: descController.text.trim(),
                      imageUrl: urlController.text.trim(),
                      syncDisabled: syncDisabledVal,
                    );

                    ref.invalidate(playlistDetailsProvider(playlist.id));
                  },
                  child: const Text('Salvar', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _TrackPlaceholder extends StatelessWidget {
  const _TrackPlaceholder({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(width: 52, height: 52, decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(4))),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(width: 140, height: 12, color: AppColors.surfaceHigh),
                const SizedBox(height: 8),
                Container(width: 80, height: 10, color: AppColors.surfaceHigh),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
