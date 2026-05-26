import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/theme.dart';
import 'data/database/database.dart';
import 'data/services/audio_handler.dart';
import 'providers/player_provider.dart';

late AudioHandler globalAudioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Orientação portrait-only
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Status bar transparente (visual imersivo)
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0A0A0A),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Inicializa banco de dados
  await AppDatabase.instance.init();

  // Carrega tema salvo ANTES do runApp para evitar flash do tema padrão
  final prefs = await SharedPreferences.getInstance();
  final savedThemeIndex = prefs.getInt('theme_palette_index') ?? 0;
  final savedPalette = AppThemePalette.values[savedThemeIndex];
  // Aplica as cores estáticas imediatamente
  AppColors.bg        = savedPalette.bg;
  AppColors.accent    = savedPalette.accent;
  AppColors.accentDim = savedPalette.accentDim;

  // Registra o AudioHandler para background playback
  globalAudioHandler = await AudioService.init(
    builder: () => LaPlayerAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.laplayer.audio',
      androidNotificationChannelName: 'لاplayer',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      notificationColor: Color(0xFF1DB954),
    ),
  );

  runApp(
    ProviderScope(
      overrides: [
        themePaletteProvider.overrideWith((ref) => ThemePaletteNotifier(savedPalette)),
        audioHandlerProvider.overrideWithValue(globalAudioHandler),
      ],
      child: const LaPlayerApp(),
    ),
  );
}
