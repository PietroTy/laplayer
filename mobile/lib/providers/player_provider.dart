import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'library_provider.dart';
import '../data/database/database.dart';
import '../data/models/player_state.dart' as app;
import '../data/models/track.dart';
import '../data/services/audio_handler.dart';
import '../data/services/sync_service.dart';

// Provedor para sinalizar quando o histórico foi atualizado (ex: fim de faixa)
final historyUpdateTriggerProvider = StateProvider<int>((ref) => 0);

// ── Provider do AudioHandler ──────────────────────────────────────────────

final audioHandlerProvider = Provider<AudioHandler>((_) => throw UnimplementedError());

LaPlayerAudioHandler _handler(Ref ref) =>
    ref.read(audioHandlerProvider) as LaPlayerAudioHandler;

// ── Player StateNotifier ──────────────────────────────────────────────────

class PlayerNotifier extends StateNotifier<app.PlayerState> {
  final Ref _ref;
  List<Track> _originalQueue = [];
  bool _currentTrackLogged = false;
  bool _isRestarting = false;
  int _userQueueCount = 0;
  FlutterTts? _tts;
  Timer? _saveTimer;

  PlayerNotifier(this._ref) : super(const app.PlayerState()) {
    _listenToHandler();
    restoreSavedState();
  }

  LaPlayerAudioHandler get _audio => _handler(_ref);

  void _persistState() {
    final currentTrack = state.currentTrack;
    if (currentTrack != null && state.queue.isNotEmpty) {
      AppDatabase.instance.savePlayerState(
        trackId: currentTrack.id,
        positionMs: state.position.inMilliseconds,
        queueTrackIds: state.queue.map((t) => t.id).toList(),
      );
    }
  }

  void _persistStateThrottled() {
    if (_saveTimer?.isActive ?? false) return;
    _saveTimer = Timer(const Duration(seconds: 5), () {
      _persistState();
    });
  }

  void _listenToHandler() {
    // Posição e duração com lógica de histórico ao atingir o final da faixa
    _audio.positionStream.listen((pos) {
      state = state.copyWith(position: pos);
      _persistStateThrottled();

      final currentTrack = state.currentTrack;
      final dur = state.duration;
      if (currentTrack != null && dur.inMilliseconds > 0) {
        final thresholdMs = dur.inMilliseconds - 4000;
        final targetMs = thresholdMs.clamp(0, dur.inMilliseconds);

        if (!_currentTrackLogged && pos.inMilliseconds >= targetMs) {
          _currentTrackLogged = true;
          AppDatabase.instance.addToHistory(currentTrack.id);
          _ref.read(historyUpdateTriggerProvider.notifier).state++;
        } else if (_currentTrackLogged && pos.inMilliseconds < 2000) {
          _currentTrackLogged = false;
        }
      }
    });
    _audio.durationStream.listen((dur) {
      if (dur != null) state = state.copyWith(duration: dur);
    });

    // Estado de reprodução completo sincronizado (carregando/tocando/pausado)
    _audio.playbackState.listen((pbState) {
      final isPlaying = pbState.playing;
      final procState = pbState.processingState;

      app.PlayerStatus status;
      if (procState == AudioProcessingState.loading ||
          procState == AudioProcessingState.buffering) {
        status = app.PlayerStatus.loading;
      } else if (isPlaying && procState != AudioProcessingState.completed) {
        status = app.PlayerStatus.playing;
      } else {
        status = app.PlayerStatus.paused;
      }

      state = state.copyWith(status: status);
      _persistState();

      // Intercepta quando a playlist acaba (ocorre apenas se RepeatMode for Off)
      if (procState == AudioProcessingState.completed && !_isRestarting) {
        _isRestarting = true;
        print('[PlayerNotifier] Fila concluída naturalmente. Reiniciando...');
        if (state.shuffleMode != app.ShuffleMode.off) {
          _reShuffle().then((_) {
            play();
            _isRestarting = false;
          });
        } else {
          _audio.skipToQueueItem(0).then((_) {
            play();
            _isRestarting = false;
          });
        }
      }
    });

    // Sincronização de índice via stream do player nativo.
    _audio.currentIndexStream.listen((index) async {
      if (index != null &&
          index < state.queue.length &&
          index != state.currentIndex) {
            
        // Detecta se a playlist deu a volta (LoopMode.all)
        final isLoopingBack = state.currentIndex == state.queue.length - 1 && index == 0;
            
        if (index > state.currentIndex) {
          final diff = index - state.currentIndex;
          _userQueueCount = max(0, _userQueueCount - diff);
        } else if (index < state.currentIndex && !isLoopingBack) {
          _userQueueCount = 0;
        }

        state = state.copyWith(currentIndex: index);
        _currentTrackLogged = false; // Reseta flag para a nova faixa
        _persistState();
        
        // Se deu a volta e está no modo aleatório, dá um "reroll" na fila inteira!
        if (isLoopingBack && state.shuffleMode != app.ShuffleMode.off && state.repeat == app.RepeatMode.all) {
          print('[PlayerNotifier] Fila concluída! Dando reroll no modo aleatório...');
          await _reShuffle();
        }
      }
    });

    _audio.errorStream.listen((err) async {
      state = state.copyWith(
        status: app.PlayerStatus.error,
        errorMessage: err,
      );

      final currentTrack = state.currentTrack;
      if (currentTrack != null) {
        print('[PlayerNotifier] Tratando faixa corrompida: ${currentTrack.title}');
        
        // 1. Tenta apagar o arquivo físico local
        try {
          final sync = _ref.read(syncProvider.notifier);
          final path = await sync.localPathForTrack(currentTrack);
          if (path != null) {
            final file = File(path);
            if (await file.exists()) {
              await file.delete();
              print('[PlayerNotifier] Arquivo corrompido excluído: $path');
            }
          }
        } catch (e) {
          print('[PlayerNotifier] Erro ao deletar arquivo físico corrompido: $e');
        }

        // 2. Marca a faixa como corrompida/pendente no banco de dados SQLite
        try {
          await AppDatabase.instance.markTrackCorrupted(currentTrack.id);
          print('[PlayerNotifier] Faixa marcada como pendente no banco.');
          
          // 3. Atualiza os providers para atualizar a UI imediatamente
          _ref.invalidate(playlistsProvider);
          _ref.invalidate(playlistTracksProvider(currentTrack.playlistId));
        } catch (e) {
          print('[PlayerNotifier] Erro ao atualizar banco para faixa corrompida: $e');
        }
      }
    });
  }

