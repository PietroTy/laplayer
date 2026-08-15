import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'tts_announcer_service.dart';

/// Handler de áudio em background que integra just_audio + audio_service.
/// Responsável APENAS pela reprodução de áudio e notificações do sistema.
/// O gerenciamento da fila (ordem, shuffle, seleção) é feito pelo PlayerNotifier.
class LaPlayerAudioHandler extends BaseAudioHandler with SeekHandler {
  final _player = AudioPlayer();
  ConcatenatingAudioSource? _playlist;
  int _playlistGeneration = 0;
  Timer? _fadeTimer;
  bool _isFadingOut = false;
  String? _lastPlayingId;
  bool _isAnnouncing = false;
  MediaItem? _pendingTtsItem;

  final _errorController = StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorController.stream;

  LaPlayerAudioHandler() {
    _setupPlayer();
  }

  // ── Configuração ──────────────────────────────────────────────────────

  void _updatePlaybackState() {
    if (_isAnnouncing) {
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.ready,
        playing: true,
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.pause,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
      ));
      return;
    }

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
    _player.playerStateStream.listen(
      (_) => _updatePlaybackState(),
      onError: (Object e) {
        print('[LaPlayerAudioHandler] Erro no playerStateStream: $e');
        _errorController.add(e.toString());
      },
    );
    _player.playbackEventStream.listen(
      (_) => _updatePlaybackState(),
      onError: (Object e) {
        print('[LaPlayerAudioHandler] Erro no playbackEventStream: $e');
        _errorController.add(e.toString());
      },
    );

    // Sincroniza o MediaItem atual para a notificação + fade-in ao mudar de faixa
    _player.currentIndexStream.listen((index) async {
      if (index != null && index < queue.value.length) {
        final item = queue.value[index];
        mediaItem.add(item);

        // Fade-in suave apenas ao efetivamente mudar de faixa (não no seek)
        if (item.id != _lastPlayingId) {
          _lastPlayingId = item.id;
          
          if (TtsAnnouncerService.instance.isEnabled) {
            if (_player.playing) {
              // Já está tocando (mudança natural ou skip com player ativo)
              _fadeTimer?.cancel();
              await _player.setVolume(0.0); // Drop immediate
              _announceAndPlay(item);
            } else {
              // Mudança manual (o play() será chamado em seguida, então deixamos pendente)
              _pendingTtsItem = item;
            }
          } else {
            _isFadingOut = false;
            _player.setVolume(0.0);
            _fadeTo(1.0, const Duration(seconds: 2));
          }
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
  Future<void> loadQueue(List<MediaItem> items, int initialIndex, {Duration initialPosition = Duration.zero}) async {
    if (items.isEmpty) return;
    initialIndex = initialIndex.clamp(0, items.length - 1);

    queue.add(items);

    final generation = ++_playlistGeneration;
    
    // Carrega apenas um pequeno pedaço para iniciar rapidamente
    int endInitial = (initialIndex + 50).clamp(0, items.length);
    final initialBatch = items.sublist(0, endInitial);

    _playlist = ConcatenatingAudioSource(
      children: initialBatch
          .map((item) => AudioSource.uri(Uri.parse(item.id), tag: item))
          .toList(),
    );

    try {
      await _player.setAudioSource(
        _playlist!,
        initialIndex: initialIndex,
        initialPosition: initialPosition,
      );

      if (initialIndex < items.length) {
        final item = items[initialIndex];
        mediaItem.add(item);
        _lastPlayingId = item.id;
      }

      // REMOVIDO AUTO-PLAY AQUI: await _player.play();

      // Carrega o restante da fila assincronamente em pequenos lotes
      if (endInitial < items.length) {
        Future.microtask(() async {
          int current = endInitial;
          while (current < items.length && generation == _playlistGeneration) {
            int nextChunk = (current + 100).clamp(0, items.length);
            final chunk = items.sublist(current, nextChunk);
            if (_playlist != null) {
              await _playlist!.addAll(
                chunk.map((item) => AudioSource.uri(Uri.parse(item.id), tag: item)).toList()
              );
            }
            current = nextChunk;
            await Future.delayed(const Duration(milliseconds: 20)); // Cede tempo para UI
          }
        });
      }
    } catch (e) {
      print('[LaPlayerAudioHandler] Erro ao carregar/iniciar fila: $e');
      _errorController.add(e.toString());
    }
  }

  /// Recarrega a fila com uma nova ordem, preservando a posição atual.
  /// Usado para shuffle/unshuffle/reorder sem interromper a música tocando.
  Future<void> reloadQueue(List<MediaItem> items, int currentIndex) async {
    if (items.isEmpty) return;
    currentIndex = currentIndex.clamp(0, items.length - 1);

    queue.add(items);
    final generation = ++_playlistGeneration;

    // Se já estivermos tocando e a música atual for a mesma, atualizamos a fila In-Place
    // Isso evita completamente o "engasgo" de recriar o player nativo (setAudioSource)
    if (_playlist != null && _player.currentIndex != null) {
      final oldIndex = _player.currentIndex!;
      if (oldIndex < _playlist!.children.length) {
        final currentSource = _playlist!.children[oldIndex];
        final currentId = currentSource.sequence.first.tag.id;
        
        if (items[currentIndex].id == currentId) {
          try {
            // 1. Remove tudo que vem DEPOIS da música atual
            if (oldIndex + 1 < _playlist!.length) {
              await _playlist!.removeRange(oldIndex + 1, _playlist!.length);
            }
            // 2. Remove tudo que vem ANTES da música atual
            if (oldIndex > 0) {
              await _playlist!.removeRange(0, oldIndex);
            }
            // Agora _playlist tem tamanho 1, e a música tocando está no index 0.
            
            // 3. Adiciona as novas músicas que vêm ANTES
            if (currentIndex > 0) {
              final beforeItems = items.sublist(0, currentIndex);
              await _playlist!.insertAll(0, beforeItems.map((item) => AudioSource.uri(Uri.parse(item.id), tag: item)).toList());
            }
            
            // 4. Adiciona as novas músicas que vêm DEPOIS
            if (currentIndex + 1 < items.length) {
              final afterItems = items.sublist(currentIndex + 1);
              await _playlist!.insertAll(currentIndex + 1, afterItems.map((item) => AudioSource.uri(Uri.parse(item.id), tag: item)).toList());
            }

            // Atualiza os metadados da UI
            final item = items[currentIndex];
            mediaItem.add(item);
            _lastPlayingId = item.id;
            
            return; // Termina silenciosamente sem engasgar
          } catch (e) {
            print('[LaPlayerAudioHandler] Erro no in-place shuffle: $e, fazendo fallback');
          }
        }
      }
    }

    // Fallback: recria a fila (pode causar engasgo se estiver tocando)
    final wasPlaying = _player.playing;
    final currentPosition = _player.position;

    // Carrega apenas um pequeno pedaço para recarregar rapidamente
    int endInitial = (currentIndex + 50).clamp(0, items.length);
    final initialBatch = items.sublist(0, endInitial);

    _playlist = ConcatenatingAudioSource(
      children: initialBatch
          .map((item) => AudioSource.uri(Uri.parse(item.id), tag: item))
          .toList(),
    );

    try {
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

      // Carrega o restante da fila assincronamente em pequenos lotes
      if (endInitial < items.length) {
        Future.microtask(() async {
          int current = endInitial;
          while (current < items.length && generation == _playlistGeneration) {
            int nextChunk = (current + 100).clamp(0, items.length);
            final chunk = items.sublist(current, nextChunk);
            if (_playlist != null) {
              await _playlist!.addAll(
                chunk.map((item) => AudioSource.uri(Uri.parse(item.id), tag: item)).toList()
              );
            }
            current = nextChunk;
            await Future.delayed(const Duration(milliseconds: 20)); // Cede tempo para UI
          }
        });
      }
    } catch (e) {
      print('[LaPlayerAudioHandler] Erro ao recarregar fila: $e');
      _errorController.add(e.toString());
    }
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

  Future<void> _announceAndPlay(MediaItem item) async {
    _isAnnouncing = true;
    _updatePlaybackState(); // Força a UI a mostrar 'loading'
    
    // Deixamos tocando no volume zero e voltamos pro início para o TTS falar.
    _fadeTimer?.cancel();
    await _player.setVolume(0.0);
    if (_player.currentIndex != null) {
      await _player.seek(Duration.zero, index: _player.currentIndex);
    } else {
      await _player.seek(Duration.zero);
    }
    
    try {
      // Fala todas as músicas criando um espaço limpo entre elas
      await TtsAnnouncerService.instance.announceTrack(
        title: item.title,
        artist: item.artist ?? '',
      );
    } catch (e) {
      print('[LaPlayerAudioHandler] Erro no TTS announcer: $e');
    } finally {
      _isAnnouncing = false;
      _updatePlaybackState(); // Força a saída do estado de loading imediatamente
      _isFadingOut = false;
      if (_player.currentIndex != null) {
        await _player.seek(Duration.zero, index: _player.currentIndex);
      } else {
        await _player.seek(Duration.zero);
      }
      // GARANTE QUE O VOLUME RETORNE AO NORMAL (1.0) MESMO EM CASO DE ERRO OU BUG NO TTS
      await _player.setVolume(1.0);
    }
  }

  @override
  Future<void> play() async {
    if (_pendingTtsItem != null) {
      final item = _pendingTtsItem!;
      _pendingTtsItem = null;
      
      // Se a música já estiver tocando de onde parou (resumo de sessão),
      // não anunciamos novamente, apenas damos play normal com volume 1.0.
      if (_player.position.inMilliseconds > 1000) {
        await _player.setVolume(1.0);
        await _player.play();
        return;
      }

      _fadeTimer?.cancel();
      await _player.setVolume(0.0); // Garante silêncio antes de dar o play inicial
      await _player.play(); // Inicia a reprodução silenciosa para o TTS não bugar
      _announceAndPlay(item);
      return;
    }
    
    if (_isAnnouncing) return; // Protege contra play duplo
    await _player.setVolume(1.0); // Sempre reseta o volume para o nível normal ao dar play
    await _player.play();
  }

  @override
  Future<void> pause() async {
    if (_isAnnouncing) {
      _isAnnouncing = false;
      await TtsAnnouncerService.instance.stop();
      await _player.setVolume(1.0); // Garante que a música toque ao despausar
      if (_player.currentIndex != null) {
        await _player.seek(Duration.zero, index: _player.currentIndex);
      } else {
        await _player.seek(Duration.zero);
      }
    }
    await _player.setVolume(1.0);
    await _player.pause();
    _updatePlaybackState();
  }

  @override
  Future<void> stop() async {
    await _player.setVolume(1.0);
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_isAnnouncing) {
      _isAnnouncing = false;
      await TtsAnnouncerService.instance.stop();
      _updatePlaybackState();
    }
    _isFadingOut = false;
    await _player.setVolume(1.0);
    await _player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    if (_isAnnouncing) {
      _isAnnouncing = false;
      await TtsAnnouncerService.instance.stop();
      _updatePlaybackState();
    }
    await _player.setVolume(1.0);
    final currentIndex = _player.currentIndex;
    if (currentIndex != null) {
      if (currentIndex == queue.value.length - 1) {
        await _player.seek(Duration.zero, index: 0);
      } else {
        await _player.seek(Duration.zero, index: currentIndex + 1);
      }
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_isAnnouncing) {
      _isAnnouncing = false;
      await TtsAnnouncerService.instance.stop();
      _updatePlaybackState();
    }
    await _player.setVolume(1.0);
    final currentIndex = _player.currentIndex;
    // Spotify-like: se > 3s, reinicia a música; caso contrário, volta para a anterior
    if (_player.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
    } else if (currentIndex != null) {
      if (currentIndex == 0) {
        // Se estiver na primeira música, volta para a última da fila
        await _player.seek(Duration.zero, index: queue.value.length - 1);
      } else {
        await _player.seek(Duration.zero, index: currentIndex - 1);
      }
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= queue.value.length) return;
    if (_isAnnouncing) {
      _isAnnouncing = false;
      await TtsAnnouncerService.instance.stop();
      _updatePlaybackState();
    }
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

  Stream<Duration> get positionStream => _player.positionStream.map((pos) => _isAnnouncing ? Duration.zero : pos);
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
