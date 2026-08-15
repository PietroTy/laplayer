import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serviço de Text-To-Speech (TTS) offline para anúncio de músicas com voz de robô/Vocaloid.
class TtsAnnouncerService {
  TtsAnnouncerService._();
  static final instance = TtsAnnouncerService._();

  FlutterTts? _tts;
  bool _initialized = false;
  bool _isEnabled = false;
  bool _isAborted = false;
  double _pitch = 1.5; // Pitch elevado para som robótico / Vocaloid
  double _speechRate = 0.55; // Velocidade ligeiramente acelerada

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    _tts = FlutterTts();
    await _loadSettings();

    try {
      await _tts!.setLanguage("pt-BR");
      await _tts!.setPitch(_pitch);
      await _tts!.setSpeechRate(_speechRate);
      await _tts!.setVolume(1.0);
      // Garante modo offline / fala síncrona
      await _tts!.awaitSpeakCompletion(true);
    } catch (e) {
      print('[TtsAnnouncerService] Erro ao inicializar TTS: $e');
    }
  }

  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isEnabled = prefs.getBool('tts_announcer_enabled') ?? false;
      _pitch = prefs.getDouble('tts_announcer_pitch') ?? 1.5;
      _speechRate = prefs.getDouble('tts_announcer_rate') ?? 0.55;
    } catch (_) {}
  }

  bool get isEnabled => _isEnabled;

  Future<void> setEnabled(bool enabled) async {
    _isEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tts_announcer_enabled', enabled);
  }

  Future<void> setPitch(double pitch) async {
    _pitch = pitch;
    await _tts?.setPitch(pitch);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('tts_announcer_pitch', pitch);
  }

  /// Anuncia a música antes da reprodução se a opção estiver ativada
  Future<void> announceTrack({required String title, required String artist}) async {
    _isAborted = false;
    await init();
    if (!_isEnabled || _isAborted) return;

    try {
      // Remove emojis e caracteres super estranhos para garantir que o TTS não engasgue
      // O \w do Dart padrão não pega acentos a menos que usemos unicode, então é melhor
      // apenas fazer um filtro básico para não quebrar a string.
      final safeTitle = title.replaceAll(RegExp(r'[^\p{L}\p{N}\s\-_.,!]', unicode: true), '').trim();
      final safeArtist = artist.replaceAll(RegExp(r'[^\p{L}\p{N}\s\-_.,!]', unicode: true), '').trim();
      
      // Texto limpo e direto para pronúncia robótica ideal
      final textToSpeak = "$safeTitle, de $safeArtist";
      if (_isAborted) return;
      
      print('[TtsAnnouncerService] Anunciando: $textToSpeak');
      await _tts?.speak(textToSpeak).timeout(
        const Duration(seconds: 5),
        onTimeout: () => print('[TtsAnnouncerService] Timeout: Motor TTS demorou demais para responder'),
      );
    } catch (e) {
      print('[TtsAnnouncerService] Falha ao anunciar faixa: $e');
    }
  }

  Future<void> stop() async {
    _isAborted = true;
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}
