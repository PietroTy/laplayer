import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Resultado de uma busca remota no YouTube (via backend).
class RemoteTrack {
  final String youtubeId;
  final String title;
  final String artist;
  final int durationMs;
  final String thumbnail;
  final String url;

  const RemoteTrack({
    required this.youtubeId,
    required this.title,
    required this.artist,
    required this.durationMs,
    required this.thumbnail,
    required this.url,
  });

  String get durationFormatted {
    final d = Duration(milliseconds: durationMs);
    final min = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$min:$sec';
  }

  factory RemoteTrack.fromJson(Map<String, dynamic> json) => RemoteTrack(
        youtubeId:  json['youtube_id']  ?? '',
        title:      json['title']       ?? '',
        artist:     json['artist']      ?? '',
        durationMs: json['duration_ms'] ?? 0,
        thumbnail:  json['thumbnail']   ?? '',
        url:        json['url']         ?? '',
      );
}

class SearchService {
  static const _githubRepo = 'PietroTy/laplayer';

  /// Descobre a URL do servidor (igual ao ServerDownloader).
  Future<String> _resolveServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final tempDio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final rawUrl =
          'https://raw.githubusercontent.com/$_githubRepo/main/server_url.txt?t=$timestamp';
      final res = await tempDio.get(rawUrl);
      if (res.statusCode == 200 && res.data != null) {
        final fetched = res.data.toString().replaceAll(RegExp(r'\s+'), '');
        if (fetched.startsWith('http')) {
          await prefs.setString('server_url', fetched);
        }
      }
    } catch (_) {}

    final cached = prefs.getString('server_url')?.replaceAll(RegExp(r'\s+'), '') ?? '';
    if (cached.isEmpty) {
      throw Exception('Servidor indisponível. Verifique a conexão.');
    }

    final base = cached.endsWith('/') ? cached.substring(0, cached.length - 1) : cached;
    return base;
  }

  /// Busca músicas no YouTube sem baixar nada.
  /// Lança exceção se o servidor não estiver disponível.
  Future<List<RemoteTrack>> search(String query, {int limit = 8}) async {
    if (query.trim().isEmpty) return [];

    final base = await _resolveServerUrl();
    final url = '$base/api/search';

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ));

    final res = await dio.get(url, queryParameters: {'q': query.trim(), 'limit': limit});

    if (res.statusCode != 200) {
      throw Exception('Erro ${res.statusCode} ao buscar no servidor.');
    }

    final entries = (res.data['results'] as List? ?? []);
    return entries
        .map((e) => RemoteTrack.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
