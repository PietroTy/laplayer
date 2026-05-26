import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

/// Handler de áudio em background que integra just_audio + audio_service.
/// Responsável APENAS pela reprodução de áudio e notificações do sistema.
/// O gerenciamento da fila (ordem, shuffle, seleção) é feito pelo PlayerNotifier.
class LaPlayerAudioHandler extends BaseAudioHandler with SeekHandler {
  final _player = AudioPlayer();
  ConcatenatingAudioSource? _playlist;
  Timer? _fadeTimer;
  bool _isFadingOut = false;
  String? _lastPlayingId;

  LaPlayerAudioHandler() {
    _setupPlayer();
  }

  // ── Configuração ──────────────────────────────────────────────────────

  void _updatePlaybackState() {
    final playing = _player.playing;
    final processingState = {
      ProcessingState.idle: AudioProcessingState.idle,
      ProcessingState.loading: AudioProcessingState.loading,
      ProcessingState.buffering: AudioProcessingState.buffering,
      ProcessingState.ready: AudioProcessingState.ready,
      ProcessingState.completed: AudioProcessingState.completed,
    }[_player.processingState] ?? AudioProcessingState.idle;

    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processingState,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _player.currentIndex,
    ));
  }

  void _setupPlayer() {
    // Propaga estado do player para a notificação do sistema (lockscreen, etc.)
    _player.playerStateStream.listen((_) => _updatePlaybackState());
    _player.playbackEventStream.listen((_) => _updatePlaybackState());

    // Sincroniza o MediaItem atual para a notificação + fade-in ao mudar de faixa
    _player.currentIndexStream.listen((index) {
      if (index != null && index < queue.value.length) {
        final item = queue.value[index];
        mediaItem.add(item);

        // Fade-in suave apenas ao efetivamente mudar de faixa (não no seek)
        if (item.id != _lastPlayingId) {
          _lastPlayingId = item.id;
          _isFadingOut = false;
          _player.setVolume(0.0);
          _fadeTo(1.0, const Duration(seconds: 2));
        }
      }
    });

    // Fade-out suave nos últimos 5 segundos da música
    _player.positionStream.listen((position) {
      final duration = _player.duration;
      if (duration != null && duration.inMilliseconds > 5000) {
        final remaining = duration.inMilliseconds - position.inMilliseconds;
        if (remaining <= 5000 && !_isFadingOut && _player.playing) {
          _isFadingOut = true;
          _fadeTo(0.0, const Duration(seconds: 5));
        } else if (remaining > 5000 && _isFadingOut) {
          _isFadingOut = false;
          _fadeTo(1.0, const Duration(milliseconds: 300));
        }
      }
    });
  }

  // ── Gestão Atômica de Fila ──────────────────────────────────────────────

  /// Carrega uma nova fila e começa a tocar no índice especificado.
  /// Operação ATÔMICA: a fila e o índice são definidos juntos via
  /// `setAudioSource(initialIndex:)`, eliminando qualquer flash de
  /// estado intermediário (antigo bug do index 0).
  Future<void> loadQueue(List<MediaItem> items, int initialIndex) async {
    if (items.isEmpty) return;
    initialIndex = initialIndex.clamp(0, items.length - 1);

    queue.add(items);

    _playlist = ConcatenatingAudioSource(
      children: items
          .map((item) => AudioSource.uri(Uri.parse(item.id), tag: item))
          .toList(),
    );

    await _player.setAudioSource(
      _playlist!,
      initialIndex: initialIndex,
      initialPosition: Duration.zero,
    );

    if (initialIndex < items.length) {
      final item = items[initialIndex];
      mediaItem.add(item);
      _lastPlayingId = item.id;
    }

    await _player.play();
  }

  /// Recarrega a fila com uma nova ordem, preservando a posição atual.
  /// Usado para shuffle/unshuffle/reorder sem interromper a música tocando.
  Future<void> reloadQueue(List<MediaItem> items, int currentIndex) async {
    if (items.isEmpty) return;
    currentIndex = currentIndex.clamp(0, items.length - 1);

    final wasPlaying = _player.playing;
    final currentPosition = _player.position;

    queue.add(items);

    _playlist = ConcatenatingAudioSource(
      children: items
          .map((item) => AudioSource.uri(Uri.parse(item.id), tag: item))
          .toList(),
    );

    // Preserva a posição exata de reprodução durante o reordenamento
    await _player.setAudioSource(
      _playlist!,
      initialIndex: currentIndex,
      initialPosition: currentPosition,
    );

    if (currentIndex < items.length) {
      final item = items[currentIndex];
      mediaItem.add(item);
      _lastPlayingId = item.id;
    }

    if (wasPlaying) await _player.play();
  }

  /// Insere um item na fila sem interromper a reprodução atual.
  /// Usado pelo "Adicionar à Fila" no menu de contexto.
  Future<void> insertItem(int index, MediaItem item) async {
    if (_playlist == null) return;

    final currentQueue = List<MediaItem>.from(queue.value);
    final clampedIndex = index.clamp(0, currentQueue.length);
    currentQueue.insert(clampedIndex, item);
    queue.add(currentQueue);

    await _playlist!.insert(
      clampedIndex,
      AudioSource.uri(Uri.parse(item.id), tag: item),
    );
  }

  /// Remove um item da fila pelo índice sem interromper a reprodução atual.
  Future<void> removeItem(int index) async {
    if (_playlist == null) return;
    final currentQueue = List<MediaItem>.from(queue.value);
    if (index < 0 || index >= currentQueue.length) return;

    await _playlist!.removeAt(index);
    currentQueue.removeAt(index);
    queue.add(currentQueue);
  }

  // ── Controles de Reprodução ────────────────────────────────────────────

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() => _player.seekToNext();

  @override
  Future<void> skipToPrevious() async {
    // Spotify-like: se > 3s, reinicia a música; caso contrário, volta para a anterior
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
    } else {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= queue.value.length) return;
    try {
      await _player.seek(Duration.zero, index: index);
      await _player.play();
    } catch (e) {
      print('Erro ao pular para item da fila: $e');
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await _player.setLoopMode({
      AudioServiceRepeatMode.none: LoopMode.off,
      AudioServiceRepeatMode.one: LoopMode.one,
      AudioServiceRepeatMode.all: LoopMode.all,
      AudioServiceRepeatMode.group: LoopMode.all,
    }[repeatMode]!);
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'setVolume') {
      await _player.setVolume((extras?['volume'] as double?) ?? 1.0);
    }
  }

  // ── Streams Públicos (para a UI via PlayerNotifier) ────────────────────

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<bool> get playingStream => _player.playingStream;
  Stream<int?> get currentIndexStream => _player.currentIndexStream;
  bool get playing => _player.playing;
  int? get playerCurrentIndex => _player.currentIndex;

  // ── Fade ──────────────────────────────────────────────────────────────

  void _fadeTo(double targetVolume, Duration duration) {
    _fadeTimer?.cancel();
    const steps = 25;
    final stepInterval = duration.inMilliseconds ~/ steps;
    final startVolume = _player.volume;
    final diff = targetVolume - startVolume;
    int step = 0;

    _fadeTimer = Timer.periodic(Duration(milliseconds: stepInterval), (timer) {
      step++;
      final ratio = step / steps;
      final currentVol = startVolume + (diff * ratio);
      _player.setVolume(currentVol.clamp(0.0, 1.0));
      if (step >= steps) {
        timer.cancel();
      }
    });
  }
}