  /// Restaura o estado anterior salvo do player ao abrir o app
  Future<void> restoreSavedState() async {
    try {
      final saved = await AppDatabase.instance.getSavedPlayerState();
      if (saved == null) return;
      final trackId = saved['track_id'] as String?;
      final posMs = saved['position_ms'] as int? ?? 0;
      final queueStr = saved['queue_track_ids'] as String? ?? '';
      if (trackId == null || queueStr.isEmpty) return;

      final trackIds = queueStr.split(',').where((id) => id.isNotEmpty).toList();
      if (trackIds.isEmpty) return;

      final queueTracks = await AppDatabase.instance.getTracksByIds(trackIds);
      if (queueTracks.isEmpty) return;

      final sync = _ref.read(syncProvider.notifier);
      final localPathsMap = await sync.findLocalPathsBulk(queueTracks);

      final downloadedTracks = <Track>[];
      for (final t in queueTracks) {
        if (localPathsMap.containsKey(t.id)) {
          downloadedTracks.add(t);
        }
      }
      if (downloadedTracks.isEmpty) return;

      var index = downloadedTracks.indexWhere((t) => t.id == trackId);
      var actualPosMs = posMs;
      if (index < 0) {
        index = 0;
        actualPosMs = 0; // Faixa original não existe, reseta o tempo para não dar seek inválido noutra faixa
      }
      final safeIndex = index;

      final items = _buildMediaItemsFromMap(downloadedTracks, localPathsMap);
      if (items.isEmpty) return;

      _originalQueue = List<Track>.from(downloadedTracks);
      state = state.copyWith(
        queue: downloadedTracks,
        currentIndex: safeIndex,
        status: app.PlayerStatus.paused,
      );

      final adjustedIndex = safeIndex.clamp(0, items.length - 1);
      await _audio.loadQueue(
        items,
        adjustedIndex,
        initialPosition: Duration(milliseconds: actualPosMs),
      );
      await _audio.pause();
    } catch (e) {
      print('[PlayerNotifier] Erro ao restaurar estado do player: $e');
    }
  }

  // ── Reprodução ─────────────────────────────────────────────────────────

  /// Carrega e reproduz uma fila de músicas a partir do índice especificado.
  /// Filtra automaticamente faixas que não estão disponíveis offline.
  /// Aplica shuffle se ativo. Operação ATÔMICA (sem flash de index 0).
  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    final sync = _ref.read(syncProvider.notifier);

