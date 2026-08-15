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

    // 1. Caso de URL da web (ex: open.spotify.com/.../playlist/37i9dQZF1DXcBWIGoYBM5M)
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

    final trimmed = input.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 8);
        final request = await client.getUrl(Uri.parse(trimmed));
        request.followRedirects = false;
        final response = await request.close();
        final location = response.headers.value('location');
        if (location != null && location.isNotEmpty) {
          final redirectedParsed = parsePlaylistId(location);
          if (redirectedParsed != null) return redirectedParsed;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<String?> _getToken([String? playlistId]) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_cachedAccessToken != null && now < _tokenExpirationMs - 60000) {
      return _cachedAccessToken;
    }

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final targetUrl = playlistId != null && playlistId.isNotEmpty
          ? 'https://open.spotify.com/embed/playlist/$playlistId'
          : 'https://open.spotify.com/embed/track/4cOdK2wGLETKBW3PvgPWqT';
          
      final request = await client.getUrl(Uri.parse(targetUrl));
      request.headers.set(
        'User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      );

      final response = await request.close();
      final html = await response.transform(utf8.decoder).join();

      final match = RegExp(r'"accessToken":"([^"]+)"').firstMatch(html);
      if (match != null && match.group(1) != null) {
        _cachedAccessToken = match.group(1)!;
        _tokenExpirationMs = now + (3000 * 1000);
        return _cachedAccessToken;
      }

      throw 'Token anônimo não encontrado no HTML';
    } catch (e) {
      if (e is SocketException) throw 'Falha de conexão com Spotify.';
      throw '$e';
    }
  }

  Future<Map<String, dynamic>?> getPlaylistDetails(String playlistId) async {
    final cleanId = parsePlaylistId(playlistId) ?? playlistId.trim().split('?')[0].replaceAll('/', '');
    
    // Método 1: Tentar via embed HTML (100% público e sem rate-limit)
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
              'name': entity['name'] ?? entity['title'] ?? 'Playlist',
              'description': entity['subtitle'] ?? '',
              'image_url': imageUrl,
              'spotify_url': 'https://open.spotify.com/playlist/$cleanId',
              'total_tracks': entity['trackList']?.length ?? 0,
            };
          }
        }
      }
    } catch (_) {}

    // Método 2: Fallback via API com token anônimo
    final token = await _getToken(cleanId);
    if (token == null) return null;

    try {
      final client = HttpClient();
      final url = 'https://api.spotify.com/v1/playlists/$cleanId?fields=name,description,images,external_urls,tracks(total)';
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
      
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      final data = jsonDecode(responseBody);

      if (response.statusCode == 200) {
        final images = data['images'] as List? ?? [];
        final imageUrl = images.isNotEmpty ? images[0]['url'] : '';

        return {
          'name': data['name'] ?? 'Playlist',
          'description': data['description'] ?? '',
          'image_url': imageUrl,
          'spotify_url': data['external_urls']?['spotify'] ?? '',
          'total_tracks': data['tracks']?['total'] ?? 0,
        };
      }
    } catch (e) {
      debugPrint('[SpotifyService] Erro ao obter detalhes da playlist via API: $e');
    }
    
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
    final token = await _getToken(cleanId);
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

  /// Paginador ilimitado de faixas usando Spotify GQL Pathfinder (capaz de puxar playlists de 10.000+ faixas)
  Future<List<Track>> getPlaylistTracks(
    String playlistId, {
    Function(int)? onProgress,
    Function(List<Track>)? onTracksFetched,
  }) async {
    final cleanId = parsePlaylistId(playlistId) ?? playlistId.trim().split('?')[0].replaceAll('/', '');
    final token = await _getToken(cleanId);

    if (token != null) {
      try {
        debugPrint('[SpotifyService] Iniciando extração GQL para a playlist $cleanId...');
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 15);
        
        const gqlHash = '86dde7b9d9356e2369414647cf6950cfed96e778e129cfdfc99aea6c1613b3b0';
        List<Track> allGqlTracks = [];
        int offset = 0;
        bool hasMore = true;

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
            '?operationName=fetchPlaylistContents'
            '&variables=${Uri.encodeComponent(variables)}'
            '&extensions=${Uri.encodeComponent(extensions)}',
          );

          final request = await client.getUrl(queryUri);
          request.headers.set('Authorization', 'Bearer $token');
          request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
          request.headers.set('App-Platform', 'WebPlayer');

          final response = await request.close();
          if (response.statusCode != 200) {
            debugPrint('[SpotifyService] GQL retornou status ${response.statusCode} no offset $offset');
            break;
          }

          final responseBody = await response.transform(utf8.decoder).join();
          final gdata = jsonDecode(responseBody);

          final items = gdata['data']?['playlistV2']?['content']?['items'] as List? ?? [];
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
            if (onTracksFetched != null) onTracksFetched(batchTracks);
            if (onProgress != null) onProgress(allGqlTracks.length);

            offset += 100;
            if (items.length < 100) {
              hasMore = false;
            }
          }
        }

        if (allGqlTracks.isNotEmpty) {
          debugPrint('[SpotifyService] Sucesso GQL: ${allGqlTracks.length} faixas extraídas com sucesso!');
          return allGqlTracks;
        }
      } catch (gqlErr) {
        debugPrint('[SpotifyService] Erro durante paginação GQL: $gqlErr. Recorrendo a fallbacks...');
      }
    }

    // Método 2: Fallback via Embed HTML (caso GQL falhe)
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
              if (onTracksFetched != null) onTracksFetched(embedTracks);
              if (onProgress != null) onProgress(embedTracks.length);
              return embedTracks;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[SpotifyService] Erro no fallback Embed HTML: $e');
    }

    return [];
  }
}
