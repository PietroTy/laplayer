import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Constantes globais do Localify
abstract class AppConstants {

  // ── Storage keys (SharedPreferences) ─────────────────────────────────

  static const keyLastSync     = 'last_sync';
  static const keyCurrentQueue = 'current_queue';
  static const keyLastPosition = 'last_position';

  // ── Player ─────────────────────────────────────────────────────────────
  static const seekForwardSecs  = 10;
  static const seekBackwardSecs = 10;

  // ── Sync ──────────────────────────────────────────────────────────────
  /// Intervalo de sync automático em minutos (0 = desabilitado)
  static const autoSyncIntervalMinutes = 15;

  // ── UI ────────────────────────────────────────────────────────────────
  static const artBorderRadius  = 12.0;
  static const cardBorderRadius = 16.0;
  static const defaultPadding   = 16.0;

  // ── Misc ──────────────────────────────────────────────────────────────
  static const appName    = 'لاplayer';
  static const appVersion = '1.0.0';

  // ── YouTube Cookies (reais - manter repositório PRIVADO!) ────────────────
  static const youtubeCookieTemplate = '''# Netscape HTTP Cookie File
# https://curl.haxx.se/rfc/cookie_spec.html
# This is a generated file! Do not edit.

''';

  /// Retorna o diretório padrão (Documents/music) para salvar músicas e letras.
  static Future<String> getDefaultMusicDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, 'music');
  }

  /// Retorna o diretório configurado pelo usuário para baixar e salvar músicas e letras,
  /// ou o diretório padrão (Documents/music) se não houver um personalizado.
  static Future<String> getMusicDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final customPath = prefs.getString('custom_music_directory') ?? '';
    if (customPath.trim().isNotEmpty) {
      return customPath.trim();
    }
    return getDefaultMusicDirectory();
  }

  /// Atualiza o diretório de música configurado pelo usuário.
  static Future<void> setMusicDirectory(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_music_directory', path);
  }
}

