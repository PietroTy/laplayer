import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/file_utils.dart';
import '../database/database.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import 'spotify_service.dart';
import '../../providers/library_provider.dart';
import 'standalone_downloader.dart';
import 'lyrics_service.dart';
import 'download_foreground_service.dart';
import 'manifest_service.dart';
import 'native_downloader_service.dart';

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
    StandaloneDownloader(),
    ref,
  );
});

final downloadProgressProvider = StateProvider.family<double?, String>((ref, trackId) => null);
final trackSkipMatchesProvider = StateProvider.family<int, String>((ref, trackId) => 0);

class SyncService extends StateNotifier<SyncState> {
  final SpotifyService _spotify;
  final StandaloneDownloader _standaloneDownloader;
  final Ref ref;
  bool _cancelRequested = false;

  SyncService(this._spotify, this._standaloneDownloader, this.ref) : super(SyncState.idle());

  void cancelSync() {
    _cancelRequested = true;
    state = SyncState.idle();
  }

  // Verifica se um arquivo existe e tem tamanho mínimo válido (evita arquivos corrompidos)
  static Future<bool> _isValidAudioFile(String path) => FileUtils.isValidAudioFile(path);

  // Mostra um aviso visível na tela de que o arquivo está corrompido
  void _showCorruptionWarning(Track track) {
    state = SyncState.error('Música corrompida removida: "${track.artist} - ${track.title}". Baixe-a novamente.');
  }

  // Deleta arquivos órfãos (letras, áudio, etc.) e reseta o status no banco de dados local
  Future<void> checkAndCleanOrphanedTrack(Track track) async {
    try {
      final musicDirRoot = await AppConstants.getMusicDirectory();

      // 1. Busca e apaga o arquivo físico mapeado no diretório
      final filenameToPath = await FileUtils.scanAudioDirectory(musicDirRoot);
      final matchedPath = FileUtils.findTrackFile(
        filenameToPath,
        localFilename: track.localFilename,
        artist: track.artist,
        title: track.title,
      );

      if (matchedPath != null) {
        final f = File(matchedPath);
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }

      // 2. Apaga arquivo de letras (.lrc) e fallbacks pelo nome sanitizado
      final baseName = '${FileUtils.sanitizeFilename(track.artist)} - ${FileUtils.sanitizeFilename(track.title)}';
      final lrcFile = File(p.join(musicDirRoot, '$baseName.lrc'));
      if (await lrcFile.exists()) {
        try {
          await lrcFile.delete();
        } catch (_) {}
      }

      if (track.localFilename != null && track.localFilename!.isNotEmpty) {
        final f = File(p.join(musicDirRoot, track.localFilename!));
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      for (final ext in FileUtils.audioExtensions) {
        final candidate = File(p.join(musicDirRoot, '$baseName.$ext'));
        if (await candidate.exists()) {
          try {
            await candidate.delete();
          } catch (_) {}
        }
      }

      // 3. Atualiza banco para refletir não instalado
      final updated = track.copyWith(
        isCached: false,
        available: false,
        downloadStatus: 'pending',
        localFilename: null,
      );
      await AppDatabase.instance.updateTracksCacheStatus([updated]);
      
      ref.invalidate(playlistsProvider);
      ref.invalidate(playlistTracksProvider(track.playlistId));
    } catch (_) {}
  }

  // Retorna o caminho absoluto do arquivo se ele existir localmente.
  // Detecta se foi removido manualmente ou se está corrompido (tamanho < 1KB),
  // limpando arquivos órfãos e revalidando o status no banco de dados.
  Future<String?> localPathForTrack(Track track) async {
    final musicDirRoot = await AppConstants.getMusicDirectory();
    final musicDir = musicDirRoot; // Agora tudo fica na raiz

    // 1. Caminho exato pelo localFilename (do servidor Python)
    if (track.localFilename != null && track.localFilename!.isNotEmpty) {
      final file = File(p.join(musicDir, track.localFilename!));
      final exists = await file.exists();
      if (exists) {
        if (await _isValidAudioFile(file.path)) {
          return file.path;
        } else {
          // Arquivo corrompido! Deleta e limpa
          print('ARQUIVO CORROMPIDO DETECTADO: ${file.path}');
          _showCorruptionWarning(track);
          await checkAndCleanOrphanedTrack(track);
          return null;
        }
      }
    }

    // 2. Fallback: padrão do NativeDownloader com qualquer extensão suportada
    final baseName = '${FileUtils.sanitizeFilename(track.artist)} - ${FileUtils.sanitizeFilename(track.title)}';
    for (final ext in FileUtils.audioExtensions) {
      final candidate = File(p.join(musicDir, '$baseName.$ext'));
      final exists = await candidate.exists();
      if (exists) {
        if (await _isValidAudioFile(candidate.path)) {
          return candidate.path;
        } else {
          // Arquivo corrompido! Deleta e limpa
          print('ARQUIVO CORROMPIDO DETECTADO: ${candidate.path}');
          _showCorruptionWarning(track);
          await checkAndCleanOrphanedTrack(track);
          return null;
        }
      }
    }

    // 3. Último recurso: varre a pasta procurando qualquer áudio com o título
    final dir = Directory(musicDir);
    if (await dir.exists()) {
      final titleLower = track.title.toLowerCase();
      await for (final entity in dir.list()) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
          if (FileUtils.audioExtensions.contains(ext) &&
              p.basename(entity.path).toLowerCase().contains(titleLower)) {
            if (await _isValidAudioFile(entity.path)) {
              return entity.path;
            } else {
              // Arquivo corrompido! Deleta e limpa
              print('ARQUIVO CORROMPIDO DETECTADO: ${entity.path}');
              _showCorruptionWarning(track);
              await checkAndCleanOrphanedTrack(track);
              return null;
            }
          }
        }
      }
    }