    // Identifica qual track o usuário clicou
    Track? selectedTrack;
    if (startIndex == -1 && tracks.isNotEmpty) {
      if (state.shuffleMode != app.ShuffleMode.off) {
        startIndex = Random().nextInt(tracks.length);
      } else {
        startIndex = 0;
      }
    }
    if (startIndex >= 0 && startIndex < tracks.length) selectedTrack = tracks[startIndex];

    // Resolve todos os caminhos locais de uma vez (1 varredura de diretório)
    // ao invés de chamar localPathForTrack() N vezes sequencialmente.
    final playlistId = tracks.isNotEmpty ? tracks.first.playlistId : '';
    final localPathsMap = await sync.findLocalPathsBulk(tracks);

    // Filtra apenas tracks que existem localmente (lookup em memória, O(1) cada)
    final downloadedTracks = <Track>[];
    for (final t in tracks) {
      if (localPathsMap.containsKey(t.id)) {
        downloadedTracks.add(t);
      }
    }

    if (downloadedTracks.isEmpty) return;

    // Encontra a posição da track selecionada na lista filtrada
    int selectedIndex = 0;
    if (selectedTrack != null) {
      selectedIndex =
          downloadedTracks.indexWhere((t) => t.id == selectedTrack!.id);
      if (selectedIndex < 0) selectedIndex = 0;
    }

    // Salva a ordem original para restore de shuffle
    _originalQueue = List<Track>.from(downloadedTracks);

    // Aplica shuffle se ativo (Spotify-like: só shuffla o que vem DEPOIS)
    List<Track> finalQueue;
    int finalIndex;

    if (state.shuffleMode != app.ShuffleMode.off) {
      finalQueue = _buildShuffledQueue(
          downloadedTracks, selectedIndex, state.shuffleMode);
      finalIndex = finalQueue.indexWhere((t) => t.id == selectedTrack?.id);
      if (finalIndex < 0) finalIndex = 0;
    } else {
      finalQueue = List<Track>.from(downloadedTracks);
      finalIndex = selectedIndex;
    }

    _userQueueCount = 0;
    _currentTrackLogged = false;

    // Atualiza o estado da UI imediatamente (antes de carregar o áudio)
    state = state.copyWith(
      queue: finalQueue,
      currentIndex: finalIndex,
      status: app.PlayerStatus.loading,
    );

    // Constrói os MediaItems usando o mapa já resolvido (sem I/O adicional)
    final items = _buildMediaItemsFromMap(finalQueue, localPathsMap);
    if (items.isEmpty) return;

    final adjustedIndex = finalIndex.clamp(0, items.length - 1);
    await _audio.loadQueue(items, adjustedIndex);
    
