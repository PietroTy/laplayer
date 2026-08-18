import 'dart:math' as math;
import 'dart:ui';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../data/models/player_state.dart' as app;
import '../data/models/track.dart';
import '../providers/player_provider.dart';
import '../data/services/lyrics_service.dart';
import '../data/services/sync_service.dart';
import 'widgets/track_tile.dart';

class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Escuta erros de reprodução (ex: arquivo corrompido)
    ref.listen<app.PlayerState>(playerProvider, (prev, next) {
      if (next.status == app.PlayerStatus.error && next.errorMessage != null && next.errorMessage!.isNotEmpty) {
        final errorMsg = next.errorMessage!.toLowerCase();
        String displayError = 'Erro na reprodução desta faixa.';
        if (errorMsg.contains('source') || errorMsg.contains('codec') || errorMsg.contains('corrupt') || errorMsg.contains('decode') || errorMsg.contains('player') || errorMsg.contains('exception')) {
          displayError = 'Arquivo corrompido ou erro de decodificação no áudio.';
        }
        
        final errorTrack = next.currentTrack;
        if (errorTrack != null) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(displayError),
              backgroundColor: Colors.red.shade900,
              duration: const Duration(seconds: 6),
              action: SnackBarAction(
                label: 'Rebaixar',
                textColor: Colors.white,
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tentando baixar novamente...')));
                  ref.read(syncProvider.notifier).retryTrackDownload(errorTrack);
                },
              ),
            ),
          );
        }
      }
    });

    final palette = ref.watch(themePaletteProvider);
    final state   = ref.watch(playerProvider);
    final player  = ref.read(playerProvider.notifier);
    final track   = state.currentTrack;

    if (track == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/home');
        }
      });
      return Scaffold(
        backgroundColor: palette.bg,
        body: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      backgroundColor: palette.bg,
      body: Stack(
        children: [
          // ── Fundo Imersivo (Blurred Album Art com Tinta do Tema) ──────
          if (track.albumArtUrl != null)
            Positioned.fill(
              child: CachedNetworkImage(
                imageUrl: track.albumArtUrl!,
                fit: BoxFit.cover,
              ),
            ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 50, sigmaY: 50),
              child: Container(
                color: palette.bg.withValues(alpha: 0.75), // Herda a cor escura do tema ativo
              ),
            ),
          ),
          
          // ── Conteúdo Principal ──────────────────────────────────────────
          SafeArea(
            child: Column(
              children: [
                // ── Top bar ───────────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 34),
                        color: Colors.white,
                        onPressed: () => context.pop(),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            const Text('TOCANDO AGORA',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              track.album,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.more_vert_rounded),
                        color: Colors.white,
                        onPressed: () => _showTrackOptions(context, ref),
                      ),
                    ],
                  ),
                ),

                // ── Album Art Animada ────────────────────────────────────────
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                      child: Hero(
                        tag: 'album_art_${track.id}',
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.8, end: state.isPlaying ? 1.0 : 0.9),
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.easeOutBack,
                          builder: (context, scale, child) {
                            return Transform.scale(
                              scale: scale,
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(24),
                                    boxShadow: AppColors.premiumShadow,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(24),
                                    child: track.albumArtUrl != null
                                        ? CachedNetworkImage(
                                            imageUrl: track.albumArtUrl!,
                                            fit: BoxFit.cover,
                                            placeholder: (_, __) => _ArtPlaceholder(),
                                            errorWidget: (_, __, ___) => _ArtPlaceholder(),
                                          )
                                        : _ArtPlaceholder(),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),

                // ── Track info ────────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: () {
                          context.pop();
                          context.push('/artist/${Uri.encodeComponent(track.artist)}');
                        },
                        child: Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                // ── Progress Slider ───────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 6,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
                          activeTrackColor: palette.accent,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: palette.accent,
                          overlayColor: palette.accent.withValues(alpha: 0.2),
                        ),
                        child: Slider(
                          value: state.progressFraction.clamp(0.0, 1.0),
                          onChanged: (v) => player.seekToFraction(v),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              _fmt(state.position),
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                            Text(
                              _fmt(state.duration),
                              style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 16),

                // ── Controls ──────────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Shuffle
                      IconButton(
                        icon: Icon(
                          Icons.shuffle_rounded,
                          color: state.shuffleMode != app.ShuffleMode.off
                              ? palette.accent
                              : Colors.white38,
                          size: 26,
                        ),
                        iconSize: 26,
                        onPressed: player.cycleShuffle,
                        tooltip: 'Shuffle',
                      ),
                      // Previous
                      IconButton(
                        icon: const Icon(Icons.skip_previous_rounded),
                        color: Colors.white,
                        iconSize: 42,
                        onPressed: player.previous,
                      ),
                      // Play/Pause
                      GestureDetector(
                        onTap: player.togglePlay,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: state.isPlaying ? 74 : 80,
                          height: state.isPlaying ? 74 : 80,
                          decoration: BoxDecoration(
                            color: palette.accent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: palette.accent.withValues(alpha: 0.35),
                                blurRadius: 20,
                                spreadRadius: 4,
                              )
                            ],
                          ),
                          child: state.isLoading
                              ? const Padding(
                                  padding: EdgeInsets.all(22),
                                  child: CircularProgressIndicator(
                                    color: Colors.black, strokeWidth: 2.5,
                                  ),
                                )
                              : Icon(
                                  state.isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.black,
                                  size: 42,
                                ),
                        ),
                      ),
                      // Next
                      IconButton(
                        icon: const Icon(Icons.skip_next_rounded),
                        color: Colors.white,
                        iconSize: 42,
                        onPressed: player.next,
                      ),
                      // Repeat
                      IconButton(
                        icon: Icon(
                          state.repeat == app.RepeatMode.one
                              ? Icons.repeat_one_rounded
                              : Icons.repeat_rounded,
                          color: state.repeat != app.RepeatMode.off
                              ? palette.accent
                              : Colors.white38,
                        ),
                        iconSize: 26,
                        onPressed: player.cycleRepeat,
                      ),
                    ],
                  ),
                ),

                // ── Queue indicator & button ──────────────────────────────────
                Padding(
                  padding: const EdgeInsets.only(bottom: 32, left: 32, right: 32, top: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.lyrics_rounded, size: 28),
                        color: Colors.white,
                        onPressed: () => _showLyricsBottomSheet(context, ref),
                        tooltip: 'Letras da Música',
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: palette.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: palette.accent.withValues(alpha: 0.35)),
                        ),
                        child: Text(
                          '${state.currentIndex + 1} / ${state.queue.length}',
                          style: TextStyle(color: palette.accent, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.queue_music_rounded, size: 28),
                        color: Colors.white,
                        onPressed: () => _showQueueBottomSheet(context, ref),
                        tooltip: 'Fila de Reprodução',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$m:$s';
  }

  void _showTrackOptions(BuildContext context, WidgetRef ref) {
    final track = ref.read(playerProvider).currentTrack;
    if (track == null) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.playlist_play_rounded, color: AppColors.textSecond),
              title: const Text('Abrir na Playlist',
                style: TextStyle(color: AppColors.textPrimary),
              ),
              subtitle: const Text('Ir para a playlist onde esta faixa está salva',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11),
              ),
              onTap: () {
                Navigator.pop(context); // fecha o bottom sheet de opcoes
                context.pop(); // fecha a player screen fullscreen
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  context.push(
                    '/library/playlist/${track.playlistId}?name=${Uri.encodeComponent(track.album)}&highlightTrackId=${track.id}',
                  );
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.queue_music_rounded, color: AppColors.textSecond),
              title: const Text('Adicionar à fila',
                style: TextStyle(color: AppColors.textPrimary),
              ),
              onTap: () {
                Navigator.pop(context); // fecha o bottom sheet de opcoes
                ref.read(playerProvider.notifier).addToQueue(track);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('"${track.title}" adicionada à fila'),
                    duration: const Duration(seconds: 2),
                    backgroundColor: AppColors.accent,
                  ),
                );
              },
            ),

            ListTile(
              leading: Icon(Icons.info_outline_rounded, color: AppColors.accent),
              title: const Text('Sobre a música',
                style: TextStyle(color: AppColors.textPrimary),
              ),
              subtitle: Text(
                '${track.releaseYear}  •  ${track.genres.take(2).join(', ')}  •  Toque para ver tudo',
                style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(context); // fecha o bottom sheet de opcoes
                showTrackInfoSheet(context, ref, track);
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }



  void _showQueueBottomSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: const _QueueSheet(),
      ),
    );
  }

  void _showLyricsBottomSheet(BuildContext context, WidgetRef ref) {
    final state = ref.read(playerProvider);
    final track = state.currentTrack;
    if (track == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: _LyricsSheet(track: track),
      ),
    );
  }
}

