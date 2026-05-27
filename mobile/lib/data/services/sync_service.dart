import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../database/database.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import 'spotify_service.dart';
import '../../providers/library_provider.dart';
import 'server_downloader.dart';
import 'lyrics_service.dart';
import 'download_foreground_service.dart';

/// Estado detalhado da sincronização
class SyncState {
  final String? message;
  final bool isLoading;
  final String? error;
  final double progress; // 0.0 to 1.0

  const SyncState({this.message, this.isLoading = false, this.error, this.progress = 0.0});

  factory SyncState.idle() => const SyncState();
  factory SyncState.loading(String msg, {double progress = 0.0}) => 
      SyncState(message: msg, isLoading: true, progress: progress);
  factory SyncState.error(String err) => SyncState(error: err);
  factory SyncState.success(String msg) => SyncState(message: msg);
}

final syncProvider = StateNotifierProvider<SyncService, SyncState>((ref) {
  return SyncService(
    SpotifyService(),
    ServerDownloader(),
    ref,
  );
});

final downloadProgressProvider = StateProvider.family<double?, String>((ref, trackId) => null);
final trackSkipMatchesProvider = StateProvider.family<int, String>((ref, trackId) => 0);

class SyncService extends StateNotifier<SyncState> {
  final SpotifyService _spotify;
  final ServerDownloader _serverDownloader;
  final Ref ref;
  bool _cancelRequested = false;

  SyncService(this._spotify, this._serverDownloader, this.ref) : super(SyncState.idle());

  void cancelSync() {
    _cancelRequested = true;
    state = SyncState.idle();
  }

