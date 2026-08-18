import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../data/database/database.dart';
import '../data/models/album_group.dart';
import '../data/models/artist_group.dart';
import '../data/models/track.dart';
import '../data/services/standalone_downloader.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../data/services/spotify_service.dart';
import '../data/services/lyrics_service.dart';
import '../data/services/manifest_service.dart';
import '../data/services/native_downloader_service.dart';
import 'widgets/track_tile.dart';
import 'widgets/album_grid_view.dart';
import 'widgets/artist_list_view.dart';
import 'widgets/add_to_playlist_sheet.dart';

// ── Providers ─────────────────────────────────────────────────────────────────

enum _SearchFilter { all, downloaded, pending, albums, artists }

const _filterLabels = {
  _SearchFilter.all:        ('Todos',     Icons.library_music_rounded),
  _SearchFilter.downloaded: ('Baixadas',  Icons.check_circle_rounded),
  _SearchFilter.pending:    ('Pendentes', Icons.schedule_rounded),
  _SearchFilter.albums:     ('Álbuns',    Icons.album_rounded),
  _SearchFilter.artists:    ('Artistas',  Icons.person_rounded),
};

// ── Screen ────────────────────────────────────────────────────────────────────

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();

  // Local search state
  List<Track> _localResults = [];
  List<Track> _spotifyResults = [];
  List<AlbumGroup> _albumResults = [];
  List<ArtistGroup> _artistResults = [];
  Map<String, String> _playlistNames = {};
  _SearchFilter _activeFilter = _SearchFilter.all;
  bool _groupLoading = false;

  // Debounce for local search
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadPlaylistNames();
  }

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadPlaylistNames() async {
    try {
      final playlists = await AppDatabase.instance.getPlaylists();
      if (mounted) {
        setState(() {
          _playlistNames = {for (final pl in playlists) pl.id: pl.name};
        });
      }
    } catch (_) {}
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _searchLocal(query);
    });
  }

  Future<void> _searchLocal(String query) async {
    final q = query.trim();
    if (q.length < 2 &&
        _activeFilter != _SearchFilter.albums &&
        _activeFilter != _SearchFilter.artists) {
      setState(() {
        _localResults = [];
        _spotifyResults = [];
        _albumResults = [];
        _artistResults = [];
        _groupLoading = false;
      });
      return;
    }

    setState(() => _groupLoading = true);

    final results = await Future.wait([
      AppDatabase.instance.searchTracks(
        q,
        cachedOnly: _activeFilter == _SearchFilter.downloaded
            ? true
            : _activeFilter == _SearchFilter.pending
                ? false
                : null,
      ),
      AppDatabase.instance.searchAlbums(q, limit: 50),
      AppDatabase.instance.searchArtists(q, limit: 50),
    ]);

    if (mounted) {
      setState(() {
        _localResults = results[0] as List<Track>;
        _albumResults = results[1] as List<AlbumGroup>;
        _artistResults = results[2] as List<ArtistGroup>;
        _groupLoading = false;
      });
    }
  }

  void _setFilter(_SearchFilter filter) {
    setState(() {
      _activeFilter = filter;
      _localResults = [];
      _spotifyResults = [];
      _albumResults = [];
      _artistResults = [];
    });
    _searchLocal(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: AppColors.bg,
          elevation: 0,
          title: const Text(
            'Buscar',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(104), // 46 (TextField) + 58 (TabBar)
            child: Column(
              children: [
                // Barra de busca
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                  child: Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border.withOpacity(0.4)),
                    ),
                    child: TextField(
                      controller: _controller,
                      autofocus: false,
                      onChanged: (val) {
                        ref.read(spotifySearchQueryProvider.notifier).state = val;
                        _onQueryChanged(val);
                      },
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'Buscar músicas, álbuns, artistas...',
                        hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        prefixIcon: Icon(Icons.search_rounded, color: AppColors.accent, size: 20),
                        suffixIcon: _controller.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, color: AppColors.textMuted, size: 18),
                                onPressed: () {
                                  _controller.clear();
                                  setState(() {
                                    _localResults = [];
                                    _albumResults = [];
                                    _artistResults = [];
                                  });
                                },
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
                TabBar(
                  indicatorColor: AppColors.accent,
                  labelColor: AppColors.accent,
                  unselectedLabelColor: AppColors.textMuted,
                  indicatorSize: TabBarIndicatorSize.label,
                  indicatorWeight: 3,
                  labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  unselectedLabelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
                  tabs: const [
                    Tab(
                      icon: Icon(Icons.my_library_music_rounded, size: 20),
                      text: 'Biblioteca',
                      iconMargin: EdgeInsets.only(bottom: 3),
                    ),
                    Tab(
                      icon: Icon(Icons.explore_rounded, size: 20),
                      text: 'Spotify',
                      iconMargin: EdgeInsets.only(bottom: 3),
                    ),
                    Tab(
                      icon: Icon(Icons.play_circle_fill_rounded, size: 20),
                      text: 'YouTube',
                      iconMargin: EdgeInsets.only(bottom: 3),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        body: TabBarView(
          children: [
            _LocalSearchTab(
              results: _localResults,
              albumResults: _albumResults,
              artistResults: _artistResults,
              query: _controller.text,
              playlistNames: _playlistNames,
              filter: _activeFilter,
              onFilterSelected: _setFilter,
              groupLoading: _groupLoading,
              ref: ref,
            ),
            _SpotifySearchTab(
              query: _controller.text,
            ),
            _YouTubeSearchTab(
              query: _controller.text,
              ref: ref,
            ),
          ],
        ),
      ),
    ),
  );
}
}

// ── Tab 1: Biblioteca local ───────────────────────────────────────────────────

class _LocalSearchTab extends StatelessWidget {
  final List<Track> results;
  final List<AlbumGroup> albumResults;
  final List<ArtistGroup> artistResults;
  final String query;
  final Map<String, String> playlistNames;
  final _SearchFilter filter;
  final ValueChanged<_SearchFilter> onFilterSelected;
  final bool groupLoading;
  final WidgetRef ref;

  const _LocalSearchTab({
    required this.results,
    required this.albumResults,
    required this.artistResults,
    required this.query,
    required this.playlistNames,
    required this.filter,
    required this.onFilterSelected,
    required this.groupLoading,
    required this.ref,
  });

  Widget _buildFilterChips() {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: _SearchFilter.values.map((f) {
          final (label, icon) = _filterLabels[f]!;
          final isSelected = filter == f;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              showCheckmark: false,
              avatar: Icon(icon, size: 13,
                color: isSelected ? Colors.black : AppColors.textMuted),
              label: Text(label, style: TextStyle(
                fontSize: 11,
                color: isSelected ? Colors.black : AppColors.textSecond,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.normal,
              )),
              selected: isSelected,
              onSelected: (_) => onFilterSelected(f),
              selectedColor: AppColors.accent,
              backgroundColor: AppColors.surface,
              checkmarkColor: Colors.black,
              side: BorderSide(
                color: isSelected ? AppColors.accent : AppColors.border,
                width: 1,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 2),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget bodyContent;
    if (query.trim().length < 2 &&
        filter != _SearchFilter.albums &&
        filter != _SearchFilter.artists) {
      bodyContent = const Expanded(
        child: _Placeholder(
          icon: Icons.search_rounded,
          title: 'Pesquisar na Biblioteca',
          subtitle: 'Encontre suas músicas, álbuns e artistas baixados.',
        ),
      );
    } else if (filter == _SearchFilter.albums) {
      if (groupLoading && albumResults.isEmpty) {
        bodyContent = Expanded(child: Center(child: CircularProgressIndicator(color: AppColors.accent)));
      } else if (albumResults.isEmpty) {
        bodyContent = const Expanded(child: _Placeholder(icon: Icons.album_rounded, title: 'Nenhum álbum', subtitle: 'Não encontramos álbuns com esse nome.'));
      } else {
        bodyContent = Expanded(child: AlbumGridView(albums: albumResults, playlistNames: playlistNames));
      }
    } else if (filter == _SearchFilter.artists) {
      if (groupLoading && artistResults.isEmpty) {
        bodyContent = Expanded(child: Center(child: CircularProgressIndicator(color: AppColors.accent)));
      } else if (artistResults.isEmpty) {
        bodyContent = const Expanded(child: _Placeholder(icon: Icons.person_rounded, title: 'Nenhum artista', subtitle: 'Não encontramos artistas com esse nome.'));
      } else {
        bodyContent = Expanded(child: ArtistListView(artists: artistResults));
      }
    } else if (results.isEmpty) {
      bodyContent = Expanded(
        child: _Placeholder(
          icon: Icons.music_off_rounded,
          title: 'Nenhum resultado',
          subtitle: filter == _SearchFilter.downloaded
              ? 'Nenhuma música baixada com esse nome.'
              : filter == _SearchFilter.pending
                  ? 'Nenhuma música pendente com esse nome.'
                  : 'Tente buscar por outro termo.',
        ),
      );
    } else {
      bodyContent = Expanded(
        child: CustomScrollView(
          slivers: [
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final track = results[i];
                  final playlistName = playlistNames[track.playlistId] ?? track.playlistId;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 16, top: 8, bottom: 2),
                        child: Text(
                          playlistName,
                          style: const TextStyle(
                            color: AppColors.textSecond,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      TrackTile(
                        track: track,
                        queue: results,
                      ),
                    ],
                  );
                },
                childCount: results.length,
              ),
            ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 100)),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildFilterChips(),
        bodyContent,
      ],
    );
  }
}

