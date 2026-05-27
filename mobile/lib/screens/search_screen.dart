import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../core/theme.dart';
import '../data/database/database.dart';
import '../data/models/track.dart';
import '../data/services/search_service.dart';
import '../data/services/server_downloader.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import 'widgets/track_tile.dart';

// ── Providers ─────────────────────────────────────────────────────────────────

final _remoteSearchResultsProvider =
    StateProvider<List<RemoteTrack>>((ref) => []);
final _remoteSearchLoadingProvider = StateProvider<bool>((ref) => false);
final _remoteSearchErrorProvider = StateProvider<String?>((ref) => null);

// ── Screen ────────────────────────────────────────────────────────────────────

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  late TabController _tabController;

  // Local search state
  List<Track> _localResults = [];
  Map<String, String> _playlistNames = {};

  // Debounce for local search
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadPlaylistNames();
  }

  @override
  void dispose() {
    _tabController.dispose();
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
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _searchLocal(query);
      // Reset remote results when query changes
      ref.read(_remoteSearchResultsProvider.notifier).state = [];
      ref.read(_remoteSearchErrorProvider.notifier).state = null;
    });
  }

  Future<void> _searchLocal(String query) async {
    if (query.trim().length < 2) {
      setState(() => _localResults = []);
      return;
    }
    final results = await AppDatabase.instance.searchTracks(query);
    if (mounted) setState(() => _localResults = results);
  }

  Future<void> _searchRemote() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;

    ref.read(_remoteSearchLoadingProvider.notifier).state = true;
    ref.read(_remoteSearchErrorProvider.notifier).state = null;
    ref.read(_remoteSearchResultsProvider.notifier).state = [];

    try {
      final results = await SearchService().search(query, limit: 10);
      ref.read(_remoteSearchResultsProvider.notifier).state = results;
    } catch (e) {
      ref.read(_remoteSearchErrorProvider.notifier).state =
          'Erro ao buscar no servidor: $e';
    } finally {
      ref.read(_remoteSearchLoadingProvider.notifier).state = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onQueryChanged,
          onSubmitted: (_) {
            // When user presses Enter/Search on keyboard, search the active tab
            if (_tabController.index == 1) _searchRemote();
          },
          style: const TextStyle(color: Colors.white, fontSize: 15),
          decoration: InputDecoration(
            hintText: 'Buscar músicas...',
            hintStyle: const TextStyle(color: AppColors.textMuted),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
            prefixIcon: Icon(Icons.search_rounded, color: AppColors.accent),
            suffixIcon: _controller.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear_rounded, color: AppColors.textMuted, size: 18),
                    onPressed: () {
                      _controller.clear();
                      setState(() => _localResults = []);
                      ref.read(_remoteSearchResultsProvider.notifier).state = [];
                    },
                  )
                : null,
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.accent,
          labelColor: AppColors.accent,
          unselectedLabelColor: AppColors.textMuted,
          tabs: const [
            Tab(icon: Icon(Icons.library_music_rounded, size: 18), text: 'Biblioteca'),
            Tab(icon: Icon(Icons.youtube_searched_for_rounded, size: 18), text: 'YouTube'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _LocalSearchTab(
            results: _localResults,
            query: _controller.text,
            playlistNames: _playlistNames,
            ref: ref,
          ),
          _RemoteSearchTab(
            query: _controller.text,
            onSearch: _searchRemote,
          ),
        ],
      ),
    );
  }
}

// ── Tab 1: Biblioteca local ───────────────────────────────────────────────────

class _LocalSearchTab extends StatelessWidget {
  final List<Track> results;
  final String query;
  final Map<String, String> playlistNames;
  final WidgetRef ref;

