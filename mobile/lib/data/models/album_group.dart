/// Grupo de álbum derivado das tracks — sem tabela própria no banco.
class AlbumGroup {
  final String albumName;
  final String albumArtist;
  final String? albumArtUrl;
  final String releaseYear;
  final int totalTracks;
  final int downloadedTracks;
  final List<String> playlistIds;

  const AlbumGroup({
    required this.albumName,
    required this.albumArtist,
    this.albumArtUrl,
    this.releaseYear = '',
    required this.totalTracks,
    required this.downloadedTracks,
    this.playlistIds = const [],
  });

  double get downloadProgress =>
      totalTracks == 0 ? 0 : downloadedTracks / totalTracks;
}