// ── Tab 2: Spotify ────────────────────────────────────────────────────────────

class _SpotifySearchTab extends ConsumerWidget {
  final String query;

  const _SpotifySearchTab({
    required this.query,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (query.trim().length < 2) {
      return const _Placeholder(
        icon: Icons.explore_rounded,
        title: 'Pesquisar no Spotify',
        subtitle: 'Busque músicas online para adicionar às suas playlists.',
      );
    }

    final searchAsync = ref.watch(spotifySearchResultsProvider);

    return searchAsync.when(
      loading: () => Center(child: CircularProgressIndicator(color: AppColors.accent)),
      error: (e, st) => _Placeholder(
        icon: Icons.error_outline_rounded,
        title: 'Erro na busca',
        subtitle: e.toString(),
      ),
      data: (results) {
        if (results.isEmpty) {
          return const _Placeholder(
            icon: Icons.search_off_rounded,
            title: 'Nenhum resultado',
            subtitle: 'Não foi possível encontrar essa música no Spotify.',
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: results.length,
          separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border, indent: 80),
          itemBuilder: (context, i) {
            final track = results[i];
            final durSec = track.durationMs ~/ 1000;
            final durStr = '${durSec ~/ 60}:${(durSec % 60).toString().padLeft(2, '0')}';

            return _ExternalSearchResultTile(
              title: track.title,
              subtitle: '${track.artist} • $durStr',
              imageUrl: track.albumArtUrl,
              badgeColor: const Color(0xFF1DB954), // Spotify Green
              badgeLabel: 'Spotify',
              onAddTap: () {
                showModalBottomSheet(
                  context: context,
                  backgroundColor: Colors.transparent,
                  isScrollControlled: true,
                  builder: (_) => AddToPlaylistSheet(track: track),
                );
              },
            );
          },
        );
      },
    );
  }
}

// ── Tab 3: Busca Direta no YouTube ────────────────────────────────────────────

class _YouTubeSearchTab extends StatefulWidget {
  final String query;
  final WidgetRef ref;
  const _YouTubeSearchTab({required this.query, required this.ref});

