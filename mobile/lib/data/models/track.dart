/// Modelo de uma faixa de música
class Track {
  final String id;               // spotify_id
  final String spotifyUri;
  final String isrc;
  final int    playlistPosition;
  final String title;
  final String artist;
  final String primaryArtist;
  final String album;
  final String albumArtist;
  final String? albumArtUrl;     // URL remota (do servidor)
  final String releaseDate;
  final String releaseYear;
  final List<String> genres;
  final int    durationMs;
  final int    trackNumber;
  final int    totalTracks;
  final int    discNumber;
  final bool   explicit;
  final String spotifyUrl;

  // ── Campos locais (app) ────────────────────────────────────────────────
  final String  playlistId;
  final String? localFilename;   // Ex: "0001. Artist - Title.m4a"
  final String  downloadStatus;  // "success" | "failed" | "pending"
  final bool    available;       // arquivo existe no servidor
  final bool    isCached;        // arquivo existe localmente no app

  const Track({
    required this.id,
    required this.spotifyUri,
    this.isrc             = '',
    this.playlistPosition = 0,
    required this.title,
    required this.artist,
    this.primaryArtist    = '',
    this.album            = '',
    this.albumArtist      = '',
    this.albumArtUrl,
    this.releaseDate      = '',
    this.releaseYear      = '',
    this.genres           = const [],
    this.durationMs       = 0,
    this.trackNumber      = 1,
    this.totalTracks      = 1,
    this.discNumber       = 1,
    this.explicit         = false,
    this.spotifyUrl       = '',
    required this.playlistId,
    this.localFilename,
    this.downloadStatus   = 'pending',
    this.available        = false,
    this.isCached         = false,
  });

  // ── Utilitários ────────────────────────────────────────────────────────

  /// Duração formatada (ex: "3:45")
  String get durationFormatted {
    final total = Duration(milliseconds: durationMs);
    final min   = total.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec   = total.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${total.inMinutes >= 60 ? '${total.inHours}:' : ''}$min:$sec';
  }

  /// URL de stream do arquivo no servidor
  String streamUrl(String serverBase) =>
      '$serverBase/tracks/$playlistId/${Uri.encodeComponent(localFilename ?? '')}/stream';

  // ── Serialização ──────────────────────────────────────────────────────