    // Se o banco dizia que estava baixado, mas não achamos nenhum arquivo, então foi removido manualmente!
    if (track.isCached || track.available || track.downloadStatus == 'success') {
      print('ARQUIVO REMOVIDO MANUALMENTE DETECTADO para a música: ${track.title}');
      await checkAndCleanOrphanedTrack(track);
    }

    return null;
  }

  Future<Map<String, String>> findLocalPathsBulk(
    List<Track> tracks, {
    String? overrideMusicDir,
  }) async {
    final musicDirRoot = overrideMusicDir ?? await AppConstants.getMusicDirectory();
    final filenameToPath = await FileUtils.scanAudioDirectory(musicDirRoot);
    final Map<String, String> trackIdToLocalPath = {};

    for (final track in tracks) {
      final matchedPath = FileUtils.findTrackFile(
        filenameToPath,
        localFilename: track.localFilename,
        artist: track.artist,
        title: track.title,
      );
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

      final parsedId = SpotifyService.parsePlaylistId(playlistId) ?? playlistId.trim().replaceAll('/', '');
      if (parsedId.contains(' ') || parsedId.length < 15) {
        throw 'ID de Playlist inválido: "$playlistId". Por favor, remova esta playlist e adicione usando o LINK do Spotify.';
      }

      final currentPlaylists = await AppDatabase.instance.getPlaylists();
      final localPlaylist = currentPlaylists.cast<Playlist?>().firstWhere(
        (pl) => pl?.id == playlistId, orElse: () => null
      );
      
      if (localPlaylist != null && localPlaylist.syncDisabled) {
        state = SyncState.success('Sincronização desabilitada para esta playlist.');
        return;
      }
      
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
        name: details?['name'] != null && details!['name'].toString().isNotEmpty && details['name'] != 'Playlist'
            ? details['name']
            : playlistToUpdate.name,
        description: details?['description'] ?? playlistToUpdate.description,
        imageUrl: details?['image_url'] != null && details!['image_url'].toString().isNotEmpty
            ? details['image_url']
            : playlistToUpdate.imageUrl,
        spotifyUrl: details?['spotify_url'] ?? playlistToUpdate.spotifyUrl,
        totalTracks: spotifyIds.isNotEmpty ? spotifyIds.length : (details?['total_tracks'] ?? playlistToUpdate.totalTracks),
        snapshotId: remoteSnapshot ?? playlistToUpdate.snapshotId,
      );
      await AppDatabase.instance.upsertPlaylist(updatedPlaylist);
      ref.invalidate(playlistsProvider);

      // Cura retroativa dos arquivos locais com varredura em lote extremamente rápida
      state = SyncState.loading('Escaneando arquivos de áudio locais...', progress: 0.85);
      final updatedLocalTracks = await AppDatabase.instance.getTracksForPlaylist(playlistId);
      final localPathsMap = await findLocalPathsBulk(updatedLocalTracks);
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
      ManifestService.instance.scheduleSave(); // Auto-salva manifesto após sync
    } catch (e) {
      state = SyncState.error('$e');
    }
  }

  Future<void> syncAudio(String playlistId) async {
    _cancelRequested = false;
    final _fgs = DownloadForegroundService.instance;

    try {
      state = SyncState.loading('Preparando download...', progress: 0.0);

      // Reseta qualquer estado 'downloading' anterior que possa ter ficado travado
      await AppDatabase.instance.resetDownloadingStatus();
      ref.invalidate(playlistTracksProvider(playlistId));

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
      final totalPending = pendingTracks.length;

      final concurrency = 1;
      print('[SyncService] Iniciando download sequencial (1 por 1)');

      int nextIndex = 0;

      Future<void> runWorker() async {
        while (nextIndex < totalPending) {
          if (_cancelRequested) break;
          
          final currentIndex = nextIndex++;
          if (currentIndex >= totalPending) break;

          final track = pendingTracks[currentIndex];

          // Marca a track como 'downloading'
          await AppDatabase.instance.upsertTracks([track.copyWith(
            downloadStatus: 'downloading',
          )]);
          ref.read(downloadProgressProvider(track.id).notifier).state = 0.0;
          ref.invalidate(playlistTracksProvider(playlistId));

          // Atualiza notificação
          _fgs.updateNotification(
            'Baixando músicas...',
            '$downloadedCount/$totalPending concluídas ($failedCount falhas)',
          );

          // Atualiza estado do provider
          state = SyncState.loading(
            'Baixando: $downloadedCount/$totalPending concluídas (${track.title})',
            progress: downloadedCount / totalPending,
          );

          try {
            final file = await _standaloneDownloader.downloadTrack(
              title: track.title,
              artist: track.artist,
              album: track.album,
              imageUrl: track.albumArtUrl,
              playlistId: playlistId,
              trackId: track.id,
              durationMs: track.durationMs,
              year: track.releaseYear,
              trackNumber: track.trackNumber,
              onProgress: (msg, trackProgress) {
                ref.read(downloadProgressProvider(track.id).notifier).state = trackProgress;
                state = SyncState.loading(
                  'Baixando: $downloadedCount/$totalPending concluídas ($failedCount falhas)',
                  progress: (downloadedCount + trackProgress) / totalPending,
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
            } else {
              failedCount++;
              await AppDatabase.instance.upsertTracks([track.copyWith(
                downloadStatus: 'failed',
              )]);
              ref.invalidate(playlistTracksProvider(playlistId));
            }
          } catch (e) {
            print('[SyncService] Worker falhou na track ${track.title}: $e. Tentando auto-recover com reset de sessão...');
            
            // Auto-recover pass embutido no worker: reseta sessão e tenta mais uma vez
            bool recovered = false;
            try {
              await _standaloneDownloader.closeSession();
              await Future.delayed(const Duration(milliseconds: 500));
              
              final retryFile = await _standaloneDownloader.downloadTrack(
                title: track.title,
                artist: track.artist,
                album: track.album,
                imageUrl: track.albumArtUrl,
                playlistId: playlistId,
                trackId: track.id,
                durationMs: track.durationMs,
                year: track.releaseYear,
                trackNumber: track.trackNumber,
                onProgress: (msg, trackProgress) {
                  ref.read(downloadProgressProvider(track.id).notifier).state = trackProgress;
                },
              );

              if (retryFile != null) {
                downloadedCount++;
                await AppDatabase.instance.upsertTracks([track.copyWith(
                  available: true,
                  isCached: true,
                  downloadStatus: 'success',
                  localFilename: p.basename(retryFile.path),
                )]);
                ref.invalidate(playlistTracksProvider(playlistId));
                ref.read(downloadProgressProvider(track.id).notifier).state = null;
                recovered = true;
              }
            } catch (retryE) {
              print('[SyncService] Auto-recover também falhou na track ${track.title}: $retryE');
            }

            if (!recovered) {
              ref.read(downloadProgressProvider(track.id).notifier).state = null;
              failedCount++;
              await AppDatabase.instance.upsertTracks([track.copyWith(
                downloadStatus: 'failed',
              )]);
              ref.invalidate(playlistTracksProvider(playlistId));
            }
          }

          _fgs.updateNotification(
            'Baixando músicas...',
            '$downloadedCount/$totalPending concluídas ($failedCount falhas)',
          );
          state = SyncState.loading(
            'Baixando: $downloadedCount/$totalPending concluídas ($failedCount falhas)',
            progress: downloadedCount / totalPending,
          );
        }
      }

      final workers = List.generate(concurrency, (_) => runWorker());
      await Future.wait(workers);

      // Salva o manifest final apenas 1 vez ao encerrar o lote
      ManifestService.instance.scheduleSave();

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
    } finally {
      // Encerra a sessão do librespot no final, independentemente de sucesso ou erro
      await _standaloneDownloader.closeSession();
    }
  }
  Future<void> addNewPlaylist(String input) async {
    try {
      state = SyncState.loading('Processando link do Spotify...');
      
      var playlistId = SpotifyService.parsePlaylistId(input);
      playlistId ??= await SpotifyService.extractPlaylistIdAsync(input);

      if (playlistId == null || playlistId.isEmpty) {
        state = SyncState.error('Link ou ID de playlist inválido. Certifique-se de colar um link válido do Spotify.');
        return;
      }

      final details = await _spotify.getPlaylistDetails(playlistId);
      if (details == null) {
        state = SyncState.error('Playlist não encontrada ou privada no Spotify.');
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
      state = SyncState.loading('Baixando: ${track.artist} - ${track.title}...');
      
      // Marca a track como 'downloading'
      await AppDatabase.instance.upsertTracks([track.copyWith(
        downloadStatus: 'downloading',
      )]);
      ref.read(downloadProgressProvider(track.id).notifier).state = 0.0;
      if (track.playlistId.isNotEmpty) {
        ref.invalidate(playlistTracksProvider(track.playlistId));
      }
      ref.invalidate(playlistsProvider);

      final file = await _standaloneDownloader.downloadTrack(
        title: track.title,
        artist: track.artist,
        album: track.album,
        imageUrl: track.albumArtUrl,
        playlistId: track.playlistId,
        trackId: track.id,
        durationMs: track.durationMs,
        year: track.releaseYear,
        trackNumber: track.trackNumber,
        onProgress: (msg, trackProgress) {
          ref.read(downloadProgressProvider(track.id).notifier).state = trackProgress;
          state = SyncState.loading(msg);
        },
      );

      ref.read(downloadProgressProvider(track.id).notifier).state = null;

      if (file != null && file.existsSync()) {
        await AppDatabase.instance.upsertTracks([track.copyWith(
          available: true,
          isCached: true,
          downloadStatus: 'success',
          localFilename: p.basename(file.path),
        )]);
        if (track.playlistId.isNotEmpty) {
          ref.invalidate(playlistTracksProvider(track.playlistId));
        }
        ref.invalidate(playlistsProvider);
        ManifestService.instance.scheduleSave();
        state = SyncState.success('Música baixada com sucesso!');
      } else {
        await AppDatabase.instance.upsertTracks([track.copyWith(
          downloadStatus: 'failed',
        )]);
        if (track.playlistId.isNotEmpty) {
          ref.invalidate(playlistTracksProvider(track.playlistId));
        }
        ref.invalidate(playlistsProvider);
        state = SyncState.error('Não foi possível baixar esta música.');
      }
    } catch (e) {
      ref.read(downloadProgressProvider(track.id).notifier).state = null;
      await AppDatabase.instance.upsertTracks([track.copyWith(
        downloadStatus: 'failed',
      )]);
      if (track.playlistId.isNotEmpty) {
        ref.invalidate(playlistTracksProvider(track.playlistId));
      }
      ref.invalidate(playlistsProvider);
      state = SyncState.error('Falha no download: $e');
    } finally {
      await _standaloneDownloader.closeSession();
    }
  }


  /// Revalida todas as faixas do banco comparando com o diretório físico atual.
  Future<void> revalidateAllTracks() async {
    try {
      final playlists = await AppDatabase.instance.getPlaylists();
      for (final pl in playlists) {
        final tracks = await AppDatabase.instance.getTracksForPlaylist(pl.id);
        final localPathsMap = await findLocalPathsBulk(tracks);
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
          await AppDatabase.instance.updateTracksCacheStatus(tracksToUpdate);
        }
      }
      ref.invalidate(playlistsProvider);
    } catch (e) {
      print('Erro ao revalidar faixas: $e');
    }
  }
}