  @override
  State<_YouTubeSearchTab> createState() => _YouTubeSearchTabState();
}

class _YouTubeSearchTabState extends State<_YouTubeSearchTab> {
  List<InnerTubeSearchResult> _results = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.query.trim().length >= 2) _search();
  }

  @override
  void didUpdateWidget(covariant _YouTubeSearchTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != oldWidget.query && widget.query.trim().length >= 2) {
      _search();
    }
  }

  Future<void> _search() async {
    if (widget.query.trim().isEmpty) return;
    setState(() => _isLoading = true);

    try {
      final results = await NativeDownloaderService().searchInnerTube(widget.query.trim());
      if (mounted) {
        setState(() {
          _results = results;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.query.trim().length < 2) {
      return const _Placeholder(
        icon: Icons.play_circle_fill_rounded,
        title: 'Pesquisar no YouTube',
        subtitle: 'Busque áudios e vídeos diretamente do YouTube.',
      );
    }

    if (_isLoading) {
      return Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (_results.isEmpty) {
      return const _Placeholder(
        icon: Icons.search_off_rounded,
        title: 'Nenhum vídeo encontrado',
        subtitle: 'Não foi possível encontrar vídeos no YouTube com esse termo.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: AppColors.border, indent: 80),
      itemBuilder: (ctx, i) {
        final item = _results[i];
        final durStr = '${item.durationSec ~/ 60}:${(item.durationSec % 60).toString().padLeft(2, '0')}';
        final isTopic = item.owner.contains('Topic') || item.title.toLowerCase().contains('audio');
        final artistClean = item.owner.replaceAll('- Topic', '').trim();

        return _ExternalSearchResultTile(
          title: item.title,
          subtitle: '$artistClean • $durStr',
          imageUrl: 'https://img.youtube.com/vi/${item.id}/hqdefault.jpg',
          badgeColor: const Color(0xFFFF0000), // YouTube Red
          badgeLabel: isTopic ? 'OFICIAL' : 'YouTube',
          isOfficial: isTopic,
          onAddTap: () {
            final artistClean = item.owner.replaceAll('- Topic', '').trim();
            final artistFinal = artistClean.isEmpty ? 'YouTube' : artistClean;
            final track = Track(
              id: 'yt_${item.id}',
              spotifyUri: 'youtube:${item.id}',
              title: item.title,
              artist: artistFinal,
              primaryArtist: artistFinal,
              album: 'YouTube',
              albumArtist: artistFinal,
              durationMs: item.durationSec * 1000,
              albumArtUrl: 'https://img.youtube.com/vi/${item.id}/hqdefault.jpg',
              playlistId: '',
              available: true,
              downloadStatus: 'pending',
            );

            showModalBottomSheet(
              context: context,
              backgroundColor: Colors.transparent,
              isScrollControlled: true,
              builder: (_) => AddToPlaylistSheet(track: track),
            );
          },
        );
      },
    );
  }
}

// ── Item de Busca Externa Unificado (Spotify & YouTube) ───────────────────────

class _ExternalSearchResultTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? imageUrl;
  final Color badgeColor;
  final String badgeLabel;
  final bool isOfficial;
  final VoidCallback onAddTap;

  const _ExternalSearchResultTile({
    required this.title,
    required this.subtitle,
    this.imageUrl,
    required this.badgeColor,
    required this.badgeLabel,
    this.isOfficial = false,
    required this.onAddTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: imageUrl != null && imageUrl!.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: imageUrl!,
                width: 52,
                height: 52,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => Container(
                  width: 52,
                  height: 52,
                  color: AppColors.surfaceHigh,
                  child: const Icon(Icons.music_note_rounded, color: AppColors.textMuted, size: 24),
                ),
              )
            : Container(
                width: 52,
                height: 52,
                color: AppColors.surfaceHigh,
                child: const Icon(Icons.music_note_rounded, color: AppColors.textMuted, size: 24),
              ),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          subtitle,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      trailing: IconButton(
        icon: Icon(Icons.add_circle_outline_rounded, color: AppColors.accent, size: 24),
        onPressed: onAddTap,
        tooltip: 'Adicionar à Playlist',
      ),
    );
  }
}

// ── Placeholder genérico ──────────────────────────────────────────────────────

class _Placeholder extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  const _Placeholder({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 48, color: AppColors.accent),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