    // Inicia a reprodução automaticamente APÓS a fila ter sido carregada (evita corrida/bug do index 0)
    await play();
  }

  /// Atalho: reproduz com um modo de shuffle específico.
  Future<void> playQueueWithShuffle(List<Track> tracks,
      {required app.ShuffleMode shuffleMode, int startIndex = -1}) async {
    state = state.copyWith(shuffleMode: shuffleMode);
    await playQueue(tracks, startIndex: startIndex);
  }

  /// Reproduz uma track específica dentro de uma fila.
  Future<void> playTrack(Track track, List<Track> queue) async {
    List<Track> targetQueue = queue;
    if (targetQueue.isEmpty) {
      targetQueue = [track];
    }
    final index = targetQueue.indexWhere((t) => t.id == track.id);
    await playQueue(targetQueue, startIndex: index < 0 ? 0 : index);
  }

  // ── Fila (Spotify-like) ────────────────────────────────────────────────

  /// Adiciona uma track logo após a música atual (e após as músicas já adicionadas manualmente à fila).
  /// A track é inserida TANTO no estado do Flutter QUANTO no ConcatenatingAudioSource.
  Future<void> addToQueue(Track track) async {
    final sync = _ref.read(syncProvider.notifier);
    final localPath = await sync.localPathForTrack(track);
    if (localPath == null) return;

    final item = MediaItem(
      id: Uri.file(localPath).toString(),
      title: track.title,
      artist: track.artist,
      album: track.album,
      duration: Duration(milliseconds: track.durationMs),
      artUri:
          track.albumArtUrl != null ? Uri.parse(track.albumArtUrl!) : null,
      extras: {'track_id': track.id, 'playlist_id': track.playlistId},
    );

    // Insere como próxima música (após a música atual e após as músicas adicionadas anteriormente à fila manual)
    final int insertAt = (state.currentIndex + 1 + _userQueueCount).clamp(0, state.queue.length).toInt();
    final newQueue = List<Track>.from(state.queue)..insert(insertAt, track);
    _userQueueCount++;
    state = state.copyWith(queue: newQueue);

    // Insere no ConcatenatingAudioSource real (fix BUG 2)
    await _audio.insertItem(insertAt, item);
  }

  /// Remove uma track da fila pelo índice (não pode remover a música tocando).
  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    if (index == state.currentIndex) return;

    final list = List<Track>.from(state.queue);
    list.removeAt(index);

    int newCurrentIndex = state.currentIndex;
    if (index < state.currentIndex) {
      newCurrentIndex -= 1;
    }

    if (index > state.currentIndex && index <= state.currentIndex + _userQueueCount) {
      _userQueueCount = max(0, _userQueueCount - 1);
    }

    state = state.copyWith(queue: list, currentIndex: newCurrentIndex);
    await _audio.removeItem(index);
  }

  /// Reordena a fila (drag & drop na UI).
  /// Usa recarregamento atômico ao invés de moves sequenciais (fix BUG 3).
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) newIndex -= 1;
    if (oldIndex < 0 ||
        oldIndex >= state.queue.length ||
        newIndex < 0 ||
        newIndex >= state.queue.length) {
      return;
    }

    final list = List<Track>.from(state.queue);
    final track = list.removeAt(oldIndex);
    list.insert(newIndex, track);

    // Ajusta o currentIndex baseado na movimentação
    int newCurrentIndex = state.currentIndex;
    if (state.currentIndex == oldIndex) {
      newCurrentIndex = newIndex;
    } else if (oldIndex < state.currentIndex &&
        newIndex >= state.currentIndex) {
      newCurrentIndex -= 1;
    } else if (oldIndex > state.currentIndex &&
        newIndex <= state.currentIndex) {
      newCurrentIndex += 1;
    }

    state = state.copyWith(queue: list, currentIndex: newCurrentIndex);

    // Recarrega a fila atomicamente preservando a posição
    final sync = _ref.read(syncProvider.notifier);
    final playlistId = list.isNotEmpty ? list.first.playlistId : '';
    final localPathsMap = await sync.findLocalPathsBulk(list);
    final items = _buildMediaItemsFromMap(list, localPathsMap);
    await _audio.reloadQueue(items, newCurrentIndex);
  }

  // ── Controles Básicos ──────────────────────────────────────────────────

  Future<void> play() async {
    state = state.copyWith(status: app.PlayerStatus.playing);
    await _audio.play();
  }
  
  Future<void> pause() async {
    state = state.copyWith(status: app.PlayerStatus.paused);
    await _audio.pause();
  }
  
  Future<void> togglePlay() async {
    final willPlay = !_audio.playing;
    state = state.copyWith(status: willPlay ? app.PlayerStatus.playing : app.PlayerStatus.paused);
    if (willPlay) {
      await _audio.play();
    } else {
      await _audio.pause();
    }
  }
  Future<void> next() => _audio.skipToNext();
  Future<void> previous() => _audio.skipToPrevious();

  /// Pula para um item específico na fila de reprodução atual pelo índice.
  /// Preserva a ordem da fila e o estado de shuffle ativo.
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    await _audio.skipToQueueItem(index);
  }

  Future<void> seek(Duration position) => _audio.seek(position);
  Future<void> seekToFraction(double fraction) {
    final dur = state.duration;
    return seek(
        Duration(milliseconds: (dur.inMilliseconds * fraction).round()));
  }

  // ── Shuffle (Spotify-like) ─────────────────────────────────────────────
  //
  // Comportamento idêntico ao Spotify:
  // - OFF → Random: mantém a música atual, embaralha todo o resto
  // - Random → Smart: mantém a música atual, reordena por afinidade de gêneros
  // - Smart → OFF: restaura a ordem original da playlist
  // - A reprodução NUNCA é interrompida durante a troca de modo.

  Future<void> cycleShuffle() async {
    final next = state.shuffleMode == app.ShuffleMode.off
        ? app.ShuffleMode.random
        : app.ShuffleMode.off;
    state = state.copyWith(shuffleMode: next);

    if (state.queue.isEmpty) return;

    final currentTrack = state.currentTrack;
    if (currentTrack == null) return;

    final sync = _ref.read(syncProvider.notifier);
    final localPathsMap = await sync.findLocalPathsBulk(_originalQueue);

    final validOriginal = _originalQueue.where((t) => localPathsMap.containsKey(t.id)).toList();
    if (validOriginal.isEmpty) return;

    List<Track> newQueue;

    if (next == app.ShuffleMode.off) {
      newQueue = List<Track>.from(validOriginal);
    } else {
      final others = List<Track>.from(validOriginal)
        ..removeWhere((t) => t.id == currentTrack.id);
      others.shuffle();
      newQueue = [currentTrack, ...others];
    }

    final newIndex = newQueue.indexWhere((t) => t.id == currentTrack.id);
    final safeIndex = newIndex >= 0 ? newIndex : 0;

    final items = _buildMediaItemsFromMap(newQueue, localPathsMap);

    state = state.copyWith(queue: newQueue, currentIndex: safeIndex);
    await _audio.reloadQueue(items, safeIndex);
  }

  /// Refaz o shuffle da fila INTEIRA (usado quando a fila chega ao fim e recomeça)
  Future<void> _reShuffle() async {
    if (_originalQueue.isEmpty) return;

    final sync = _ref.read(syncProvider.notifier);
    final localPathsMap = await sync.findLocalPathsBulk(_originalQueue);
    final validOriginal = _originalQueue.where((t) => localPathsMap.containsKey(t.id)).toList();
    if (validOriginal.isEmpty) return;

    final newQueue = List<Track>.from(validOriginal)..shuffle();

    final items = _buildMediaItemsFromMap(newQueue, localPathsMap);
    state = state.copyWith(queue: newQueue, currentIndex: 0);
    await _audio.reloadQueue(items, 0);
  }

  // ── Repeat ─────────────────────────────────────────────────────────────

  Future<void> cycleRepeat() async {
    final next = app.RepeatMode
        .values[(state.repeat.index + 1) % app.RepeatMode.values.length];
    state = state.copyWith(repeat: next);
    await _audio.setRepeatMode({
      app.RepeatMode.off: AudioServiceRepeatMode.none,
      app.RepeatMode.all: AudioServiceRepeatMode.all,
      app.RepeatMode.one: AudioServiceRepeatMode.one,
    }[next]!);
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  /// Constrói a lista de MediaItems a partir das tracks (resolvendo caminhos locais).
  Future<List<MediaItem>> _buildMediaItems(List<Track> tracks) async {
    final sync = _ref.read(syncProvider.notifier);
    final items = <MediaItem>[];

    for (final track in tracks) {
      final localPath = await sync.localPathForTrack(track);

      // Se não tem arquivo local, pula silenciosamente
      if (localPath == null) continue;

      items.add(MediaItem(
        id: Uri.file(localPath).toString(),
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: Duration(milliseconds: track.durationMs),
        artUri:
            track.albumArtUrl != null ? Uri.parse(track.albumArtUrl!) : null,
        extras: {'track_id': track.id, 'playlist_id': track.playlistId},
      ));
    }
    return items;
  }

  /// Constrói MediaItems usando um mapa de caminhos já resolvido (sem I/O).
  /// Usado pelo playQueue otimizado que já fez findLocalPathsBulk().
  List<MediaItem> _buildMediaItemsFromMap(
      List<Track> tracks, Map<String, String> localPathsMap) {
    final items = <MediaItem>[];
    for (final track in tracks) {
      final localPath = localPathsMap[track.id];
      if (localPath == null) continue;

      items.add(MediaItem(
        id: Uri.file(localPath).toString(),
        title: track.title,
        artist: track.artist,
        album: track.album,
        duration: Duration(milliseconds: track.durationMs),
        artUri:
            track.albumArtUrl != null ? Uri.parse(track.albumArtUrl!) : null,
        extras: {'track_id': track.id, 'playlist_id': track.playlistId},
      ));
    }
    return items;
  }

  /// Constrói uma fila embaralhada mantendo a track selecionada na posição 0.
  /// Spotify-like: a música clicada fica primeiro, o resto é shuffled.
  List<Track> _buildShuffledQueue(
      List<Track> tracks, int selectedIndex, app.ShuffleMode mode) {
    if (tracks.isEmpty) return [];

    final selected = tracks[selectedIndex];
    final others = List<Track>.from(tracks)..removeAt(selectedIndex);

    if (mode == app.ShuffleMode.random) {
      others.shuffle();
    }
    return [selected, ...others];
  }
}

final playerProvider = StateNotifierProvider<PlayerNotifier, app.PlayerState>(
  (ref) => PlayerNotifier(ref),
);

// ── Providers derivados ───────────────────────────────────────────────────

final currentTrackProvider = Provider<Track?>((ref) {
  return ref.watch(playerProvider).currentTrack;
});

final isPlayingProvider = Provider<bool>((ref) {
  return ref.watch(playerProvider).isPlaying;
});

final playerPositionProvider = Provider<Duration>((ref) {
  return ref.watch(playerProvider).position;
});

final playerDurationProvider = Provider<Duration>((ref) {
  return ref.watch(playerProvider).duration;
});
