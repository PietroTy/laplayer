import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/add_playlist_screen.dart';
import '../screens/artist_screen.dart';
import '../screens/home_screen.dart';
import '../screens/library_screen.dart';
import '../screens/player_screen.dart';
import '../screens/playlist_screen.dart';
import '../screens/search_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/widgets/scaffold_with_nav.dart';

/// Configuração de rotas do Localify
class AppRouter {
  static final _rootNavigatorKey = GlobalKey<NavigatorState>();
  static final _shellNavigatorKey = GlobalKey<NavigatorState>();

  static final router = GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/home',
    routes: [
      // ── Shell com bottom nav ────────────────────────────────────────────
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => ScaffoldWithNav(child: child),
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: HomeScreen(),
            ),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: SearchScreen(),
            ),
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: LibraryScreen(),
            ),
            routes: [
              GoRoute(
                path: 'playlist/:id',
                builder: (context, state) {
                  final id   = state.pathParameters['id']!;
                  final name = state.uri.queryParameters['name'] ?? id;
                  final highlightTrackId = state.uri.queryParameters['highlightTrackId'];
                  return PlaylistScreen(
                    playlistId: id,
                    playlistName: name,
                    highlightTrackId: highlightTrackId,
                  );
                },
              ),
            ],
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => const NoTransitionPage(
              child: SettingsScreen(),
            ),
          ),
          GoRoute(
            path: '/artist/:name',
            builder: (context, state) {
              final name = Uri.decodeComponent(state.pathParameters['name']!);
              return ArtistScreen(artistName: name);
            },
          ),
          GoRoute(
            path: '/add-playlist',
            builder: (context, state) => const AddPlaylistScreen(),
          ),
        ],
      ),

      // ── Player (fullscreen, sem bottom nav) ───────────────────────────
      GoRoute(
        path: '/player',
        parentNavigatorKey: _rootNavigatorKey,
        pageBuilder: (context, state) => CustomTransitionPage(
          child: const PlayerScreen(),
          transitionsBuilder: (context, animation, _, child) => SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
      ),
    ],
  );
}