  const _LocalSearchTab({
    required this.results,
    required this.query,
    required this.playlistNames,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    if (query.length < 2) {
      return _Placeholder(
        icon: Icons.library_music_rounded,
        title: 'Sua biblioteca',
        subtitle: 'Digite pelo menos 2 caracteres para buscar nas músicas baixadas.',
      );
    }
    if (results.isEmpty) {
      return _Placeholder(
        icon: Icons.search_off_rounded,
        title: 'Nada encontrado',
        subtitle: 'Tente buscar no YouTube pela aba ao lado.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 8, bottom: 100),
      itemCount: results.length,
      itemBuilder: (context, i) {
        final track = results[i];
        final playlistName = playlistNames[track.playlistId] ?? track.playlistId;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 8, bottom: 2),
              child: Text(
                playlistName,
                style: TextStyle(
                  color: AppColors.accent.withOpacity(0.8),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            TrackTile(
              track: track,
              queue: results,
              showIndex: false,
              onTap: () async {
                try {
                  final all = await AppDatabase.instance
                      .getTracksForPlaylist(track.playlistId);
                  final available = all.where((t) => t.isCached).toList();
                  if (available.isEmpty && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Nenhuma música baixada nesta playlist.')),
                    );
                    return;
                  }
                  await ref
                      .read(playerProvider.notifier)
                      .playTrack(track, available);
                } catch (_) {}
              },
            ),
          ],
        );
      },
    );
  }
}

// ── Tab 2: Busca remota YouTube ───────────────────────────────────────────────

class _RemoteSearchTab extends ConsumerWidget {
  final String query;
  final VoidCallback onSearch;

  const _RemoteSearchTab({required this.query, required this.onSearch});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isLoading = ref.watch(_remoteSearchLoadingProvider);
    final error = ref.watch(_remoteSearchErrorProvider);
    final results = ref.watch(_remoteSearchResultsProvider);

    if (isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: AppColors.accent),
            const SizedBox(height: 16),
            const Text('Buscando no YouTube...', style: TextStyle(color: AppColors.textMuted)),
          ],
        ),
      );
    }

    if (error != null) {
      return _Placeholder(
        icon: Icons.cloud_off_rounded,
        title: 'Servidor indisponível',
        subtitle: error,
        action: TextButton.icon(
          onPressed: onSearch,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Tentar novamente'),
        ),
      );
    }

    if (results.isEmpty) {
      return _Placeholder(
        icon: Icons.youtube_searched_for_rounded,
        title: 'Buscar no YouTube',
        subtitle: query.isEmpty
            ? 'Digite o nome da música e pressione buscar.'
            : 'Pressione o botão para buscar "$query" no YouTube.',
        action: query.isEmpty
            ? null
            : ElevatedButton.icon(
                onPressed: onSearch,
                icon: const Icon(Icons.search_rounded),
                label: const Text('Buscar'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                ),
              ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text(
                '${results.length} resultados para "$query"',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onSearch,
                icon: const Icon(Icons.refresh_rounded, size: 14),
                label: const Text('Refazer busca', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(foregroundColor: AppColors.accent),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 100),
            itemCount: results.length,
            itemBuilder: (context, i) =>
                _RemoteTrackTile(track: results[i], query: query),
          ),
        ),
      ],
    );
  }
}

// ── Card de resultado remoto ──────────────────────────────────────────────────

class _RemoteTrackTile extends ConsumerStatefulWidget {
  final RemoteTrack track;
  final String query;
  const _RemoteTrackTile({required this.track, required this.query});

  @override
  ConsumerState<_RemoteTrackTile> createState() => _RemoteTrackTileState();
}

class _RemoteTrackTileState extends ConsumerState<_RemoteTrackTile> {
  bool _downloading = false;
  double _progress = 0;
  String _status = '';
  bool _done = false;

