/// Grupo de artista derivado das tracks — sem tabela própria no banco.
class ArtistGroup {
  final String name;
  final String? coverArtUrl; // capa de uma das músicas do artista
  final int totalTracks;
  final int downloadedTracks;
  final int albumCount;

  const ArtistGroup({
    required this.name,
    this.coverArtUrl,
    required this.totalTracks,
    required this.downloadedTracks,
    required this.albumCount,
  });
}
