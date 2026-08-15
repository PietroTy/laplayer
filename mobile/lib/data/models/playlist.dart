/// Modelo de uma playlist sincronizada do Spotify
class Playlist {
  final String id;
  final String name;
  final String description;
  final String imageUrl;
  final String spotifyUrl;
  final int    totalTracks;
  final int    downloaded;
  final int    failed;
  final String path;
  final String snapshotId;
  final bool syncDisabled;

  const Playlist({
    required this.id,
    required this.name,
    this.description = '',
    this.imageUrl    = '',
    this.spotifyUrl   = '',
    this.totalTracks = 0,
    this.downloaded  = 0,
    this.failed      = 0,
    this.path        = '',
    this.snapshotId  = '',
    this.syncDisabled = false,
  });

  int get pending => totalTracks - downloaded - failed;

  double get progress =>
      totalTracks == 0 ? 0.0 : downloaded / totalTracks;

  bool get isComplete => downloaded == totalTracks && totalTracks > 0;

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id:          json['id']           ?? '',
      name:        json['name']         ?? '',
      description: json['description']  ?? '',
      imageUrl:    json['image_url']    ?? '',
      spotifyUrl:  json['spotify_url']  ?? '',
      totalTracks: json['total_tracks'] ?? 0,
      downloaded:  json['downloaded']   ?? 0,
      failed:      json['failed']       ?? 0,
      path:        json['path']         ?? '',
      snapshotId:  json['snapshot_id']  ?? '',
      syncDisabled: json['sync_disabled'] == 1 || json['sync_disabled'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id':           id,
    'name':         name,
    'description':  description,
    'image_url':    imageUrl,
    'spotify_url':  spotifyUrl,
    'total_tracks': totalTracks,
    'downloaded':   downloaded,
    'failed':       failed,
    'path':         path,
    'snapshot_id':  snapshotId,
    'sync_disabled': syncDisabled ? 1 : 0,
  };

  Playlist copyWith({
    String? id,
    String? name,
    String? description,
    String? imageUrl,
    String? spotifyUrl,
    int?    totalTracks,
    int? downloaded,
    int? failed,
    String? path,
    String? snapshotId,
    bool? syncDisabled,
  }) {
    return Playlist(
      id:          id          ?? this.id,
      name:        name        ?? this.name,
      description: description ?? this.description,
      imageUrl:    imageUrl    ?? this.imageUrl,
      spotifyUrl:  spotifyUrl  ?? this.spotifyUrl,
      totalTracks: totalTracks ?? this.totalTracks,
      downloaded:  downloaded  ?? this.downloaded,
      failed:      failed      ?? this.failed,
      path:        path        ?? this.path,
      snapshotId:  snapshotId  ?? this.snapshotId,
      syncDisabled: syncDisabled ?? this.syncDisabled,
    );
  }
}
