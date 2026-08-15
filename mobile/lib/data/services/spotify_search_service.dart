import 'dart:convert';
import 'package:dio/dio.dart';
import '../models/track.dart';

/// Serviço que faz buscas de músicas na API oficial do Spotify usando Client Credentials.
class SpotifySearchService {
  SpotifySearchService._();
  static final instance = SpotifySearchService._();

  final Dio _dio = Dio();
  String? _accessToken;
  int _tokenExpirationMs = 0;

  /// Obtém um token web anônimo do Spotify (usado publicamente pelo player web embed).
  Future<String> _getAccessToken() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_accessToken != null && now < _tokenExpirationMs - 60000) {
      return _accessToken!;
    }

    try {
      final response = await _dio.get(
        'https://open.spotify.com/embed/track/4cOdK2wGLETKBW3PvgPWqT',
        options: Options(
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          },
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final html = response.data.toString();
        final match = RegExp(r'"accessToken":"([^"]+)"').firstMatch(html);
        if (match != null && match.group(1) != null) {
          _accessToken = match.group(1)!;
          // Token web costuma durar cerca de 1 hora (3600s)
          _tokenExpirationMs = now + (3000 * 1000);
          return _accessToken!;
        }
      }
    } catch (e) {
      print('[SpotifySearchService] Erro ao obter token anônimo do Spotify: $e');
    }
    return '';
  }

  /// Pesquisa faixas globais no Spotify
  Future<List<Track>> searchTracks(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return [];

    final token = await _getAccessToken();
    if (token.isEmpty) return [];

    try {
      final response = await _dio.get(
        'https://api.spotify.com/v1/search',
        queryParameters: {
          'q': query,
          'type': 'track',
          'limit': limit,
        },
        options: Options(headers: {
          'Authorization': 'Bearer $token',
        }),
      );

      if (response.statusCode == 200 && response.data != null && response.data['tracks'] != null) {
        final items = response.data['tracks']['items'] as List? ?? [];
        return items.map<Track?>((item) {
          if (item == null) return null;
          final id = (item['id'] as String?) ?? '';
          final title = (item['name'] as String?) ?? '';
          if (id.isEmpty || title.isEmpty) return null;

          final artists = (item['artists'] as List? ?? [])
              .map((a) => (a['name'] as String?) ?? '')
              .where((name) => name.isNotEmpty)
              .join(', ');

          final album = (item['album']?['name'] as String?) ?? '';
          final durationMs = (item['duration_ms'] as int?) ?? 0;

          String? coverUrl;
          final images = item['album']?['images'] as List? ?? [];
          if (images.isNotEmpty && images.first?['url'] != null) {
            coverUrl = images.first['url'] as String;
          }

          return Track(
            id: id,
            spotifyUri: 'spotify:track:$id',
            title: title,
            artist: artists.isNotEmpty ? artists : 'Artista Desconhecido',
            album: album,
            durationMs: durationMs,
            albumArtUrl: coverUrl,
            playlistId: '',
            downloadStatus: 'not_downloaded',
          );
        }).whereType<Track>().toList();
      }
    } catch (e) {
      print('[SpotifySearchService] Erro ao buscar faixas: $e');
    }

    return [];
  }
}

