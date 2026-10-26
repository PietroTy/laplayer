import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import '../../core/file_utils.dart';
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

    // Uma queda de conexão (ex: o túnel cai no meio da resposta) não pode jogar direto pro
    // download nativo: tenta o servidor de novo. Respostas do servidor (404 não achou, 403) não repetem.
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final response = await _dio.post(
          endpoint,
          data: {
            'title': title,
            'artist': artist,
            'album': album ?? '',
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
        return null;
      } on DioException catch (e) {
        debugPrint('[StandaloneDownloader] Servidor $endpoint falhou (tentativa $attempt): $e');
        final status = e.response?.statusCode;
        final transient = status == null || status >= 500;  // conexão caiu ou servidor/túnel com erro
        if (!transient || attempt == 2) return null;
        onProgress('Conexão com o servidor caiu, tentando de novo...', 0.1);
        await Future.delayed(const Duration(seconds: 2));
      } catch (e) {
        debugPrint('[StandaloneDownloader] Erro ao salvar resposta do servidor: $e');
        return null;
      }
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

      final sanitizedFilename = '${FileUtils.trackBaseName(artist, title)}.$formatStr';
      final targetPath = p.join(targetFolder.path, sanitizedFilename);

      // ── SERVIDOR BACKEND (Prioridade Absoluta) ─────────────────────────────
      // Primeiro o servidor escolhido em Configurações; depois o do PietroTy e o último que funcionou.
      const fixedProdUrl = 'https://laplayer-api.pietroty.com.br';
      final candidateServerUrls = <String>{
        if (serverUrl.trim().isNotEmpty) serverUrl.trim(),
        fixedProdUrl,
        if (_cachedWorkingServerUrl != null) _cachedWorkingServerUrl!,
      }.toList();

      debugPrint('[StandaloneDownloader] Tentando ${candidateServerUrls.length} servidor(es): $candidateServerUrls');

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
