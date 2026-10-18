import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/track.dart';

class SpotifyService {
  static String? _cachedAccessToken;
  static int _tokenExpirationMs = 0;

  /// Extrai e limpa o ID de uma playlist do Spotify a partir de links, URIs ou IDs puros.
  static String? parsePlaylistId(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return null;

    // 1. Caso de URL da web ou URI (ex: open.spotify.com/.../playlist/37i9dQZF1DXcBWIGoYBM5M ou spotify:playlist:...)
    final playlistUrlRegex = RegExp(r'playlist[/:]([a-zA-Z0-9]{15,30})');
    final matchUrl = playlistUrlRegex.firstMatch(raw);
    if (matchUrl != null) {
      return matchUrl.group(1);
    }

    // 2. ID puro de 15 a 30 caracteres alfanuméricos
    final pureIdRegex = RegExp(r'^[a-zA-Z0-9]{15,30}$');
    if (pureIdRegex.hasMatch(raw)) {
      return raw;
    }

    return null;
  }

  /// Tenta resolver URLs encurtadas (como spotify.link/...) caso o parser direto falhar.
  static Future<String?> extractPlaylistIdAsync(String input) async {
    final parsed = parsePlaylistId(input);
    if (parsed != null) return parsed;

    // Procura por qualquer URL http(s) dentro do texto colado
    final urlRegex = RegExp(r'https?://[^\s]+');
    final match = urlRegex.firstMatch(input.trim());
    if (match != null) {
      final urlStr = match.group(0)!;
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 8);
        final request = await client.getUrl(Uri.parse(urlStr));
        request.followRedirects = true;
        request.maxRedirects = 5;
        final response = await request.close();
        
        final finalUrl = response.redirects.isNotEmpty
            ? response.redirects.last.location.toString()
            : request.uri.toString();
            
        final redirectedParsed = parsePlaylistId(finalUrl);
        if (redirectedParsed != null) return redirectedParsed;
      } catch (_) {}
    }
    return null;
  }

  /// Obtém um access token anônimo funcional do Spotify.
  /// Nunca solicita o token da página de embed da própria playlist (pois não contém token),
  /// usando URLs de embed de faixas/editoriais confiáveis.
  Future<String?> _getToken() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_cachedAccessToken != null && now < _tokenExpirationMs - 60000) {
      return _cachedAccessToken;
    }

    final targetUrls = [
      'https://open.spotify.com/embed/track/4cOdK2wGLETKBW3PvgPWqT',
      'https://open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M',
    ];

    for (final targetUrl in targetUrls) {
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 8);
        final request = await client.getUrl(Uri.parse(targetUrl));
        request.headers.set(
          'User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
        );

        final response = await request.close();
        if (response.statusCode == 200) {
          final html = await response.transform(utf8.decoder).join();
          final match = RegExp(r'"accessToken":"([^"]+)"').firstMatch(html);
          if (match != null && match.group(1) != null) {
            _cachedAccessToken = match.group(1)!;
            _tokenExpirationMs = now + (3000 * 1000);
            return _cachedAccessToken;
          }
        }
      } catch (e) {
        debugPrint('[SpotifyService] Erro ao obter token em $targetUrl: $e');
      }
    }

    return null;
  }

  /// Obtém metadados da playlist (Nome, Descrição, Capa, Total de Faixas).
  Future<Map<String, dynamic>?> getPlaylistDetails(String playlistId) async {
    final cleanId = parsePlaylistId(playlistId) ?? playlistId.trim().split('?')[0].replaceAll('/', '');
    final token = await _getToken();

    // Método 1: Tentar via GQL queryPlaylist (retorna todos os detalhes completos)
    if (token != null) {
      try {
        const gqlHash = '908a5597b4d0af0489a9ad6a2d41bc3b416ff47c0884016d92bbd6822d0eb6d8';
        final variables = jsonEncode({
          'uri': 'spotify:playlist:$cleanId',
          'offset': 0,
          'limit': 1,
        });
        final extensions = jsonEncode({
          'persistedQuery': {
            'version': 1,
            'sha256Hash': gqlHash,
          }
        });

        final queryUri = Uri.parse(
          'https://api-partner.spotify.com/pathfinder/v1/query'
          '?operationName=queryPlaylist'
          '&variables=${Uri.encodeComponent(variables)}'
          '&extensions=${Uri.encodeComponent(extensions)}',
        );

        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 10);
        final request = await client.getUrl(queryUri);
        request.headers.set('Authorization', 'Bearer $token');
        request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
        request.headers.set('App-Platform', 'WebPlayer');

        final response = await request.close();
        if (response.statusCode == 200) {
          final responseBody = await response.transform(utf8.decoder).join();
          final gdata = jsonDecode(responseBody);
          final pdata = gdata['data']?['playlistV2'];

          if (pdata != null && pdata['__typename'] == 'Playlist') {
            final name = (pdata['name'] as String?) ?? 'Playlist do Spotify';
            final description = (pdata['description'] as String?) ?? '';
            final images = pdata['images']?['items'] as List? ?? [];
            String imageUrl = '';
            if (images.isNotEmpty && images[0]['sources'] != null) {
              final sources = images[0]['sources'] as List? ?? [];
              if (sources.isNotEmpty) {
                imageUrl = sources[0]['url'] ?? '';
              }
            }
            final totalTracks = (pdata['content']?['totalCount'] as int?) ?? 0;

            return {
              'name': name,
              'description': description,
              'image_url': imageUrl,
              'spotify_url': 'https://open.spotify.com/playlist/$cleanId',
              'total_tracks': totalTracks,
            };
          }
        }
      } catch (e) {
        debugPrint('[SpotifyService] Erro ao obter detalhes da playlist via GQL: $e');
      }
    }

    // Método 2: Fallback via Embed HTML
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final embedUrl = 'https://open.spotify.com/embed/playlist/$cleanId';
      final request = await client.getUrl(Uri.parse(embedUrl));
      request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');

      final response = await request.close();
      if (response.statusCode == 200) {
        final html = await response.transform(utf8.decoder).join();
        final match = RegExp(r'<script id="__NEXT_DATA__" type="application/json">([^<]+)</script>').firstMatch(html);
        if (match != null && match.group(1) != null) {
          final data = jsonDecode(match.group(1)!);
          final entity = data['props']?['pageProps']?['state']?['data']?['entity'];
          if (entity != null) {
            final images = entity['coverArt']?['sources'] as List? ?? [];
            final imageUrl = images.isNotEmpty ? images[0]['url'] : '';

            return {
              'name': entity['name'] ?? entity['title'] ?? 'Playlist do Spotify',
              'description': entity['subtitle'] ?? '',
              'image_url': imageUrl,
              'spotify_url': 'https://open.spotify.com/playlist/$cleanId',
              'total_tracks': entity['trackList']?.length ?? 0,
            };
          }
        }
      }
    } catch (_) {}

    return {
      'name': 'Playlist do Spotify',
      'description': '',
      'image_url': '',
      'spotify_url': 'https://open.spotify.com/playlist/$cleanId',
      'total_tracks': 0,
    };
  }

  Future<String?> getPlaylistSnapshot(String playlistId) async {
    final cleanId = parsePlaylistId(playlistId) ?? playlistId.trim().split('?')[0].replaceAll('/', '');
    final token = await _getToken();
    if (token == null) return null;

    try {
      final client = HttpClient();
      final url = 'https://api.spotify.com/v1/playlists/$cleanId?fields=snapshot_id';
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Authorization', 'Bearer $token');

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      final data = jsonDecode(responseBody);

      return data['snapshot_id'];
    } catch (e) {
      return null;
    }
  }

  /// Paginador ilimitado de faixas usando Spotify GQL Pathfinder com fallback para Embed HTML.
  Future<List<Track>> getPlaylistTracks(
    String playlistId, {
    Function(int)? onProgress,
    Future<void> Function(List<Track>)? onTracksFetched,
  }) async {
    final cleanId = parsePlaylistId(playlistId) ?? playlistId.trim().split('?')[0].replaceAll('/', '');
    final token = await _getToken();

    // ── Método 1: GQL queryPlaylist com paginação total ──────────────────
    if (token != null) {
      try {
        debugPrint('[SpotifyService] Iniciando extração GQL para a playlist $cleanId...');
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 15);

        const gqlHash = '908a5597b4d0af0489a9ad6a2d41bc3b416ff47c0884016d92bbd6822d0eb6d8';
        List<Track> allGqlTracks = [];
        int offset = 0;
        bool hasMore = true;
        int totalCount = 0;

        while (hasMore) {
          final variables = jsonEncode({
            'uri': 'spotify:playlist:$cleanId',
            'offset': offset,
            'limit': 100,
          });

          final extensions = jsonEncode({
            'persistedQuery': {
              'version': 1,
              'sha256Hash': gqlHash,
            }
          });

          final queryUri = Uri.parse(
            'https://api-partner.spotify.com/pathfinder/v1/query'
            '?operationName=queryPlaylist'
            '&variables=${Uri.encodeComponent(variables)}'
            '&extensions=${Uri.encodeComponent(extensions)}',
          );

          final request = await client.getUrl(queryUri);
          request.headers.set('Authorization', 'Bearer $token');
          request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
          request.headers.set('App-Platform', 'WebPlayer');

          final response = await request.close();
          if (response.statusCode != 200) break;

          final responseBody = await response.transform(utf8.decoder).join();
          final gdata = jsonDecode(responseBody);

          final pdata = gdata['data']?['playlistV2'];
          if (pdata == null || pdata['__typename'] != 'Playlist') {
            break;
          }

          final content = pdata['content'];
          if (content == null) break;
          totalCount = (content['totalCount'] as int?) ?? totalCount;

          final items = content['items'] as List? ?? [];
          if (items.isEmpty) {
            hasMore = false;
            break;
          }

          final List<Track> batchTracks = [];
          for (final item in items) {
            final tdata = item['itemV2']?['data'];
            if (tdata == null) continue;

            final title = (tdata['name'] as String?) ?? '';
            if (title.isEmpty) continue;

            final uri = (tdata['uri'] as String?) ?? '';
            final trackId = uri.contains(':') ? uri.split(':').last : (tdata['id'] as String? ?? '');
            if (trackId.isEmpty) continue;

            final artistItems = tdata['artists']?['items'] as List? ?? [];
            final artistList = artistItems
                .map((a) => a['profile']?['name'] as String?)
                .where((name) => name != null && name.isNotEmpty)
                .cast<String>()
                .toList();

            final artist = artistList.isNotEmpty ? artistList.join(', ') : 'Artista Desconhecido';
            final primaryArtist = artistList.isNotEmpty ? artistList.first : artist;

            final albumObj = tdata['albumOfTrack'];
            final albumName = (albumObj?['name'] as String?) ?? '';
            final coverSources = albumObj?['coverArt']?['sources'] as List? ?? [];
            final coverUrl = coverSources.isNotEmpty ? coverSources[0]['url'] as String? : null;

            final durationMs = (tdata['trackDuration']?['totalMilliseconds'] as int?) ?? 0;

            batchTracks.add(Track(
              id: trackId,
              spotifyUri: uri.isNotEmpty ? uri : 'spotify:track:$trackId',
              playlistPosition: allGqlTracks.length + batchTracks.length,
              title: title,
              artist: artist,
              primaryArtist: primaryArtist,
              album: albumName,
              albumArtUrl: coverUrl,
              durationMs: durationMs,
              playlistId: cleanId,
              spotifyUrl: 'https://open.spotify.com/track/$trackId',
            ));
          }

          if (batchTracks.isEmpty) {
            hasMore = false;
          } else {
            allGqlTracks.addAll(batchTracks);
            if (onTracksFetched != null) await onTracksFetched(batchTracks);
            if (onProgress != null) onProgress(allGqlTracks.length);

            offset += batchTracks.length;
            if (batchTracks.length < 100 || (totalCount > 0 && offset >= totalCount)) {
              hasMore = false;
            }
          }
        }

        if (allGqlTracks.isNotEmpty) {
          debugPrint('[SpotifyService] Sucesso GQL: ${allGqlTracks.length} faixas extraídas com sucesso!');
          return allGqlTracks;
        }
      } catch (gqlErr) {
        debugPrint('[SpotifyService] Erro na extração GQL: $gqlErr');
      }
    }

    // ── Método 2: Fallback Embed HTML (até 50 faixas) ────────────────────
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final embedUrl = 'https://open.spotify.com/embed/playlist/$cleanId';
      final request = await client.getUrl(Uri.parse(embedUrl));
      request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');

      final response = await request.close();
      if (response.statusCode == 200) {
        final html = await response.transform(utf8.decoder).join();
        final match = RegExp(r'<script id="__NEXT_DATA__" type="application/json">([^<]+)</script>').firstMatch(html);
        if (match != null && match.group(1) != null) {
          final data = jsonDecode(match.group(1)!);
          final entity = data['props']?['pageProps']?['state']?['data']?['entity'];
          final trackList = entity?['trackList'] as List? ?? [];

          if (trackList.isNotEmpty) {
            List<Track> embedTracks = [];
            int pos = 0;
            for (final item in trackList) {
              final uri = (item['uri'] as String?) ?? '';
              final tId = uri.split(':').last;
              final title = (item['title'] as String?) ?? '';
              if (tId.isEmpty || title.isEmpty) continue;

              final artist = (item['subtitle'] as String?) ?? 'Artista Desconhecido';
              final durationMs = (item['duration'] as int?) ?? 0;
              final explicit = (item['isExplicit'] as bool?) ?? false;

              embedTracks.add(Track(
                id: tId,
                spotifyUri: uri.isNotEmpty ? uri : 'spotify:track:$tId',
                playlistPosition: pos++,
                title: title,
                artist: artist,
                primaryArtist: artist.split(',').first.trim(),
                durationMs: durationMs,
                explicit: explicit,
                playlistId: cleanId,
                spotifyUrl: 'https://open.spotify.com/track/$tId',
              ));
            }

            if (embedTracks.isNotEmpty) {
              debugPrint('[SpotifyService] Sucesso Embed HTML: ${embedTracks.length} faixas extraídas com sucesso!');
              if (onTracksFetched != null) await onTracksFetched(embedTracks);
              if (onProgress != null) onProgress(embedTracks.length);
              return embedTracks;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[SpotifyService] Aviso no método Embed HTML: $e');
    }

    return [];
  }
}