class _LyricsSheet extends ConsumerStatefulWidget {
  final Track track;
  const _LyricsSheet({required this.track});

  @override
  ConsumerState<_LyricsSheet> createState() => _LyricsSheetState();
}

class _LyricsSheetState extends ConsumerState<_LyricsSheet> {
  bool _isLoading = true;
  LyricsResult? _lyricsResult;
  bool _isSyncEnabled = true;
  int _lastActiveIndex = -1;
  late final ScrollController _scrollController;
  final List<GlobalKey> _lineKeys = [];

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _loadLyrics();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLyrics() async {
    try {
      final res = await LyricsService.instance.getLyrics(widget.track);
      if (mounted) {
        setState(() {
          _lyricsResult = res;
          _lineKeys.clear();
          if (res != null) {
            for (int i = 0; i < res.lines.length; i++) {
              _lineKeys.add(GlobalKey());
            }
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  int _findActiveLineIndex(List<LyricsLine> lines, Duration currentPos) {
    int activeIndex = -1;
    for (int i = 0; i < lines.length; i++) {
      final timestamp = lines[i].timestamp;
      if (timestamp != null && currentPos >= timestamp) {
        activeIndex = i;
      }
    }
    return activeIndex;
  }

  @override
  Widget build(BuildContext context) {
    final playerState = ref.watch(playerProvider);
    final playerNotifier = ref.read(playerProvider.notifier);
    
    // Se a música tocando no player mudou, recarrega a letra!
    if (playerState.currentTrack?.id != widget.track.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.pop(context); // Fecha a letra da música antiga
        }
      });
    }

    final position = playerState.position;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        widget.track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecond,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _isSyncEnabled ? Icons.timer_rounded : Icons.timer_off_rounded,
                    color: _isSyncEnabled ? AppColors.accent : Colors.white60,
                  ),
                  tooltip: _isSyncEnabled ? 'Desativar sincronização de tempo' : 'Ativar sincronização de tempo',
                  onPressed: () {
                    setState(() {
                      _isSyncEnabled = !_isSyncEnabled;
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(color: AppColors.border, height: 1),
          Expanded(
            child: _buildContent(position, playerNotifier),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(Duration position, PlayerNotifier playerNotifier) {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(AppColors.accent),
        ),
      );
    }

    if (_lyricsResult == null || _lyricsResult!.lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.music_off_outlined,
                size: 64,
                color: AppColors.textMuted,
              ),
              const SizedBox(height: 16),
              const Text(
                'Letra não disponível',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Não conseguimos encontrar a letra desta música.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textSecond,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final lines = _lyricsResult!.lines;
    final isSynced = _lyricsResult!.isSynced && _isSyncEnabled;
    final activeIndex = isSynced ? _findActiveLineIndex(lines, position) : -1;

    // Se mudou o índice ativo e for sincronizado, faz scroll automático suave
    if (isSynced && activeIndex != _lastActiveIndex) {
      final isFirstTime = _lastActiveIndex == -1;
      _lastActiveIndex = activeIndex;
      if (activeIndex >= 0 && activeIndex < _lineKeys.length) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final key = _lineKeys[activeIndex];
          if (key.currentContext != null) {
            Scrollable.ensureVisible(
              key.currentContext!,
              duration: isFirstTime ? Duration.zero : const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              alignment: 0.5, // 0.5 Centers the item exactly in the viewport
            );
          }
        });
      }
    }

    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 120), // Margem extra para conseguir centralizar o final
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: List.generate(lines.length, (index) {
          final line = lines[index];
          final isActive = isSynced && index == activeIndex;
          
          // Estilização premium e dinâmica
          final TextStyle textStyle;
          if (isSynced) {
            textStyle = TextStyle(
              color: isActive ? AppColors.accent : Colors.white60,
              fontSize: isActive ? 20 : 16,
              fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
              height: 1.5,
            );
          } else {
            // Letra não-sincronizada simples
            textStyle = const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              height: 1.6,
            );
          }

          return InkWell(
            key: _lineKeys[index],
            onTap: isSynced && line.timestamp != null
                ? () {
                    playerNotifier.seek(line.timestamp!);
                  }
                : null,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: isActive ? AppColors.accent.withOpacity(0.05) : Colors.transparent,
              ),
              child: Text(
                line.text.trim().isEmpty ? '♫' : line.text,
                style: textStyle,
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _ArtPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surfaceHigh,
      child: const Icon(Icons.music_note_rounded,
        color: AppColors.textMuted, size: 72,
      ),
    );
  }
}

class _QueueSheet extends ConsumerStatefulWidget {
  const _QueueSheet();

  @override
  ConsumerState<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends ConsumerState<_QueueSheet> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(playerProvider);
      final currentIndex = state.currentIndex;
      final startPast = math.max(0, currentIndex - 5);
      final numPast = currentIndex - startPast;
      if (numPast > 0 && _scrollController.hasClients) {
        _scrollController.jumpTo(37.0 + 56.0 * numPast);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(playerProvider);
    final notifier = ref.read(playerProvider.notifier);
    final currentIndex = state.currentIndex;
    final queue = state.queue;

    if (queue.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: const Center(child: Text('Fila vazia', style: TextStyle(color: Colors.white))),
      );
    }

    // Split queue into: Anteriores (up to 5), Atual, A Seguir
    final pastTracks = <MapEntry<int, Track>>[];
    final startPast = math.max(0, currentIndex - 5);
    for (int i = startPast; i < currentIndex; i++) {
      pastTracks.add(MapEntry(i, queue[i]));
    }

    final currentTrack = queue[currentIndex];

    final upcomingTracks = <MapEntry<int, Track>>[];
    for (int i = currentIndex + 1; i < queue.length; i++) {
      upcomingTracks.add(MapEntry(i, queue[i]));
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Fila de Reprodução',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Fechar', style: TextStyle(color: AppColors.accent)),
                ),
              ],
            ),
          ),
          const Divider(color: AppColors.border, height: 1),
          Expanded(
            child: CustomScrollView(
              controller: _scrollController,
              slivers: [
                if (pastTracks.isNotEmpty) ...[
                  const SliverToBoxAdapter(
                    child: SizedBox(
                      height: 37,
                      child: Padding(
                        padding: EdgeInsets.only(left: 20, top: 16, bottom: 8),
                        child: Text(
                          'Tocadas Anteriormente (Últimas 5)',
                          style: TextStyle(color: AppColors.textMuted, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, idx) {
                        final entry = pastTracks[idx];
                        final track = entry.value;
                        return Opacity(
                          opacity: 0.5,
                          child: SizedBox(
                            height: 56,
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: track.albumArtUrl != null
                                    ? CachedNetworkImage(
                                        imageUrl: track.albumArtUrl!,
                                        width: 40, height: 40,
                                        fit: BoxFit.cover,
                                      )
                                    : Container(width: 40, height: 40, color: AppColors.surfaceHigh, child: const Icon(Icons.music_note)),
                              ),
                              title: Text(track.title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(track.artist, style: const TextStyle(color: AppColors.textMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () => notifier.skipToQueueItem(entry.key),
                            ),
                          ),
                        );
                      },
                      childCount: pastTracks.length,
                    ),
                  ),
                ],
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 20, top: 20, bottom: 8),
                    child: Text('Tocando Agora', style: TextStyle(color: AppColors.accent, fontSize: 13, fontWeight: FontWeight.bold)),
                  ),
                ),
                SliverToBoxAdapter(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    tileColor: AppColors.surface,
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: currentTrack.albumArtUrl != null
                          ? CachedNetworkImage(
                              imageUrl: currentTrack.albumArtUrl!,
                              width: 40, height: 40,
                              fit: BoxFit.cover,
                            )
                          : Container(width: 40, height: 40, color: AppColors.surfaceHigh, child: const Icon(Icons.music_note)),
                    ),
                    title: Text(currentTrack.title, style: TextStyle(color: AppColors.accent, fontSize: 14, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(currentTrack.artist, style: const TextStyle(color: Colors.white70, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                if (upcomingTracks.isNotEmpty) ...[
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(left: 20, top: 20, bottom: 8),
                      child: Text('A Seguir', style: TextStyle(color: AppColors.textMuted, fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  SliverReorderableList(
                    itemCount: upcomingTracks.length,
                    onReorder: (oldIdx, newIdx) {
                      final absoluteOld = upcomingTracks[oldIdx].key;
                      final absoluteNew = newIdx < upcomingTracks.length
                          ? upcomingTracks[newIdx].key
                          : queue.length;
                      notifier.reorderQueue(absoluteOld, absoluteNew);
                    },
                    itemBuilder: (context, idx) {
                      final entry = upcomingTracks[idx];
                      final track = entry.value;
                      return ReorderableDelayedDragStartListener(
                        key: ValueKey('queue_item_${entry.key}_${track.id}'),
                        index: idx,
                        child: Material(
                          color: Colors.transparent,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: track.albumArtUrl != null
                                  ? CachedNetworkImage(
                                      imageUrl: track.albumArtUrl!,
                                      width: 40, height: 40,
                                      fit: BoxFit.cover,
                                    )
                                  : Container(width: 40, height: 40, color: AppColors.surfaceHigh, child: const Icon(Icons.music_note)),
                            ),
                            title: Text(track.title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(track.artist, style: const TextStyle(color: AppColors.textMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                            onTap: () => notifier.skipToQueueItem(entry.key),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline_rounded, color: AppColors.error, size: 20),
                                  onPressed: () => notifier.removeFromQueue(entry.key),
                                ),
                                ReorderableDragStartListener(
                                  index: idx,
                                  child: const Icon(Icons.drag_handle_rounded, color: AppColors.textMuted),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
