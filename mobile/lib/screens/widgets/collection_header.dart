import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/models/player_state.dart' as app;
import '../../data/models/track.dart';
import '../../providers/player_provider.dart';

/// Topo das páginas de artista e de álbum: capa quadrada, nome, linhas de detalhe e os botões
/// de tocar e de tocar em ordem aleatória (só com as faixas que dá para tocar).
class CollectionHeader extends ConsumerWidget {
  final String? coverUrl;
  final IconData placeholderIcon;
  final String kind; // "ARTISTA" / "ÁLBUM"
  final String title;
  final Widget? subtitle;
  final String stats;
  final List<Track> playable;

  const CollectionHeader({
    super.key,
    required this.coverUrl,
    required this.placeholderIcon,
    required this.kind,
    required this.title,
    this.subtitle,
    required this.stats,
    required this.playable,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void play(app.ShuffleMode mode) => ref.read(playerProvider.notifier).playQueueWithShuffle(playable, shuffleMode: mode);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(color: AppColors.border),
                boxShadow: [BoxShadow(color: AppColors.accent.withValues(alpha: 0.25), blurRadius: 30)],
              ),
              child: coverUrl != null
                  ? CachedNetworkImage(
                      imageUrl: coverUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Icon(placeholderIcon, color: AppColors.textMuted, size: 64),
                    )
                  : Icon(placeholderIcon, color: AppColors.textMuted, size: 64),
            ),
          ),
          const SizedBox(height: 20),
          Text(kind, style: TextStyle(color: AppColors.accent, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
          const SizedBox(height: 4),
          Text(title, style: const TextStyle(color: AppColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700, height: 1.2)),
          if (subtitle != null) ...[const SizedBox(height: 6), subtitle!],
          const SizedBox(height: 6),
          Text(stats, style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: playable.isEmpty ? null : () => play(app.ShuffleMode.off),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Tocar'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: playable.isEmpty ? null : () => play(app.ShuffleMode.random),
                  icon: const Icon(Icons.shuffle_rounded),
                  label: const Text('Aleatório'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "12 músicas · 48 min · 10 baixadas"
String collectionStats(List<Track> tracks, List<Track> playable) {
  final ms = tracks.fold<int>(0, (a, t) => a + t.durationMs);
  final min = (ms / 60000).round();
  final time = min >= 60 ? '${min ~/ 60} h ${min % 60} min' : '$min min';
  return '${tracks.length} música${tracks.length == 1 ? '' : 's'} · $time · ${playable.length} baixada${playable.length == 1 ? '' : 's'}';
}

/// Título de seção ("ÁLBUNS", "MÚSICAS"), no mesmo estilo dos outros apps.
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
        child: Text(text, style: const TextStyle(color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.5)),
      );
}
