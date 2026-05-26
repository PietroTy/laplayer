import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  PlayerNotifier(this._ref) : super(const app.PlayerState()) {
    _listenToHandler();
  }

  LaPlayerAudioHandler get _audio => _handler(_ref);

  void _listenToHandler() {
    // Posição e duração com lógica de histórico ao atingir o final da faixa
    _audio.positionStream.listen((pos) {
      state = state.copyWith(position: pos);

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
    });

    // Sincronização de índice via stream do player nativo.
    // Dispara quando o player avança automaticamente (fim de faixa),
    // ou quando o usuário pula (next/previous/queue tap).
    // Só atualiza quando o índice realmente muda, evitando loops.
    _audio.currentIndexStream.listen((index) {
      if (index != null &&
          index < state.queue.length &&
          index != state.currentIndex) {
        state = state.copyWith(currentIndex: index);
        _currentTrackLogged = false; // Reseta flag para a nova faixa
      }
    });
  }

  // ── Reprodução ─────────────────────────────────────────────────────────

  /// Carrega e reproduz uma fila de músicas a partir do índice especificado.
  /// Filtra automaticamente faixas que não estão disponíveis offline.
  /// Aplica shuffle se ativo. Operação ATÔMICA (sem flash de index 0).
  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    final sync = _ref.read(syncProvider.notifier);

    // Identifica qual track o usuário clicou
    Track? selectedTrack;
    if (startIndex < tracks.length) selectedTrack = tracks[startIndex];

    // Filtra apenas tracks que existem localmente
    final downloadedTracks = <Track>[];
    for (final t in tracks) {
      if (await sync.localPathForTrack(t) != null) {
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

    _currentTrackLogged = false;

    // Atualiza o estado da UI imediatamente (antes de carregar o áudio)
    state = state.copyWith(
      queue: finalQueue,
      currentIndex: finalIndex,
      status: app.PlayerStatus.loading,
    );

    // Constrói os MediaItems e carrega ATOMICAMENTE com o índice correto
    final items = await _buildMediaItems(finalQueue);
    if (items.isEmpty) return;

    final adjustedIndex = finalIndex.clamp(0, items.length - 1);
    await _audio.loadQueue(items, adjustedIndex);
  }

  /// Atalho: reproduz com um modo de shuffle específico.
  Future<void> playQueueWithShuffle(List<Track> tracks,
      {required app.ShuffleMode shuffleMode, int startIndex = 0}) async {
    state = state.copyWith(shuffleMode: shuffleMode);
    await playQueue(tracks, startIndex: startIndex);
  }

  /// Reproduz uma track específica dentro de uma fila.
  Future<void> playTrack(Track track, List<Track> queue) async {
    final index = queue.indexWhere((t) => t.id == track.id);
    await playQueue(queue, startIndex: index < 0 ? 0 : index);
  }

  // ── Fila (Spotify-like) ────────────────────────────────────────────────

  /// Adiciona uma track logo após a música atual na fila, sem interromper.
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

    // Insere logo após a música atual
    final insertAt = (state.currentIndex + 1).clamp(0, state.queue.length);
    final newQueue = List<Track>.from(state.queue)..insert(insertAt, track);
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
    final items = await _buildMediaItems(list);
    await _audio.reloadQueue(items, newCurrentIndex);
  }

  // ── Controles Básicos ──────────────────────────────────────────────────

  Future<void> play() => _audio.play();
  Future<void> pause() => _audio.pause();
  Future<void> togglePlay() =>
      _audio.playing ? _audio.pause() : _audio.play();
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
    final next = app.ShuffleMode
        .values[(state.shuffleMode.index + 1) % app.ShuffleMode.values.length];
    state = state.copyWith(shuffleMode: next);

    if (state.queue.isEmpty) return;

    final currentTrack = state.currentTrack;
    if (currentTrack == null) return;

    List<Track> newQueue;

    if (next == app.ShuffleMode.off) {
      // Restaura a ordem original da playlist
      newQueue = List<Track>.from(_originalQueue);
    } else if (next == app.ShuffleMode.random) {
      // Mantém a música atual na posição 0, embaralha todo o resto
      final others = List<Track>.from(_originalQueue)
        ..removeWhere((t) => t.id == currentTrack.id);
      others.shuffle();
      newQueue = [currentTrack, ...others];
    } else {
      // Smart Shuffle: ordena por afinidade de gêneros a partir da música atual
      final others = List<Track>.from(_originalQueue)
        ..removeWhere((t) => t.id == currentTrack.id);

      final smartOrder = <Track>[];
      final remaining = List<Track>.from(others);
      Track last = currentTrack;

      while (remaining.isNotEmpty) {
        int bestIdx = 0;
        int bestOverlap = -1;
        for (int i = 0; i < remaining.length; i++) {
          final overlap =
              remaining[i].genres.where((g) => last.genres.contains(g)).length;
          if (overlap > bestOverlap) {
            bestOverlap = overlap;
            bestIdx = i;
          }
        }
        final nextTrack = remaining.removeAt(bestIdx);
        smartOrder.add(nextTrack);
        last = nextTrack;
      }

      newQueue = [currentTrack, ...smartOrder];
    }

    // Localiza a música atual na nova ordem
    final newIndex = newQueue.indexWhere((t) => t.id == currentTrack.id);
    final safeIndex = newIndex >= 0 ? newIndex : 0;

    state = state.copyWith(queue: newQueue, currentIndex: safeIndex);

    // Recarrega o player com a nova ordem, preservando a posição de reprodução
    final items = await _buildMediaItems(newQueue);
    await _audio.reloadQueue(items, safeIndex);
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

  /// Constrói uma fila embaralhada mantendo a track selecionada na posição 0.
  /// Spotify-like: a música clicada fica primeiro, o resto é shuffled.
  List<Track> _buildShuffledQueue(
      List<Track> tracks, int selectedIndex, app.ShuffleMode mode) {
    if (tracks.isEmpty) return [];

    final selected = tracks[selectedIndex];
    final others = List<Track>.from(tracks)..removeAt(selectedIndex);

    if (mode == app.ShuffleMode.random) {
      others.shuffle();
      return [selected, ...others];
    }

    // Smart shuffle por gêneros
    final smartOrder = <Track>[];
    final remaining = List<Track>.from(others);
    Track last = selected;

    while (remaining.isNotEmpty) {
      int bestIdx = 0;
      int bestOverlap = -1;
      for (int i = 0; i < remaining.length; i++) {
        final overlap =
            remaining[i].genres.where((g) => last.genres.contains(g)).length;
        if (overlap > bestOverlap) {
          bestOverlap = overlap;
          bestIdx = i;
        }
      }
      final nextTrack = remaining.removeAt(bestIdx);
      smartOrder.add(nextTrack);
      last = nextTrack;
    }

    return [selected, ...smartOrder];
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
