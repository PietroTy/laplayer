import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants.dart';

class ServerDownloader {
  Future<File?> downloadTrack({
    required String title,
    required String artist,
    required String album,
    required String? imageUrl,
    required String playlistId,
    required String trackId,
    int? durationMs,
    int? skipMatch,
    required Function(String status, double percentage) onProgress,
  }) async {
    onProgress("Solicitando ao servidor...", 0.1);

    const githubRepo = 'PietroTy/laplayer';

    try {
      final prefs = await SharedPreferences.getInstance();

      // ── 1. Método principal: GitHub auto-discovery ──────────────────────
      onProgress("Localizando servidor via GitHub...", 0.05);
      try {
        final tempDio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));
        final rawUrl = "https://raw.githubusercontent.com/$githubRepo/main/server_url.txt";
        final response = await tempDio.get(rawUrl);
        if (response.statusCode == 200 && response.data != null) {
          final fetchedUrl = response.data.toString().trim();
          if (fetchedUrl.startsWith("http")) {
            await prefs.setString('server_url', fetchedUrl);
            print("[ServerDownloader] URL atualizada via GitHub: $fetchedUrl");
          }
        }
      } catch (e) {
        print("[ServerDownloader] GitHub indisponível, usando URL em cache: $e");
      }

      // ── 2. Método fallback: URL manual / cache ──────────────────────────
      var serverUrl = prefs.getString('server_url')?.trim() ?? '';

      if (serverUrl.isEmpty) {
        throw Exception(
          'Servidor temporariamente indisponível.\n'
          'Verifique se o servidor está rodando e tente novamente.',
        );
      }

      // Auto-completa a rota /api/download se não estiver presente
      if (!serverUrl.contains('/api/download')) {
        serverUrl = serverUrl.endsWith('/')
            ? '${serverUrl}api/download'
            : '$serverUrl/api/download';
      }
      print("[ServerDownloader] Conectando ao servidor: $serverUrl");

      final dio = Dio();
      
      final tempDir = await getTemporaryDirectory();
      final tempFilePath = p.join(tempDir.path, "temp_${DateTime.now().millisecondsSinceEpoch}.m4a");
      
      double lastProgress = 0.1;

      await dio.download(
        serverUrl,
        tempFilePath,
        data: {
          'title': title,
          'artist': artist,
          'album': album,
          'imageUrl': imageUrl,
          'duration_ms': durationMs ?? 0,
          'skip_match': skipMatch ?? 0,
        },
        options: Options(
          method: 'POST',
          receiveTimeout: const Duration(minutes: 5), // Pode demorar pois o servidor vai processar
        ),
        onReceiveProgress: (received, total) {
          if (total != -1) {
            final progress = 0.1 + (0.8 * (received / total));
            if (progress - lastProgress > 0.05) {
              onProgress("Baixando do servidor (${(progress * 100).toInt()}%)...", progress);
              lastProgress = progress;
            }
          }
        },
      );

      onProgress("Finalizando arquivo...", 0.9);

      final downloadedFile = File(tempFilePath);
      if (!downloadedFile.existsSync()) {
        throw Exception("Arquivo não encontrado após download.");
      }

      final musicDirRoot = await AppConstants.getMusicDirectory();
      final musicDir = Directory(p.join(musicDirRoot, playlistId));
      if (!await musicDir.exists()) {
        await musicDir.create(recursive: true);
      }

      final finalPath = p.join(
        musicDir.path,
        "${_sanitizeFileName(artist)} - ${_sanitizeFileName(title)}.m4a",
      );

      final finalFile = await downloadedFile.copy(finalPath);
      await downloadedFile.delete();

      onProgress("Concluído!", 1.0);
      return finalFile;
    } catch (e) {
      print("[ServerDownloader] Erro: $e");
      onProgress("Falha no download.", 0.0);
      return null;
    }
  }

  String _sanitizeFileName(String name) {
    return name.replaceAll(RegExp(r'[<>:"/\\|?*]'), "");
  }

  void dispose() {}
}
