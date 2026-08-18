import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/track.dart';

/// Serviço que faz buscas de músicas na API oficial do Spotify usando Client Credentials ou Proxy no Servidor.
class SpotifySearchService {
  SpotifySearchService._();
  static final instance = SpotifySearchService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
  ));
  String? _accessToken;
  int _tokenExpirationMs = 0;

  Future<String> _getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('server_url') ?? '';
    return url.isNotEmpty ? url : 'https://laplayer-api.magiktarot.com.br';
  }

  Future<String> _getAccessKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('access_key') ?? 'LAPLAYER-VIP-8812';
  }

  /// Obtém um token web anônimo do Spotify (usado publicamente pelo player web embed)
  /// com fallback automático para o servidor backend.
  Future<String> _getAccessToken() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_accessToken != null && now < _tokenExpirationMs - 60000) {
      return _accessToken!;
    }

    final headers = {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
      'Accept-Language': 'pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7',
    };

    final urls = [
      'https://open.spotify.com/embed/track/4cOdK2wGLETKBW3PvgPWqT',
      'https://open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M',
    ];

    for (final url in urls) {
      try {
        final response = await _dio.get(
          url,
          options: Options(headers: headers),
        );

        if (response.statusCode == 200 && response.data != null) {
          final html = response.data.toString();
          final match = RegExp(r'"accessToken":"([^"]+)"').firstMatch(html);
          if (match != null && match.group(1) != null) {
            _accessToken = match.group(1)!;
            _tokenExpirationMs = now + (3000 * 1000);
            print('[SpotifySearchService] Token obtido diretamente via Embed!');
            return _accessToken!;
          }
        }
      } catch (e) {
        print('[SpotifySearchService] Tentativa direta via $url falhou: $e');
      }
    }

    // ── FALLBACK: Servidor Backend (Proxy) ──
    try {
      final sUrl = await _getServerUrl();
      final aKey = await _getAccessKey();
      print('[SpotifySearchService] Tentando obter token via servidor backend: $sUrl');

      final response = await _dio.get(
        '$sUrl/api/spotify/token',
        options: Options(headers: {'X-Access-Key': aKey}),
      );

      if (response.statusCode == 200 && response.data != null) {
        final token = response.data['access_token'] as String?;
        if (token != null && token.isNotEmpty) {
          _accessToken = token;
          _tokenExpirationMs = now + (3000 * 1000);
          print('[SpotifySearchService] Token obtido via servidor backend!');
          return _accessToken!;
        }
      }
    } catch (e) {
      print('[SpotifySearchService] Erro ao obter token via servidor backend: $e');
    }

    return '';
  }

  /// Pesquisa faixas globais no Spotify (Direto com fallback para servidor backend)
  Future<List<Track>> searchTracks(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return [];

    final token = await _getAccessToken();
    
    // Tenta primeiro direto se tiver token
    if (token.isNotEmpty) {
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
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          }),
        );

        if (response.statusCode == 200 && response.data != null && response.data['tracks'] != null) {
          final items = response.data['tracks']['items'] as List? ?? [];
          final tracks = _parseSpotifyItems(items);
          if (tracks.isNotEmpty) return tracks;
        }
      } catch (e) {
        print('[SpotifySearchService] Busca direta falhou ou foi bloqueada ($e). Usando fallback proxy do servidor...');
      }
    }

    // ── FALLBACK PROXY: Busca via Servidor Backend ──
    try {
      final sUrl = await _getServerUrl();
      final aKey = await _getAccessKey();
      print('[SpotifySearchService] Pesquisando Spotify via proxy do servidor: $sUrl');

      final response = await _dio.get(
        '$sUrl/api/spotify/search',
        queryParameters: {'q': query, 'limit': limit},
        options: Options(headers: {'X-Access-Key': aKey}),
      );

      if (response.statusCode == 200 && response.data != null && response.data['tracks'] != null) {
        final items = response.data['tracks']['items'] as List? ?? [];
        return _parseSpotifyItems(items);
      }
    } catch (e) {
      print('[SpotifySearchService] Erro ao buscar Spotify via proxy do servidor: $e');
    }

    return [];
  }

  List<Track> _parseSpotifyItems(List items) {
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
}

