import 'package:flutter_test/flutter_test.dart';
import 'package:la_player/data/models/track.dart';

void main() {
  test('separa artistas do Spotify', () {
    expect(Track.splitArtists('Anitta, J Balvin', 'Anitta'), ['Anitta', 'J Balvin']);
    expect(Track.splitArtists('Anitta', 'Anitta'), ['Anitta']);
    expect(Track.splitArtists('A, B, C', ''), ['A', 'B', 'C']);
  });
  test('mantém o principal inteiro mesmo com vírgula no nome', () {
    expect(Track.splitArtists('Tyler, The Creator, Kali Uchis', 'Tyler, The Creator'), ['Tyler, The Creator', 'Kali Uchis']);
  });
  test('sem artista', () {
    expect(Track.splitArtists('', ''), isEmpty);
  });
}