  Future<void> _download(String playlistId) async {
    if (_downloading || _done) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _status = 'Iniciando...';
    });

    try {
      final file = await ServerDownloader().downloadTrack(
        title: widget.track.title,
        artist: widget.track.artist,
        album: '',
        imageUrl: widget.track.thumbnail.isNotEmpty ? widget.track.thumbnail : null,
        playlistId: playlistId,
        trackId: widget.track.youtubeId,
        onProgress: (status, pct) {
          if (mounted) setState(() { _status = status; _progress = pct; });
        },
      );

      if (mounted) {
        setState(() {
          _downloading = false;
          _done = file != null;
          _status = file != null ? 'Baixado!' : 'Falhou';
        });
        if (file != null) {
          // Registra a faixa no banco local para aparecer na playlist
          final newTrack = Track(
            id: widget.track.youtubeId,
            spotifyUri: '',
            title: widget.track.title,
            artist: widget.track.artist,
            album: '',
            albumArtUrl: widget.track.thumbnail.isNotEmpty
                ? widget.track.thumbnail
                : null,
            durationMs: widget.track.durationMs,
            playlistId: playlistId,
            localFilename: file.path.split('/').last,
            downloadStatus: 'success',
            available: true,
            isCached: true,
          );
          await AppDatabase.instance.upsertTracks([newTrack]);
          // Atualiza contadores e lista da playlist
          ref.invalidate(playlistsProvider);
          ref.invalidate(playlistTracksProvider(playlistId));
        }
      }

    } catch (e) {
      if (mounted) {
        setState(() { _downloading = false; _status = 'Erro: $e'; });
      }
    }
  }

  Future<void> _showPlaylistPicker() async {
    final playlists = await AppDatabase.instance.getPlaylists();
    if (!mounted) return;

    if (playlists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Crie uma playlist primeiro na aba Biblioteca.'),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Adicionar à playlist',
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(height: 1),
            ...playlists.map((pl) => ListTile(
                  leading: pl.imageUrl.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: CachedNetworkImage(
                              imageUrl: pl.imageUrl,
                              width: 40, height: 40,
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => _playlistPlaceholder()),
                        )
                      : _playlistPlaceholder(),
                  title: Text(pl.name,
                      style: const TextStyle(color: AppColors.textPrimary)),
                  subtitle: Text('${pl.downloaded} músicas',
                      style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _download(pl.id);
                  },
                )),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _playlistPlaceholder() => Container(
        width: 40, height: 40,
        color: AppColors.surfaceHigh,
        child: Icon(Icons.library_music_rounded,
            color: AppColors.accent, size: 20),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Card(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: widget.track.thumbnail.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: widget.track.thumbnail,
                        width: 56, height: 56,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => _thumbPlaceholder(),
                      )
                    : _thumbPlaceholder(),
              ),
              const SizedBox(width: 12),

              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.track.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textSecond, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.access_time_rounded,
                          size: 11, color: AppColors.textMuted),
                      const SizedBox(width: 3),
                      Text(
                        widget.track.durationFormatted,
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 11),
                      ),
                    ]),
                    if (_downloading || _done) ...[
                      const SizedBox(height: 6),
                      if (_downloading)
                        LinearProgressIndicator(
                          value: _progress > 0 ? _progress : null,
                          backgroundColor: AppColors.border,
                          color: AppColors.accent,
                          minHeight: 2,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      const SizedBox(height: 3),
                      Text(
                        _status,
                        style: TextStyle(
                          color: _done ? AppColors.accent : AppColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // Action button
              if (_done)
                Icon(Icons.check_circle_rounded,
                    color: AppColors.accent, size: 28)
              else if (_downloading)
                SizedBox(
                  width: 28, height: 28,
                  child: CircularProgressIndicator(
                    value: _progress > 0 ? _progress : null,
                    strokeWidth: 2.5,
                    color: AppColors.accent,
                    backgroundColor: Colors.white10,
                  ),
                )
              else
                IconButton(
                  onPressed: _showPlaylistPicker,
                  icon: const Icon(Icons.download_rounded),
                  color: AppColors.accent,
                  tooltip: 'Baixar para playlist',
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.accent.withOpacity(0.12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbPlaceholder() => Container(
        width: 56, height: 56,
        color: AppColors.surfaceHigh,
        child: const Icon(Icons.music_note_rounded,
            color: AppColors.textMuted, size: 24),
      );
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
            Icon(icon, size: 64, color: AppColors.surfaceHigh),
            const SizedBox(height: 16),
            Text(
              title,
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
