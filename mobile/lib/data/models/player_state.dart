import 'track.dart';

enum RepeatMode { off, all, one }

enum ShuffleMode { off, random }

enum PlayerStatus { idle, loading, playing, paused, error }

/// Estado imutável do player
class PlayerState {
  final List<Track>  queue;
  final int          currentIndex;
  final PlayerStatus status;
  final Duration     position;
  final Duration     duration;
  final ShuffleMode  shuffleMode;
  final RepeatMode   repeat;
  final double       volume;         // 0.0 – 1.0
  final String?      errorMessage;

  const PlayerState({
    this.queue         = const [],
    this.currentIndex  = 0,
    this.status        = PlayerStatus.idle,
    this.position      = Duration.zero,
    this.duration      = Duration.zero,
    this.shuffleMode   = ShuffleMode.off,
    this.repeat        = RepeatMode.off,
    this.volume        = 1.0,
    this.errorMessage,
  });

  Track? get currentTrack =>
      queue.isNotEmpty && currentIndex < queue.length
          ? queue[currentIndex]
          : null;

  bool get isPlaying  => status == PlayerStatus.playing;
  bool get isLoading  => status == PlayerStatus.loading;
  bool get hasError   => status == PlayerStatus.error;
  bool get hasNext    => currentIndex < queue.length - 1 || repeat != RepeatMode.off;
  bool get hasPrev    => currentIndex > 0;

  double get progressFraction {
    if (duration.inMilliseconds == 0) return 0.0;
    return position.inMilliseconds / duration.inMilliseconds;
  }

  PlayerState copyWith({
    List<Track>?  queue,
    int?          currentIndex,
    PlayerStatus? status,
    Duration?     position,
    Duration?     duration,
    ShuffleMode?  shuffleMode,
    RepeatMode?   repeat,
    double?       volume,
    String?       errorMessage,
  }) {
    return PlayerState(
      queue:         queue        ?? this.queue,
      currentIndex:  currentIndex ?? this.currentIndex,
      status:        status       ?? this.status,
      position:      position     ?? this.position,
      duration:      duration     ?? this.duration,
      shuffleMode:   shuffleMode  ?? this.shuffleMode,
      repeat:        repeat       ?? this.repeat,
      volume:        volume       ?? this.volume,
      errorMessage:  errorMessage ?? this.errorMessage,
    );
  }
}
