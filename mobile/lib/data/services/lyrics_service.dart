import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../models/track.dart';

/// Uma linha de letra com timestamp opcional (para letras sincronizadas).
class LyricsLine {
  final Duration? timestamp;
  final String text;

  const LyricsLine({this.timestamp, required this.text});
}

/// Resultado da busca de letras.
class LyricsResult {
  final List<LyricsLine> lines;
  final bool isSynced;
  final String rawText;

  const LyricsResult({
    required this.lines,
    required this.isSynced,
    required this.rawText,
  });

  bool get isEmpty => lines.isEmpty;
}

/// Serviço de letras com cache offline.
/// Busca letras sincronizadas (LRC) ou plain text do LrcLib.net
/// e salva localmente ao lado do arquivo de áudio (.lrc).
class LyricsService {
  static final LyricsService instance = LyricsService._();
  LyricsService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
    headers: {
      'User-Agent': 'la_player/1.0.0 (https://github.com/la_player)',
    },
  ));

  // Cache em memória para a sessão atual
  final Map<String, LyricsResult> _memCache = {};

  /// Busca letras para uma track.
  /// 1. Verifica cache em memória
  /// 2. Verifica arquivo .lrc local (offline)
  /// 3. Busca no LrcLib.net (online)
  /// 4. Salva localmente para uso offline
  Future<LyricsResult?> getLyrics(Track track) async {
    final cacheKey = '${track.artist}::${track.title}';

    // 1. Cache em memória
    if (_memCache.containsKey(cacheKey)) {
      return _memCache[cacheKey];
    }

    // 2. Arquivo local (.lrc)
    final localResult = await _loadFromLocal(track);
    if (localResult != null) {
      _memCache[cacheKey] = localResult;
      return localResult;
    }

    // 3. Busca online no LrcLib
    final onlineResult = await _fetchFromLrcLib(track);
    if (onlineResult != null) {
      _memCache[cacheKey] = onlineResult;
      // 4. Salva localmente para offline
      await _saveToLocal(track, onlineResult);
      return onlineResult;
    }

    return null;
  }

  /// Busca e salva letras sem retornar (usado durante download de áudio).
  Future<void> prefetchAndSave(Track track) async {
    try {
      final existing = await _loadFromLocal(track);
      if (existing != null) return; // Já tem cache local

      final result = await _fetchFromLrcLib(track);
      if (result != null) {
        await _saveToLocal(track, result);
      }
    } catch (_) {
      // Silencioso — letras são opcionais
    }
  }

  /// Limpa o cache em memória.
  void clearMemoryCache() => _memCache.clear();

  // ── Arquivo Local ───────────────────────────────────────────────────────

  Future<LyricsResult?> _loadFromLocal(Track track) async {
    try {
      final lrcPath = await _lrcPathForTrack(track);
      if (lrcPath == null) return null;

      final file = File(lrcPath);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;

      return _parseLrcContent(content);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveToLocal(Track track, LyricsResult result) async {
    try {
      final lrcPath = await _lrcPathForTrack(track);
      if (lrcPath == null) return;

      final file = File(lrcPath);
      await file.writeAsString(result.rawText);
    } catch (_) {
      // Silencioso
    }
  }

  /// Retorna o caminho do arquivo .lrc correspondente ao áudio da track.
  Future<String?> _lrcPathForTrack(Track track) async {
    final musicDirRoot = await AppConstants.getMusicDirectory();
    final musicDir = p.join(musicDirRoot, track.playlistId);

    final sanitize = (String s) =>
        s.replaceAll(RegExp(r'[<>:"/\\|?*]'), '');
    final baseName =
        '${sanitize(track.artist)} - ${sanitize(track.title)}';

    return p.join(musicDir, '$baseName.lrc');
  }

  // ── LrcLib API ──────────────────────────────────────────────────────────

  Future<LyricsResult?> _fetchFromLrcLib(Track track) async {
    try {
      // Tenta busca exata primeiro
      final result = await _tryLrcLibGet(track);
      if (result != null) return result;

      // Fallback: busca por search
      return await _tryLrcLibSearch(track);
    } catch (_) {
      return null;
    }
  }

  Future<LyricsResult?> _tryLrcLibGet(Track track) async {
    try {
      final durationSecs =
          track.durationMs > 0 ? (track.durationMs / 1000).round() : null;

      final queryParams = <String, dynamic>{
        'artist_name': track.primaryArtist.isNotEmpty
            ? track.primaryArtist
            : track.artist,
        'track_name': track.title,
        if (durationSecs != null) 'duration': durationSecs,
      };

      final response = await _dio.get(
        'https://lrclib.net/api/get',
        queryParameters: queryParams,
      );

      if (response.statusCode == 200 && response.data != null) {
        return _parseApiResponse(response.data);
      }
    } on DioException {
      // 404 ou timeout — tenta search
    }
    return null;
  }

  Future<LyricsResult?> _tryLrcLibSearch(Track track) async {
    try {
      final response = await _dio.get(
        'https://lrclib.net/api/search',
        queryParameters: {
          'q': '${track.artist} ${track.title}',
        },
      );

      if (response.statusCode == 200 && response.data is List) {
        final results = response.data as List;
        if (results.isEmpty) return null;

        // Pega o primeiro resultado (melhor match)
        return _parseApiResponse(results.first);
      }
    } on DioException {
      // Sem conexão ou erro — retorna null
    }
    return null;
  }

  LyricsResult? _parseApiResponse(Map<String, dynamic> data) {
    final synced = data['syncedLyrics'] as String?;
    final plain = data['plainLyrics'] as String?;

    if (synced != null && synced.trim().isNotEmpty) {
      return _parseLrcContent(synced);
    }

    if (plain != null && plain.trim().isNotEmpty) {
      final lines = plain
          .split('\n')
          .map((line) => LyricsLine(text: line))
          .toList();
      return LyricsResult(
        lines: lines,
        isSynced: false,
        rawText: plain,
      );
    }

    return null;
  }

  // ── Parser LRC ──────────────────────────────────────────────────────────

  /// Parseia conteúdo LRC no formato [mm:ss.xx] Texto
  LyricsResult _parseLrcContent(String content) {
    final lines = <LyricsLine>[];
    bool hasTimes = false;

    for (final rawLine in content.split('\n')) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) continue;

      // Tenta extrair timestamp [mm:ss.xx]
      final match = RegExp(r'^\[(\d+):(\d+)\.(\d+)\]\s*(.*)$')
          .firstMatch(trimmed);

      if (match != null) {
        hasTimes = true;
        final min = int.parse(match.group(1)!);
        final sec = int.parse(match.group(2)!);
        final centiseconds = int.parse(
          match.group(3)!.padRight(2, '0').substring(0, 2),
        );
        final text = match.group(4) ?? '';

        lines.add(LyricsLine(
          timestamp: Duration(
            minutes: min,
            seconds: sec,
            milliseconds: centiseconds * 10,
          ),
          text: text,
        ));
      } else if (!trimmed.startsWith('[')) {
        // Linha de texto plano (ignora metadados como [ar:...])
        lines.add(LyricsLine(text: trimmed));
      }
    }

    return LyricsResult(
      lines: lines,
      isSynced: hasTimes,
      rawText: content,
    );
  }
}