  factory Track.fromSpotify(Map<String, dynamic> item, String playlistId, int position) {
    final album = item['album'] ?? {};
    final artists = (item['artists'] as List? ?? []);
    final albumArt = (album['images'] as List? ?? []).isNotEmpty 
        ? album['images'][0]['url'] 
        : null;

    return Track(
      id:               item['id'] ?? '',
      spotifyUri:       item['uri'] ?? '',
      playlistPosition: position,
      title:            item['name'] ?? '',
      artist:           artists.map((a) => a['name']).join(', '),
      primaryArtist:    artists.isNotEmpty ? artists[0]['name'] : '',
      album:            album['name'] ?? '',
      albumArtist:      (album['artists'] as List? ?? []).isNotEmpty 
          ? album['artists'][0]['name'] 
          : '',
      albumArtUrl:      albumArt,
      releaseDate:      album['release_date'] ?? '',
      releaseYear:      (album['release_date'] as String? ?? '').split('-')[0],
      durationMs:       item['duration_ms'] ?? 0,
      trackNumber:      item['track_number'] ?? 1,
      totalTracks:      album['total_tracks'] ?? 1,
      discNumber:       item['disc_number'] ?? 1,
      explicit:         item['explicit'] ?? false,
      spotifyUrl:       item['external_urls']?['spotify'] ?? '',
      playlistId:       playlistId,
    );
  }

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      id:               json['id']              ?? json['spotify_id'] ?? '',
      spotifyUri:       json['spotify_uri']     ?? '',
      isrc:             json['isrc']            ?? '',
      playlistPosition: json['playlist_position'] ?? 0,
      title:            json['title']           ?? '',
      artist:           json['artist']          ?? '',
      primaryArtist:    json['primary_artist']  ?? '',
      album:            json['album']           ?? '',
      albumArtist:      json['album_artist']    ?? '',
      albumArtUrl:      json['album_art_url'],
      releaseDate:      json['release_date']    ?? '',
      releaseYear:      json['release_year']    ?? '',
      genres:           List<String>.from(json['genres'] ?? []),
      durationMs:       json['duration_ms']     ?? 0,
      trackNumber:      json['track_number']    ?? 1,
      totalTracks:      json['total_tracks']    ?? 1,
      discNumber:       json['disc_number']     ?? 1,
      explicit:         json['explicit']        ?? false,
      spotifyUrl:       json['spotify_url']     ?? '',
      playlistId:       json['playlist_id']     ?? '',
      localFilename:    json['local_filename'],
      downloadStatus:   json['download_status'] ?? 'pending',
      available:        json['available']       ?? false,
      isCached:         json['is_cached']       ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id':               id,
    'spotify_uri':      spotifyUri,
    'isrc':             isrc,
    'playlist_position': playlistPosition,
    'title':            title,
    'artist':           artist,
    'primary_artist':   primaryArtist,
    'album':            album,
    'album_artist':     albumArtist,
    'album_art_url':    albumArtUrl,
    'release_date':     releaseDate,
    'release_year':     releaseYear,
    'genres':           genres,
    'duration_ms':      durationMs,
    'track_number':     trackNumber,
    'total_tracks':     totalTracks,
    'disc_number':      discNumber,
    'explicit':         explicit,
    'spotify_url':      spotifyUrl,
    'playlist_id':      playlistId,
    'local_filename':   localFilename,
    'download_status':  downloadStatus,
    'available':        available,
    'is_cached':        isCached,
  };

  Track copyWith({
    String?  id,
    String?  spotifyUri,
    String?  isrc,
    int?     playlistPosition,
    String?  title,
    String?  artist,
    String?  primaryArtist,
    String?  album,
    String?  albumArtist,
    String?  albumArtUrl,
    String?  releaseDate,
    String?  releaseYear,
    List<String>? genres,
    int?     durationMs,
    int?     trackNumber,
    int?     totalTracks,
    int?     discNumber,
    bool?    explicit,
    String?  spotifyUrl,
    String?  playlistId,
    String?  localFilename,
    String?  downloadStatus,
    bool?    available,
    bool?    isCached,
  }) {
    return Track(
      id:               id              ?? this.id,
      spotifyUri:       spotifyUri      ?? this.spotifyUri,
      isrc:             isrc            ?? this.isrc,
      playlistPosition: playlistPosition ?? this.playlistPosition,
      title:            title           ?? this.title,
      artist:           artist          ?? this.artist,
      primaryArtist:    primaryArtist   ?? this.primaryArtist,
      album:            album           ?? this.album,
      albumArtist:      albumArtist     ?? this.albumArtist,
      albumArtUrl:      albumArtUrl     ?? this.albumArtUrl,
      releaseDate:      releaseDate     ?? this.releaseDate,
      releaseYear:      releaseYear     ?? this.releaseYear,
      genres:           genres          ?? this.genres,
      durationMs:       durationMs      ?? this.durationMs,
      trackNumber:      trackNumber     ?? this.trackNumber,
      totalTracks:      totalTracks     ?? this.totalTracks,
      discNumber:       discNumber      ?? this.discNumber,
      explicit:         explicit        ?? this.explicit,
      spotifyUrl:       spotifyUrl      ?? this.spotifyUrl,
      playlistId:       playlistId      ?? this.playlistId,
      localFilename:    localFilename   ?? this.localFilename,
      downloadStatus:   downloadStatus  ?? this.downloadStatus,
      available:        available       ?? this.available,
      isCached:         isCached        ?? this.isCached,
    );
  }
}
