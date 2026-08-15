import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'core/router.dart';
import 'core/theme.dart';

class LaPlayerApp extends ConsumerWidget {
  const LaPlayerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(themePaletteProvider);

    return WithForegroundTask(
      child: MaterialApp.router(
        title: 'لاplayer',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(palette),
        routerConfig: AppRouter.router,
      ),
    );
  }
}
