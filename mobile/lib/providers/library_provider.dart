import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../core/file_utils.dart';
import '../data/database/database.dart';
import '../data/models/playlist.dart';
import '../data/models/track.dart';
import '../data/services/sync_service.dart';
import '../data/services/spotify_search_service.dart';
import 'player_provider.dart';

// ── Playlists ─────────────────────────────────────────────────────────────

bool _hasRevalidatedOnStartup = false;

final playlistsProvider = FutureProvider<List<Playlist>>((ref) async {
  if (!_hasRevalidatedOnStartup) {
    _hasRevalidatedOnStartup = true;
    // Dispara revalidação silenciosa em background na primeira vez que o app carrega
    Future.microtask(() => ref.read(syncProvider.notifier).revalidateAllTracks());
  }
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
      // 1. Encontra e deleta os arquivos físicos de músicas órfãs 
      // (que pertencem APENAS a esta playlist que está sendo deletada).
      final db = await AppDatabase.instance.db;
      final orphanedTracks = await db.rawQuery('''
        SELECT local_filename FROM tracks 
        WHERE id IN (
          SELECT track_id FROM playlist_tracks WHERE playlist_id = ?
        ) AND id NOT IN (
          SELECT track_id FROM playlist_tracks WHERE playlist_id != ?
        )
      ''', [playlistId, playlistId]);

      final musicDirRoot = await AppConstants.getMusicDirectory();
      for (final row in orphanedTracks) {
        final filename = row['local_filename'] as String?;
        if (filename != null && filename.isNotEmpty) {
           final file = File(p.join(musicDirRoot, filename));
           if (await file.exists()) {
             await file.delete();
           }
        }
      }

      // 2. Apaga no Banco de Dados local (o SQLite cuida de deletar os registros).
      await AppDatabase.instance.deletePlaylist(playlistId);
      ref.invalidate(playlistsProvider);

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

  /// Atualiza nome, descrição, URL da imagem e toggle de sincronização da playlist
  Future<void> updatePlaylistDetails({
    required String playlistId,
    required String name,
    required String description,
    required String imageUrl,
    bool? syncDisabled,
  }) async {
    state = const AsyncValue.loading();
    try {
      final playlists = await ref.read(playlistsProvider.future);
      final playlist = playlists.firstWhere((p) => p.id == playlistId);

      final updated = playlist.copyWith(
        name: name,
        description: description,
        imageUrl: imageUrl,
        syncDisabled: syncDisabled,
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
  (ref, playlistId) async {
    final tracks = await AppDatabase.instance.getTracksForPlaylist(playlistId);
    
    // Varre o diretório raiz de música para revalidar arquivos (detecta se foram deletados manualmente)
    try {
      final musicDirRoot = await AppConstants.getMusicDirectory();
      final filenameToPath = await FileUtils.scanAudioDirectory(musicDirRoot);
      
      final tracksToUpdate = <Track>[];
      final revalidatedTracks = <Track>[];
      bool changed = false;
      
      for (final t in tracks) {
        final matchedPath = FileUtils.findTrackFile(
          filenameToPath,
          localFilename: t.localFilename,
          artist: t.artist,
          title: t.title,
        );
        final physicalExists = matchedPath != null;
        
        if (t.isCached != physicalExists || t.available != physicalExists) {
          final updated = t.copyWith(
            isCached: physicalExists,
            available: physicalExists,
            downloadStatus: physicalExists ? 'success' : 'pending',
          );
          tracksToUpdate.add(updated);
          revalidatedTracks.add(updated);
          changed = true;
        } else {
          revalidatedTracks.add(t);
        }
      }
      
      if (changed && tracksToUpdate.isNotEmpty) {
        AppDatabase.instance.updateTracksCacheStatus(tracksToUpdate).then((_) {
          ref.invalidate(playlistsProvider);
        });
        return revalidatedTracks;
      }
    } catch (e) {
      print('Erro ao revalidar arquivos locais no provider: $e');
    }
    
    return tracks;
  },
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
  final totalPlayTimeMs = await db.getTotalPlayTimeMs(period: period);
  final uniqueTracksCount = await db.getUniqueTracksCount(period: period);
  final totalStreamsCount = await db.getTotalStreamsCount(period: period);
  
  return DashboardData(
    mostPlayed: mostPlayed,
    totalPlayTimeMs: totalPlayTimeMs,
    uniqueTracksCount: uniqueTracksCount,
    totalStreamsCount: totalStreamsCount,
  );
});

// ── Search (Local) ────────────────────────────────────────────────────────

final searchQueryProvider = StateProvider<String>((_) => '');

final searchResultsProvider = FutureProvider<List<Track>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  if (query.trim().isEmpty) return [];
  return AppDatabase.instance.searchTracks(query);
});

// ── Search (Global / Spotify) ─────────────────────────────────────────────

final spotifySearchQueryProvider = StateProvider<String>((_) => '');

final spotifySearchResultsProvider = FutureProvider<List<Track>>((ref) async {
  final query = ref.watch(spotifySearchQueryProvider);
  if (query.trim().isEmpty) return [];
  
  // Debounce simple: wait 500ms before hitting API
  await Future.delayed(const Duration(milliseconds: 500));
  
  // Verifica se a query mudou durante o debounce
  if (ref.read(spotifySearchQueryProvider) != query) return [];
  
  return SpotifySearchService.instance.searchTracks(query);
});
