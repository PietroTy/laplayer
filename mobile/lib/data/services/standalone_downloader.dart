import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import 'native_downloader_service.dart';

class StandaloneDownloader {
  // Singleton
  static final StandaloneDownloader _instance = StandaloneDownloader._internal();
  factory StandaloneDownloader() => _instance;
  StandaloneDownloader._internal();

  final NativeDownloaderService _nativeService = NativeDownloaderService();
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15), // 15s timeout for mobile connections
    receiveTimeout: const Duration(seconds: 180), // 3 min receive timeout for server audio conversion
  ));

  /// URL de servidor backend que respondeu com sucesso recentemente
  String? _cachedWorkingServerUrl;

  /// Não requer mais autenticação prévia
  Future<String> authenticateSpotify(Function(String) onUrlReady) async => '';
  Future<bool> checkAuth() async => true;
  Future<bool> saveCredentials(String jsonContent) async => true;

  /// Sanitiza o nome do arquivo para gravação em disco
  String _sanitizeFilename(String filename) {
    return filename
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Tenta baixar a faixa usando o servidor backend (FastAPI + yt-dlp)
  Future<File?> _downloadViaServer({
    required String baseUrl,
    required String accessKey,
    required String title,
    required String artist,
    required String album,
    required String? imageUrl,
    required String targetPath,
    int? durationMs,
    String format = 'm4a',
    String quality = 'high',
    required Function(String status, double percentage) onProgress,
  }) async {
    final cleanUrl = baseUrl.trim().replaceAll(RegExp(r'/$'), '');
    final endpoint = '$cleanUrl/api/download';

    debugPrint('[StandaloneDownloader] Conectando ao backend server: $endpoint');
    onProgress('Solicitando ao servidor Vitals ($artist - $title)...', 0.1);

    try {
      final response = await _dio.post(
        endpoint,
        data: {
          'title': title,
          'artist': artist,
          'album': album,
          'imageUrl': imageUrl,
          'duration_ms': durationMs ?? 0,
          'audio_format': format,
          'audio_quality': quality,
        },
        options: Options(
          headers: {
            'X-Access-Key': accessKey.isNotEmpty ? accessKey : 'LAPLAYER-VIP-8812',
          },
          responseType: ResponseType.bytes,
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final pct = 0.2 + (0.75 * (received / total));
            onProgress(
              'Baixando do servidor (${(received / (1024 * 1024)).toStringAsFixed(1)} / ${(total / (1024 * 1024)).toStringAsFixed(1)} MB)...',
              pct,
            );
          } else {
            onProgress('Processando e convertendo áudio no servidor...', 0.3);
          }
        },
      );

      if (response.statusCode == 200 && response.data != null) {
        final bytes = response.data as List<int>;
        if (bytes.length > 10000) {
          final file = File(targetPath);
          if (file.existsSync()) {
            try { file.deleteSync(); } catch (_) {}
          }
          await file.writeAsBytes(bytes, flush: true);
          onProgress('Concluído via Servidor!', 1.0);
          debugPrint('[StandaloneDownloader] SUCESSO via Servidor ($cleanUrl): ${file.path} (${(bytes.length / (1024 * 1024)).toStringAsFixed(2)} MB)');
          return file;
        }
      }
    } catch (e) {
      debugPrint('[StandaloneDownloader] Servidor $endpoint indisponível ou erro: $e');
    }
    return null;
  }

  /// Baixa a faixa via servidor backend do Vitals (prioritário)
  Future<File?> downloadTrack({
    required String title,
    required String artist,
    required String album,
    required String? imageUrl,
    required String playlistId,
    required String trackId,
    required Function(String status, double percentage) onProgress,
    int? durationMs,
    String? year,
    int? trackNumber,
  }) async {
    debugPrint('[StandaloneDownloader] Iniciando download do servidor: $artist - $title');

    try {
      onProgress("Preparando armazenamento local...", 0.05);
      final musicDirRoot = await AppConstants.getMusicDirectory();
      
      final targetFolder = Directory(musicDirRoot);
      if (!targetFolder.existsSync()) {
        targetFolder.createSync(recursive: true);
      }

      final prefs = await SharedPreferences.getInstance();
      final serverUrl = prefs.getString('server_url') ?? '';
      final accessKey = prefs.getString('access_key') ?? 'LAPLAYER-VIP-8812';
      final formatStr = prefs.getString('download_audio_format') ?? 'm4a';
      final qualityStr = prefs.getString('download_audio_quality') ?? 'high';

      final sanitizedFilename = _sanitizeFilename('$artist - $title.$formatStr');
      final targetPath = p.join(targetFolder.path, sanitizedFilename);

      // ── SERVIDOR BACKEND (Prioridade Absoluta) ─────────────────────────────
      final candidateServerUrls = <String>[];
      const fixedProdUrl = 'https://laplayer-api.magiktarot.com.br';
      candidateServerUrls.add(fixedProdUrl);

      if (_cachedWorkingServerUrl != null && !candidateServerUrls.contains(_cachedWorkingServerUrl)) {
        candidateServerUrls.add(_cachedWorkingServerUrl!);
      }
      if (serverUrl.isNotEmpty && !candidateServerUrls.contains(serverUrl)) {
        candidateServerUrls.add(serverUrl);
      }
      if (!candidateServerUrls.contains('http://10.0.2.2:3004')) {
        candidateServerUrls.add('http://10.0.2.2:3004'); // Emulador Android
      }
      if (!candidateServerUrls.contains('http://127.0.0.1:3004')) {
        candidateServerUrls.add('http://127.0.0.1:3004'); // PC Local
      }

      for (final sUrl in candidateServerUrls) {
        final serverFile = await _downloadViaServer(
          baseUrl: sUrl,
          accessKey: accessKey,
          title: title,
          artist: artist,
          album: album,
          imageUrl: imageUrl,
          targetPath: targetPath,
          durationMs: durationMs,
          format: formatStr,
          quality: qualityStr,
          onProgress: onProgress,
        );

        if (serverFile != null && serverFile.existsSync()) {
          _cachedWorkingServerUrl = sUrl;
          return serverFile;
        }
      }

      // ── DOWNLOAD NATIVO (Apenas se o servidor estiver completamente offline) ────────────────
      debugPrint('[StandaloneDownloader] Servidor indisponível. Recorrendo ao engine nativo...');
      AudioQualityPreset qualityPreset;
      switch (qualityStr.toLowerCase()) {
        case 'normal':
        case 'low':
          qualityPreset = AudioQualityPreset.normal;
          break;
        case 'high':
          qualityPreset = AudioQualityPreset.high;
          break;
        case 'very_high':
        default:
          qualityPreset = AudioQualityPreset.veryHigh;
          break;
      }

      final downloadedFile = await _nativeService.downloadTrack(
        trackTitle: title,
        artistName: artist,
        albumName: album,
        targetDirectory: targetFolder.path,
        coverUrl: imageUrl,
        durationMs: durationMs,
        year: year,
        trackNumber: trackNumber,
        qualityPreset: qualityPreset,
        onProgress: (progress, status) {
          onProgress(status, progress);
        },
      );

      if (downloadedFile == null || !downloadedFile.existsSync()) {
        throw Exception("Falha ao salvar o arquivo baixado.");
      }

      onProgress("Concluído!", 1.0);
      debugPrint('[StandaloneDownloader] Sucesso! Baixado em: ${downloadedFile.path}');
      return downloadedFile;

    } catch (e) {
      debugPrint('[StandaloneDownloader] Erro ao baixar faixa: $e');
      
      try {
        final musicDirRoot = await AppConstants.getMusicDirectory();
        final errorFile = File('$musicDirRoot/error_log.txt');
        errorFile.writeAsStringSync('${DateTime.now()}: $title - $e\n', mode: FileMode.append);
      } catch (_) {}

      onProgress("Erro: $e", 0.0);
      rethrow;
    }
  }

  Future<void> closeSession() async {}
  void dispose() {}
}
