import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/services/sync_service.dart';
import '../../providers/player_provider.dart';
import 'mini_player.dart';

class ScaffoldWithNav extends ConsumerWidget {
  final Widget child;
  const ScaffoldWithNav({super.key, required this.child});

  static const _tabs = [
    _NavTab(icon: Icons.home_rounded,     label: 'Home',    path: '/home'),
    _NavTab(icon: Icons.search_rounded,   label: 'Busca',   path: '/search'),
    _NavTab(icon: Icons.library_music_rounded, label: 'Biblioteca', path: '/library'),
    _NavTab(icon: Icons.settings_rounded, label: 'Config',  path: '/settings'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location     = GoRouterState.of(context).uri.path;
    final currentIndex = _tabs.indexWhere((t) => location.startsWith(t.path));
    final hasTrack     = ref.watch(currentTrackProvider) != null;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          Expanded(child: child),
          const _GlobalSyncBanner(),
          if (hasTrack) const MiniPlayer(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
        ),
        child: NavigationBar(
          backgroundColor:    AppColors.surface,
          surfaceTintColor:   Colors.transparent,
          indicatorColor:     AppColors.accent.withValues(alpha: 0.15),
          selectedIndex:      currentIndex < 0 ? 0 : currentIndex,
          labelBehavior:      NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) => context.go(_tabs[i].path),
          destinations: _tabs.map((t) => NavigationDestination(
            icon:          Icon(t.icon, color: AppColors.textMuted),
            selectedIcon:  Icon(t.icon, color: AppColors.accent),
            label:         t.label,
          )).toList(),
        ),
      ),
    );
  }
}

class _GlobalSyncBanner extends ConsumerWidget {
  const _GlobalSyncBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncProvider);
    if (!syncState.isLoading) return const SizedBox.shrink();

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: AppColors.border, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const _SyncIcon(),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  syncState.message ?? 'Sincronizando...',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(syncState.progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  color: AppColors.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                constraints: const BoxConstraints(),
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.cancel_rounded,
                  color: AppColors.textMuted,
                  size: 20,
                ),
                onPressed: () => ref.read(syncProvider.notifier).cancelSync(),
                tooltip: 'Cancelar sincronização',
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: syncState.progress > 0 ? syncState.progress : null,
              backgroundColor: Colors.white10,
              color: AppColors.accent,
              minHeight: 4,
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncIcon extends StatefulWidget {
  const _SyncIcon();
  @override
  State<_SyncIcon> createState() => _SyncIconState();
}

class _SyncIconState extends State<_SyncIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(Icons.sync_rounded, color: AppColors.accent, size: 20),
    );
  }
}

class _NavTab {
  final IconData icon;
  final String   label;
  final String   path;
  const _NavTab({required this.icon, required this.label, required this.path});
}