  // Retorna o caminho absoluto do arquivo se ele existir localmente
  Future<String?> localPathForTrack(Track track) async {
    final musicDirRoot = await AppConstants.getMusicDirectory();
    final musicDir = p.join(musicDirRoot, track.playlistId);

    // 1. Caminho exato pelo localFilename (do servidor Python)
    if (track.localFilename != null && track.localFilename!.isNotEmpty) {
      final file = File(p.join(musicDir, track.localFilename));
      if (await file.exists()) return file.path;
    }

    // 2. Fallback: padrão do NativeDownloader ("Artist - Title.m4a")
    final sanitize = (String s) => s.replaceAll(RegExp(r'[<>:"/\\|?*]'), '');
    final nativeName = '${sanitize(track.artist)} - ${sanitize(track.title)}.m4a';
    final nativeFile = File(p.join(musicDir, nativeName));
    if (await nativeFile.exists()) return nativeFile.path;

    // 3. Último recurso: varre a pasta procurando qualquer .m4a com o título
    final dir = Directory(musicDir);
    if (await dir.exists()) {
      final titleLower = track.title.toLowerCase();
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.m4a')) {
          if (p.basename(entity.path).toLowerCase().contains(titleLower)) {
            return entity.path;
          }
        }
      }
    }

    return null;
  }

  // Retorna um mapa de ID da Track para o caminho absoluto do arquivo se ele existir localmente
  // Executa uma única listagem de diretório física em O(N) para máxima eficiência
  Future<Map<String, String>> findLocalPathsBulk(String playlistId, List<Track> tracks) async {
    final musicDirRoot = await AppConstants.getMusicDirectory();
    final musicDir = p.join(musicDirRoot, playlistId);
    final dir = Directory(musicDir);

    final Map<String, String> filenameToPath = {};
    if (await dir.exists()) {
      try {
        final entities = await dir.list().toList();
        for (final entity in entities) {
          if (entity is File && entity.path.toLowerCase().endsWith('.m4a')) {
            filenameToPath[p.basename(entity.path).toLowerCase()] = entity.path;
          }
        }
      } catch (e) {
        print('Erro ao varrer diretório de música: $e');
      }
    }

    final sanitize = (String s) => s.replaceAll(RegExp(r'[<>:"/\\|?*]'), '');
    final Map<String, String> trackIdToLocalPath = {};

    for (final track in tracks) {
      String? matchedPath;

      // 1. Caminho exato pelo localFilename
      if (track.localFilename != null && track.localFilename!.isNotEmpty) {
        final key = track.localFilename!.toLowerCase();
        if (filenameToPath.containsKey(key)) {
          matchedPath = filenameToPath[key];
        }
      }

      // 2. Fallback: padrão do NativeDownloader ("Artist - Title.m4a")
      if (matchedPath == null) {
        final nativeName = '${sanitize(track.artist)} - ${sanitize(track.title)}.m4a';
        final key = nativeName.toLowerCase();
        if (filenameToPath.containsKey(key)) {
          matchedPath = filenameToPath[key];
        }
      }

      // 3. Último recurso: qualquer .m4a com o título no nome
      if (matchedPath == null) {
        final titleLower = track.title.toLowerCase();
        for (final entry in filenameToPath.entries) {
          if (entry.key.contains(titleLower)) {
            matchedPath = entry.value;
            break;
          }
        }
      }

      if (matchedPath != null) {
        trackIdToLocalPath[track.id] = matchedPath;
      }
    }

    return trackIdToLocalPath;
  }

  Future<void> syncAll() async {
    try {
      state = SyncState.loading('Iniciando sincronização global...');
      final playlists = await AppDatabase.instance.getPlaylists();
      for (final pl in playlists) {
        await syncMetadata(pl.id);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_sync', DateTime.now().toIso8601String());
      ref.invalidate(playlistsProvider);
      state = SyncState.success('Sincronização global concluída!');
    } catch (e) {
      state = SyncState.error('Erro no sync global: $e');
    }
  }

  Future<void> syncMetadata(String playlistId) async {
    try {
      state = SyncState.loading('Verificando playlist...', progress: 0.05);

      if (playlistId.contains(' ') || playlistId.length < 15) {
        throw 'ID de Playlist inválido: "$playlistId". Por favor, remova esta playlist e adicione usando o LINK do Spotify.';
      }

      final currentPlaylists = await AppDatabase.instance.getPlaylists();
      final localPlaylist = currentPlaylists.cast<Playlist?>().firstWhere(
        (pl) => pl?.id == playlistId, orElse: () => null
      );
      
      String? remoteSnapshot;
      if (localPlaylist != null) {
        remoteSnapshot = await _spotify.getPlaylistSnapshot(playlistId);
        if (remoteSnapshot != null && localPlaylist.snapshotId == remoteSnapshot) {
          state = SyncState.success('Dados já estão atualizados (Cache)');
          return;
        }
        state = SyncState.loading('Buscando mudanças no Spotify...', progress: 0.15);
      }

      final spotifyIds = <String>{};

      await _spotify.getPlaylistTracks(
        playlistId,
        onProgress: (count) {
          state = SyncState.loading('Sincronizando músicas: $count...', progress: 0.15 + (count / 200).clamp(0.0, 0.35));
        },
        onTracksFetched: (pageTracks) async {
          // Salva em tempo real no banco e atualiza a UI
          await AppDatabase.instance.upsertTracks(pageTracks);
          for (final t in pageTracks) {
            spotifyIds.add(t.id);
          }
          ref.invalidate(playlistTracksProvider(playlistId));
        },
      );

      if (spotifyIds.isEmpty && localPlaylist == null) {
        state = SyncState.error('Nenhuma música encontrada.');
        return;
      }

      state = SyncState.loading('Limpando faixas obsoletas...', progress: 0.60);
      final localTracks = await AppDatabase.instance.getTracksForPlaylist(playlistId);
      final tracksToDelete = <String>[];
      for (final lt in localTracks) {
        if (!spotifyIds.contains(lt.id)) {
          tracksToDelete.add(lt.id);
        }
      }
      if (tracksToDelete.isNotEmpty) {
        await AppDatabase.instance.deleteTracks(tracksToDelete);
        ref.invalidate(playlistTracksProvider(playlistId));
      }
      
      state = SyncState.loading('Finalizando metadados...', progress: 0.75);
      final details = await _spotify.getPlaylistDetails(playlistId);
      final playlistToUpdate = localPlaylist ?? Playlist(id: playlistId, name: 'Playlist');
      final updatedPlaylist = playlistToUpdate.copyWith(
        name:        details?['name']         ?? playlistToUpdate.name,
        description: details?['description']  ?? playlistToUpdate.description,
        imageUrl:    details?['image_url']    ?? playlistToUpdate.imageUrl,
        spotifyUrl:  details?['spotify_url']  ?? playlistToUpdate.spotifyUrl,
        snapshotId:  remoteSnapshot           ?? playlistToUpdate.snapshotId,
        totalTracks: spotifyIds.length,
      );
      await AppDatabase.instance.upsertPlaylist(updatedPlaylist);
      ref.invalidate(playlistsProvider);

      // Cura retroativa dos arquivos locais com varredura em lote extremamente rápida
      state = SyncState.loading('Escaneando arquivos de áudio locais...', progress: 0.85);
      final updatedLocalTracks = await AppDatabase.instance.getTracksForPlaylist(playlistId);
      final localPathsMap = await findLocalPathsBulk(playlistId, updatedLocalTracks);
      final tracksToUpdate = <Track>[];
      for (final t in updatedLocalTracks) {
        final path = localPathsMap[t.id];
        final exists = path != null;
        if (t.isCached != exists || t.available != exists || (exists && t.localFilename == null)) {
          tracksToUpdate.add(t.copyWith(
            isCached: exists,
            available: exists,
            localFilename: exists ? p.basename(path) : t.localFilename,
            downloadStatus: exists ? 'success' : 'pending',
          ));
        }
      }
      if (tracksToUpdate.isNotEmpty) {
        await AppDatabase.instance.upsertTracks(tracksToUpdate);
        ref.invalidate(playlistTracksProvider(playlistId));
      }

      state = SyncState.success('Dados sincronizados com sucesso!');
    } catch (e) {
      state = SyncState.error('$e');
    }
  }

  Future<void> syncAudio(String playlistId) async {
    _cancelRequested = false;
    final _fgs = DownloadForegroundService.instance;

    try {
      state = SyncState.loading('Preparando download...', progress: 0.0);

      // 1. Busca tracks que precisam de download
      final allTracks = await AppDatabase.instance.getTracksForPlaylist(playlistId);
      final pendingTracks = allTracks.where((t) => !t.available).toList();

      if (pendingTracks.isEmpty) {
        state = SyncState.success('Todas as músicas já estão baixadas!');
        return;
      }

      // 2. Inicia o foreground service — impede o Android de matar o processo
      //    quando a tela desligar ou o app ir para o background
      await _fgs.start(
        playlistName: 'Iniciando downloads...',
        onStarted: () {},
      );

      int downloadedCount = 0;
      int failedCount = 0;

      for (final track in pendingTracks) {
        if (_cancelRequested) break;

        // Atualiza notificação com a música atual
        _fgs.updateNotification(
          'Baixando ${downloadedCount + 1}/${pendingTracks.length}',
          track.title,
        );

        // Marca a track como 'downloading'
        await AppDatabase.instance.upsertTracks([track.copyWith(
          downloadStatus: 'downloading',
        )]);
        ref.read(downloadProgressProvider(track.id).notifier).state = 0.0;
        ref.invalidate(playlistTracksProvider(playlistId));

        final currentProgress = downloadedCount / pendingTracks.length;
        state = SyncState.loading(
          'Baixando: ${track.title} ($downloadedCount/${pendingTracks.length})',
          progress: currentProgress,
        );

        final file = await _serverDownloader.downloadTrack(
          title: track.title,
          artist: track.artist,
          album: track.album,
          imageUrl: track.albumArtUrl,
          playlistId: playlistId,
          trackId: track.id,
          onProgress: (msg, trackProgress) {
            ref.read(downloadProgressProvider(track.id).notifier).state = trackProgress;
            final overallProgress = (downloadedCount + trackProgress) / pendingTracks.length;
            state = SyncState.loading(
              '$msg (${track.title})',
              progress: overallProgress,
            );
          },
        );

        ref.read(downloadProgressProvider(track.id).notifier).state = null;

        if (file != null) {
          downloadedCount++;
          await AppDatabase.instance.upsertTracks([track.copyWith(
            available: true,
            isCached: true,
            downloadStatus: 'success',
            localFilename: p.basename(file.path),
          )]);
          ref.invalidate(playlistTracksProvider(playlistId));
          ref.invalidate(playlistsProvider);

          LyricsService.instance.prefetchAndSave(track);
          await Future.delayed(const Duration(seconds: 2));
        } else {
          failedCount++;
          await AppDatabase.instance.upsertTracks([track.copyWith(
            downloadStatus: 'failed',
          )]);
          ref.invalidate(playlistTracksProvider(playlistId));
        }
      }

      // 3. Para o foreground service ao concluir
      await _fgs.stop();

      if (_cancelRequested) {
        state = SyncState.success('Download cancelado pelo usuário.');
      } else {
        state = SyncState.success('Concluído! $downloadedCount baixadas, $failedCount falhas.');
      }

      ref.invalidate(playlistsProvider);
    } catch (e) {
      await _fgs.stop();
      state = SyncState.error('Erro no download: $e');
    }
  }
  Future<void> addNewPlaylist(String input) async {
    try {
      state = SyncState.loading('Processando link...');
      
      final playlistId = input.contains('spotify.com') 
          ? input.split('playlist/')[1].split('?')[0] 
          : input.trim();

      if (playlistId.contains(' ') || playlistId.length < 15) {
        state = SyncState.error('ID de Playlist inválido. Use o link do Spotify.');
        return;
      }

      final details = await _spotify.getPlaylistDetails(playlistId);
      if (details == null) {
        state = SyncState.error('Playlist não encontrada no Spotify.');
        return;
      }
      final playlist = Playlist(
        id: playlistId,
        name: details['name'],
        description: details['description'],
        imageUrl: details['image_url'],
        spotifyUrl: details['spotify_url'],
        totalTracks: details['total_tracks'],
      );
      await AppDatabase.instance.upsertPlaylist(playlist);
      await syncMetadata(playlistId);
      state = SyncState.success('Playlist adicionada com sucesso!');
    } catch (e) {
      state = SyncState.error('$e');
    }
  }

  Future<void> retryTrackDownload(Track track) async {
    try {
      state = SyncState.loading('Tentando baixar: ${track.title}...');
      
      // Marca a track como 'downloading'
      await AppDatabase.instance.upsertTracks([track.copyWith(
        downloadStatus: 'downloading',
      )]);
      ref.read(downloadProgressProvider(track.id).notifier).state = 0.0;
      ref.invalidate(playlistTracksProvider(track.playlistId));

      final file = await _serverDownloader.downloadTrack(
        title: track.title,
        artist: track.artist,
        album: track.album,
        imageUrl: track.albumArtUrl,
        playlistId: track.playlistId,
        trackId: track.id,
        durationMs: track.durationMs,
        onProgress: (msg, trackProgress) {
          ref.read(downloadProgressProvider(track.id).notifier).state = trackProgress;
          state = SyncState.loading(msg);
        },
      );

      ref.read(downloadProgressProvider(track.id).notifier).state = null;

      if (file != null) {
        await AppDatabase.instance.upsertTracks([track.copyWith(
          available: true,
          isCached: true,
          downloadStatus: 'success',
          localFilename: p.basename(file.path),
        )]);
        ref.invalidate(playlistTracksProvider(track.playlistId));
        ref.invalidate(playlistsProvider);
        state = SyncState.success('Música baixada com sucesso!');
      } else {
        await AppDatabase.instance.upsertTracks([track.copyWith(
          downloadStatus: 'failed',
        )]);
        ref.invalidate(playlistTracksProvider(track.playlistId));
        state = SyncState.error('Não foi possível encontrar a música no YouTube.');
      }
    } catch (e) {
      ref.read(downloadProgressProvider(track.id).notifier).state = null;
      await AppDatabase.instance.upsertTracks([track.copyWith(
        downloadStatus: 'failed',
      )]);
      ref.invalidate(playlistTracksProvider(track.playlistId));
      state = SyncState.error('Falha no download nativo: $e');
    }
  }

  /// Baixa uma versão alternativa da música, pulando os N primeiros resultados.
  /// Funciona 100% no celular, sem precisar do servidor Python.
  Future<bool> redownloadAlternative(Track track, {int skipMatch = 1}) async {
    try {
      state = SyncState.loading('Buscando versão alternativa de "${track.title}"...');

      // Marca a track como 'downloading'
      await AppDatabase.instance.upsertTracks([track.copyWith(
        downloadStatus: 'downloading',
      )]);
      ref.read(downloadProgressProvider(track.id).notifier).state = 0.0;
      ref.invalidate(playlistTracksProvider(track.playlistId));

      final file = await _serverDownloader.downloadTrack(
        title: track.title,
        artist: track.artist,
        album: track.album,
        imageUrl: track.albumArtUrl,
        playlistId: track.playlistId,
        trackId: track.id,
        durationMs: track.durationMs,
        skipMatch: skipMatch,
        onProgress: (msg, trackProgress) {
          ref.read(downloadProgressProvider(track.id).notifier).state = trackProgress;
          state = SyncState.loading(msg);
        },
      );

      ref.read(downloadProgressProvider(track.id).notifier).state = null;

      if (file != null) {
        await AppDatabase.instance.upsertTracks([track.copyWith(
          available: true,
          isCached: true,
          downloadStatus: 'success',
          localFilename: p.basename(file.path),
        )]);
        ref.invalidate(playlistTracksProvider(track.playlistId));
        ref.invalidate(playlistsProvider);
        state = SyncState.success('Versão alternativa baixada!');
        return true;
      } else {
        await AppDatabase.instance.upsertTracks([track.copyWith(
          downloadStatus: 'failed',
        )]);
        ref.invalidate(playlistTracksProvider(track.playlistId));
        state = SyncState.error('Nenhuma versão alternativa encontrada.');
        return false;
      }
    } catch (e) {
      ref.read(downloadProgressProvider(track.id).notifier).state = null;
      await AppDatabase.instance.upsertTracks([track.copyWith(
        downloadStatus: 'failed',
      )]);
      ref.invalidate(playlistTracksProvider(track.playlistId));
      state = SyncState.error('Erro: $e');
      return false;
    }
  }

  /// Baixa uma versão alternativa específica da música usando a URL selecionada.
  Future<bool> redownloadSpecificAlternative(Track track, String youtubeUrl) async {
    try {
      state = SyncState.loading('Baixando versão alternativa selecionada...');

      // Marca a track como 'downloading'
      await AppDatabase.instance.upsertTracks([track.copyWith(
        downloadStatus: 'downloading',
      )]);
      ref.read(downloadProgressProvider(track.id).notifier).state = 0.0;
      ref.invalidate(playlistTracksProvider(track.playlistId));

      final file = await _serverDownloader.downloadTrack(
        title: track.title,
        artist: track.artist,
        album: track.album,
        imageUrl: track.albumArtUrl,
        playlistId: track.playlistId,
        trackId: track.id,
        durationMs: track.durationMs,
        youtubeUrl: youtubeUrl,
        onProgress: (msg, trackProgress) {
          ref.read(downloadProgressProvider(track.id).notifier).state = trackProgress;
          state = SyncState.loading(msg);
        },
      );

      ref.read(downloadProgressProvider(track.id).notifier).state = null;

      if (file != null) {
        await AppDatabase.instance.upsertTracks([track.copyWith(
          available: true,
          isCached: true,
          downloadStatus: 'success',
          localFilename: p.basename(file.path),
        )]);
        ref.invalidate(playlistTracksProvider(track.playlistId));
        ref.invalidate(playlistsProvider);
        state = SyncState.success('Versão alternativa baixada com sucesso!');
        return true;
      } else {
        await AppDatabase.instance.upsertTracks([track.copyWith(
          downloadStatus: 'failed',
        )]);
        ref.invalidate(playlistTracksProvider(track.playlistId));
        state = SyncState.error('Não foi possível baixar esta versão.');
        return false;
      }
    } catch (e) {
      ref.read(downloadProgressProvider(track.id).notifier).state = null;
      await AppDatabase.instance.upsertTracks([track.copyWith(
        downloadStatus: 'failed',
      )]);
      ref.invalidate(playlistTracksProvider(track.playlistId));
      state = SyncState.error('Erro: $e');
      return false;
    }
  }

  /// Revalida todas as faixas do banco comparando com o diretório físico atual.
  Future<void> revalidateAllTracks() async {
    try {
      final playlists = await AppDatabase.instance.getPlaylists();
      for (final pl in playlists) {
        final tracks = await AppDatabase.instance.getTracksForPlaylist(pl.id);
        final localPathsMap = await findLocalPathsBulk(pl.id, tracks);
        final tracksToUpdate = <Track>[];
        for (final t in tracks) {
          final path = localPathsMap[t.id];
          final exists = path != null;
          if (t.isCached != exists || t.available != exists || (exists && t.localFilename == null)) {
            tracksToUpdate.add(t.copyWith(
              isCached: exists,
              available: exists,
              localFilename: exists ? p.basename(path) : t.localFilename,
              downloadStatus: exists ? 'success' : 'pending',
            ));
          }
        }
        if (tracksToUpdate.isNotEmpty) {
          await AppDatabase.instance.upsertTracks(tracksToUpdate);
        }
      }
      ref.invalidate(playlistsProvider);
    } catch (e) {
      print('Erro ao revalidar faixas: $e');
    }
  }
}
