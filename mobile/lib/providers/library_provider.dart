import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../data/database/database.dart';
import '../data/models/playlist.dart';
import '../data/models/track.dart';
import '../data/services/sync_service.dart';
import 'player_provider.dart';

// ── Playlists ─────────────────────────────────────────────────────────────

final playlistsProvider = FutureProvider<List<Playlist>>((ref) async {
  return AppDatabase.instance.getPlaylists();
});

final playlistDetailsProvider = FutureProvider.family<Playlist?, String>((ref, playlistId) async {
  final playlists = await ref.watch(playlistsProvider.future);
  final list = playlists.where((p) => p.id == playlistId).toList();
  return list.isNotEmpty ? list.first : null;
});

class LibraryNotifier extends StateNotifier<AsyncValue<void>> {
  final Ref ref;
  LibraryNotifier(this.ref) : super(const AsyncValue.data(null));

  Future<void> deletePlaylist(String playlistId) async {
    state = const AsyncValue.loading();
    try {
      // 1. Apaga no Banco de Dados local primeiro para sumir da tela na hora
      await AppDatabase.instance.deletePlaylist(playlistId);
      ref.invalidate(playlistsProvider);

      // 2. Apaga arquivos locais (cache)
      final musicDirRoot = await AppConstants.getMusicDirectory();
      final musicDir = Directory(p.join(musicDirRoot, playlistId));
      if (await musicDir.exists()) {
        await musicDir.delete(recursive: true);
      }

      state = const AsyncValue.data(null);
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }

  /// Força a atualização dos metadados (contagem de músicas) pegando do servidor
  Future<void> refreshMetadata(String playlistId) async {
    try {
      await ref.read(syncProvider.notifier).syncMetadata(playlistId);
      ref.invalidate(playlistsProvider);
    } catch (e) {
      print('Erro ao atualizar metadados: $e');
    }
  }

  /// Atualiza nome, descrição e URL da imagem da playlist
  Future<void> updatePlaylistDetails({
    required String playlistId,
    required String name,
    required String description,
    required String imageUrl,
  }) async {
    state = const AsyncValue.loading();
    try {
      final playlists = await ref.read(playlistsProvider.future);
      final playlist = playlists.firstWhere((p) => p.id == playlistId);
      final updated = playlist.copyWith(
        name: name,
        description: description,
        imageUrl: imageUrl,
      );
      await AppDatabase.instance.upsertPlaylist(updated);
      ref.invalidate(playlistsProvider);
      state = const AsyncValue.data(null);
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }
}

final libraryProvider = StateNotifierProvider<LibraryNotifier, AsyncValue<void>>((ref) {
  return LibraryNotifier(ref);
});

final playlistTracksProvider = FutureProvider.family<List<Track>, String>(
  (ref, playlistId) => AppDatabase.instance.getTracksForPlaylist(playlistId),
);

// ── Recentes ──────────────────────────────────────────────────

final recentlyPlayedProvider = FutureProvider<List<Track>>((ref) {
  ref.watch(historyUpdateTriggerProvider);
  return AppDatabase.instance.getRecentlyPlayed(limit: 20);
});

// ── Dashboard de Histórico de Reprodução ───────────────────────────────────

class DashboardData {
  final List<MapEntry<Track, int>> mostPlayed;
  final int totalPlayTimeMs;
  final int uniqueTracksCount;
  final int totalStreamsCount;

  const DashboardData({
    required this.mostPlayed,
    required this.totalPlayTimeMs,
    required this.uniqueTracksCount,
    required this.totalStreamsCount,
  });
}

final mostPlayedPeriodProvider = StateProvider<String>((ref) => 'semana');

final dashboardDataProvider = FutureProvider<DashboardData>((ref) async {
  ref.watch(historyUpdateTriggerProvider);
  final period = ref.watch(mostPlayedPeriodProvider);
  
  final db = AppDatabase.instance;
  final mostPlayed = await db.getMostPlayed(limit: 5, period: period);
  final totalPlayTimeMs = await db.getTotalPlayTimeMs();
  final uniqueTracksCount = await db.getUniqueTracksCount();
  final totalStreamsCount = await db.getTotalStreamsCount();
  
  return DashboardData(
    mostPlayed: mostPlayed,
    totalPlayTimeMs: totalPlayTimeMs,
    uniqueTracksCount: uniqueTracksCount,
    totalStreamsCount: totalStreamsCount,
  );
});

// ── Search ────────────────────────────────────────────────────────────────

final searchQueryProvider = StateProvider<String>((_) => '');

final searchResultsProvider = FutureProvider<List<Track>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  if (query.trim().isEmpty) return [];
  return AppDatabase.instance.searchTracks(query);
});
