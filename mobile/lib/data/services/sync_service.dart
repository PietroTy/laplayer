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
import 'manifest_service.dart';

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

  // Extensões de áudio suportadas (em ordem de preferência)
  static const _audioExtensions = ['m4a', 'opus', 'mp3', 'flac', 'webm', 'ogg'];

  // Verifica se um arquivo existe e tem tamanho mínimo válido (evita arquivos corrompidos)
  static Future<bool> _isValidAudioFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    return file.lengthSync() > 1024; // mínimo de 1 KB
  }

  // Mostra um aviso visível na tela de que o arquivo está corrompido
  void _showCorruptionWarning(Track track) {
    state = SyncState.error('Música corrompida removida: "${track.artist} - ${track.title}". Baixe-a novamente.');
  }

  // Deleta arquivos órfãos (letras, etc.) e reseta o status no banco de dados local
  Future<void> checkAndCleanOrphanedTrack(Track track) async {
    try {
      final musicDirRoot = await AppConstants.getMusicDirectory();
      final musicDir = p.join(musicDirRoot, track.playlistId);
      final sanitize = (String s) => s.replaceAll(RegExp(r'[<>:"/\\|?*]'), '');
      final baseName = '${sanitize(track.artist)} - ${sanitize(track.title)}';

      // 1. Apaga arquivo de letras (.lrc)
      final lrcFile = File(p.join(musicDir, '$baseName.lrc'));
      if (await lrcFile.exists()) {
        try {
          await lrcFile.delete();
        } catch (_) {}
      }

      // 2. Apaga qualquer arquivo físico parcial ou corrompido restante
      if (track.localFilename != null && track.localFilename!.isNotEmpty) {
        final f = File(p.join(musicDir, track.localFilename!));
        if (await f.exists()) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
      for (final ext in _audioExtensions) {
        final candidate = File(p.join(musicDir, '$baseName.$ext'));
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
      );
      await AppDatabase.instance.upsertTracks([updated]);
      
      ref.invalidate(playlistsProvider);
      ref.invalidate(playlistTracksProvider(track.playlistId));
    } catch (_) {}
  }

  // Retorna o caminho absoluto do arquivo se ele existir localmente.
  // Detecta se foi removido manualmente ou se está corrompido (tamanho < 1KB),
  // limpando arquivos órfãos e revalidando o status no banco de dados.
  Future<String?> localPathForTrack(Track track) async {
    final musicDirRoot = await AppConstants.getMusicDirectory();
    final musicDir = p.join(musicDirRoot, track.playlistId);

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
    final sanitize = (String s) => s.replaceAll(RegExp(r'[<>:"/\\|?*]'), '');
    final baseName = '${sanitize(track.artist)} - ${sanitize(track.title)}';
    for (final ext in _audioExtensions) {
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
          if (_audioExtensions.contains(ext) &&
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

  // Retorna um mapa de ID da Track para o caminho absoluto do arquivo se ele existir localmente
  // Executa uma única listagem de diretório física em O(N) para máxima eficiência
  // [overrideMusicDir] permite usar um diretório alternativo (ex: para recuperação de backup)
  Future<Map<String, String>> findLocalPathsBulk(
    String playlistId,
    List<Track> tracks, {
    String? overrideMusicDir,
  }) async {
    final musicDirRoot = overrideMusicDir ?? await AppConstants.getMusicDirectory();
    final musicDir = p.join(musicDirRoot, playlistId);
    final dir = Directory(musicDir);

    final Map<String, String> filenameToPath = {};
    if (await dir.exists()) {
      try {
        final entities = await dir.list().toList();
        for (final entity in entities) {
          if (entity is File) {
            final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
            // Aceita qualquer extensão de áudio suportada (não só .m4a)
            if (_audioExtensions.contains(ext) && entity.lengthSync() > 1024) {
              filenameToPath[p.basename(entity.path).toLowerCase()] = entity.path;
            }
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

      // 2. Fallback: qualquer extensão suportada com o padrão "Artist - Title"
      if (matchedPath == null) {
        final baseName = '${sanitize(track.artist)} - ${sanitize(track.title)}';
        for (final ext in _audioExtensions) {
          final key = '$baseName.$ext'.toLowerCase();
          if (filenameToPath.containsKey(key)) {
            matchedPath = filenameToPath[key];
            break;
          }
        }
      }

      // 3. Último recurso: qualquer arquivo de áudio com o título no nome
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

      final prefs = await SharedPreferences.getInstance();
      final concurrency = prefs.getInt('download_concurrency') ?? 3;
      print('[SyncService] Iniciando download paralelo com concorrência = $concurrency');

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
            'Baixando músicas ($concurrency em paralelo)...',
            '$downloadedCount/$totalPending concluídas ($failedCount falhas)',
          );

          // Atualiza estado do provider
          state = SyncState.loading(
            'Baixando: $downloadedCount/$totalPending concluídas (${track.title})',
            progress: downloadedCount / totalPending,
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
              state = SyncState.loading(
                'Baixando: $downloadedCount/$totalPending concluídas ($failedCount falhas)',
                progress: (downloadedCount + (trackProgress / concurrency)) / totalPending,
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
            ManifestService.instance.scheduleSave();
            
            // Pequeno respiro antes de puxar a próxima música neste worker
            await Future.delayed(const Duration(milliseconds: 800));
          } else {
            failedCount++;
            await AppDatabase.instance.upsertTracks([track.copyWith(
              downloadStatus: 'failed',
            )]);
            ref.invalidate(playlistTracksProvider(playlistId));
          }

          _fgs.updateNotification(
            'Baixando músicas ($concurrency em paralelo)...',
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
