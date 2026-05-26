import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/track.dart';

class SpotifyService {
  String? _accessToken;

  Future<String?> _getToken() async {
    final prefs = await SharedPreferences.getInstance();
    String? clientId = prefs.getString('spotify_client_id')?.trim();
    String? clientSecret = prefs.getString('spotify_client_secret')?.trim();

    if (clientId != null && clientId.contains('=')) clientId = clientId.split('=').last.trim();
    if (clientSecret != null && clientSecret.contains('=')) clientSecret = clientSecret.split('=').last.trim();

    if (clientId == null || clientId.isEmpty || clientSecret == null || clientSecret.isEmpty) {
      throw 'Configuração incompleta: Spotify Client ID ou Secret não encontrados.';
    }

    try {
      final auth = base64Encode(utf8.encode('$clientId:$clientSecret')).replaceAll('\n', '').replaceAll('\r', '');
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      final request = await client.postUrl(Uri.parse('https://accounts.spotify.com/api/token'));
      request.headers.set('Authorization', 'Basic $auth');
      request.headers.set('Content-Type', 'application/x-www-form-urlencoded');
      request.write('grant_type=client_credentials');
      
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      final data = jsonDecode(responseBody);

      if (response.statusCode != 200) {
        throw 'Spotify recusou: ${data['error_description'] ?? data['error'] ?? 'Erro ${response.statusCode}'}';
      }

      _accessToken = data['access_token'];
      return _accessToken;
    } catch (e) {
      if (e is SocketException) throw 'Falha de conexão com Spotify.';
      throw '$e';
    }
  }

  Future<Map<String, dynamic>?> getPlaylistDetails(String playlistId) async {
    final cleanId = playlistId.trim().split('?')[0];
    final token = await _getToken();
    if (token == null) return null;

    try {
      final client = HttpClient();
      final url = 'https://api.spotify.com/v1/playlists/$cleanId?fields=name,description,images,external_urls,tracks(total)';
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Authorization', 'Bearer $token');
      
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      final data = jsonDecode(responseBody);

      if (response.statusCode != 200) throw 'Erro ${response.statusCode} nos detalhes.';

      final images = data['images'] as List? ?? [];
      final imageUrl = images.isNotEmpty ? images[0]['url'] : '';

      return {
        'name': data['name'],
        'description': data['description'] ?? '',
        'image_url': imageUrl,
        'spotify_url': data['external_urls']?['spotify'] ?? '',
        'total_tracks': data['tracks']['total'],
      };
    } catch (e) {
      throw 'Falha ao buscar detalhes: $e';
    }
  }

  Future<String?> getPlaylistSnapshot(String playlistId) async {
    final cleanId = playlistId.trim().split('?')[0];
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

  Future<List<Track>> getPlaylistTracks(
    String playlistId, {
    Function(int)? onProgress,
    Function(List<Track>)? onTracksFetched,
  }) async {
    final cleanId = playlistId.trim().split('?')[0]; // Remove lixo do ID
    final token = await _getToken();
    if (token == null) return [];

    List<Track> tracks = [];
    String? nextUrl = 'https://api.spotify.com/v1/playlists/$cleanId/tracks?limit=100';
    int currentPosition = 0;

    try {
      final client = HttpClient();
      while (nextUrl != null) {
        print('DEBUG Spotify: [TrackSync] Requisitando: $nextUrl');
        final request = await client.getUrl(Uri.parse(nextUrl));
        request.headers.set('Authorization', 'Bearer $token');
        
        final response = await request.close();
        final responseBody = await response.transform(utf8.decoder).join();
        
        if (response.statusCode != 200) {
          print('Spotify Track Error ${response.statusCode}: $responseBody');
          throw 'Erro ${response.statusCode} ao listar músicas: $responseBody';
        }

        final data = jsonDecode(responseBody);
        final List items = data['items'] ?? [];
        final List<Track> pageTracks = [];
        for (final item in items) {
          if (item != null && item['track'] != null) {
            pageTracks.add(Track.fromSpotify(item['track'], cleanId, currentPosition++));
          }
        }
        tracks.addAll(pageTracks);
        if (onTracksFetched != null) {
          onTracksFetched(pageTracks);
        }
        if (onProgress != null) onProgress(tracks.length);
        nextUrl = data['next'];
      }
      return tracks;
    } catch (e) {
      throw 'Falha ao baixar músicas: $e';
    }
  }
}
