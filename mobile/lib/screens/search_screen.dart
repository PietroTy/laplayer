import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme.dart';
import '../data/database/database.dart';
import '../data/models/track.dart';
import '../providers/player_provider.dart';
import 'widgets/track_tile.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  List<Track> _results = [];
  Map<String, String> _playlistNames = {};

  @override
  void initState() {
    super.initState();
    _loadPlaylistNames();
  }

  void _loadPlaylistNames() async {
    try {
      final playlists = await AppDatabase.instance.getPlaylists();
      final map = {for (final pl in playlists) pl.id: pl.name};
      setState(() {
        _playlistNames = map;
      });
    } catch (e) {
      print('Erro ao carregar nomes das playlists na busca: $e');
    }
  }

  void _onSearch(String query) async {
    if (query.length < 2) {
      setState(() {
        _results = [];
      });
      return;
    }

    final results = await AppDatabase.instance.searchTracks(query);
    setState(() {
      _results = results;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onSearch,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Músicas, artistas ou álbuns...',
            hintStyle: const TextStyle(color: AppColors.textMuted),
            border: InputBorder.none,
            prefixIcon: Icon(Icons.search_rounded, color: AppColors.accent),
          ),
        ),
        backgroundColor: AppColors.surface,
      ),
      body: _results.isEmpty && _controller.text.length >= 2
          ? const Center(child: Text('Nenhum resultado encontrado.', style: TextStyle(color: AppColors.textMuted)))
          : _results.isEmpty
              ? _buildPlaceholder()
              : ListView.builder(
                  padding: const EdgeInsets.only(top: 16, bottom: 100),
                  itemCount: _results.length,
                  itemBuilder: (context, i) {
                    final track = _results[i];
                    final playlistName = _playlistNames[track.playlistId] ?? track.playlistId;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 16, top: 4),
                          child: Text(
                            'Playlist: $playlistName', // Mostra o nome amigável da playlist
                            style: TextStyle(color: AppColors.accent, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                        TrackTile(
                          track: track,
                          queue: const [], // Tocar tratará a queue localmente na playlist
                          showIndex: false,
                          onTap: () async {
                            try {
                              // Busca todas as músicas da playlist de origem
                              final playlistTracks = await AppDatabase.instance.getTracksForPlaylist(track.playlistId);
                              final availableTracks = playlistTracks.where((t) => t.isCached).toList();
                              
                              if (availableTracks.isEmpty) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Nenhuma música baixada nesta playlist.')),
                                  );
                                }
                                return;
                              }

                              // Toca a música usando as faixas da própria playlist como fila de reprodução
                              await ref.read(playerProvider.notifier).playTrack(track, availableTracks);
                            } catch (e) {
                              print('Erro ao tocar música da busca: $e');
                            }
                          },
                        ),
                      ],
                    );
                  },
                ),
    );
  }

  Widget _buildPlaceholder() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.search_rounded, size: 64, color: AppColors.surfaceHigh),
          SizedBox(height: 16),
          Text('Busque em toda sua biblioteca local', 
            style: TextStyle(color: AppColors.textMuted)),
        ],
      ),
    );
  }
}
