import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:io';
import 'package:path/path.dart' as p;

import 'app.dart';
import 'core/constants.dart';
import 'core/theme.dart';
import 'data/database/database.dart';
import 'data/services/audio_handler.dart';
import 'data/services/tts_announcer_service.dart';
import 'providers/player_provider.dart';

late AudioHandler globalAudioHandler;

class CustomHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
    return client;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = CustomHttpOverrides();

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

  // Inicializa o FlutterForegroundTask (necessário antes de qualquer uso)
  FlutterForegroundTask.initCommunicationPort();

  // Inicializa TTS Service para carregar preferências do usuário
  await TtsAnnouncerService.instance.init();

  // Carrega tema salvo ANTES do runApp para evitar flash do tema padrão
  final prefs = await SharedPreferences.getInstance();

  // Executa migração dos áudios para a nova estrutura raiz de pastas
  if (prefs.getBool('migrated_to_flat_folders') != true) {
    try {
      final musicDirRoot = await AppConstants.getMusicDirectory();
      final rootDir = Directory(musicDirRoot);
      if (await rootDir.exists()) {
        final entities = await rootDir.list().toList();
        for (final entity in entities) {
          if (entity is Directory) {
            final files = await entity.list().toList();
            for (final f in files) {
              if (f is File && (f.path.endsWith('.m4a') || f.path.endsWith('.lrc') || f.path.endsWith('.mp3'))) {
                final newPath = p.join(musicDirRoot, p.basename(f.path));
                try {
                  await f.rename(newPath);
                } catch (_) {
                  // Fallback se rename falhar entre volumes
                  await f.copy(newPath);
                  await f.delete();
                }
              }
            }
            try { await entity.delete(recursive: true); } catch (_) {}
          }
        }
      }
      await prefs.setBool('migrated_to_flat_folders', true);
    } catch (_) {}
  }

  final savedThemeIndex = prefs.getInt('theme_palette_index') ?? 0;
  final savedPalette = AppThemePalette.values[savedThemeIndex];
  // Aplica as cores estáticas imediatamente
  AppColors.bg        = savedPalette.bg;
  AppColors.accent    = savedPalette.accent;
  AppColors.accentDim = savedPalette.accentDim;

  // Registra o AudioHandler para background playback com re-entry seguro de notificação
  try {
    globalAudioHandler = await AudioService.init(
      builder: () => LaPlayerAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.laplayer.audio',
        androidNotificationChannelName: 'لاplayer',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationClickStartsActivity: true,
        notificationColor: Color(0xFF1DB954),
      ),
    );
  } catch (e, stack) {
    print('[Main] Erro ao inicializar AudioService: $e\n$stack');
  }

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
