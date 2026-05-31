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
    String? youtubeUrl,
    required Function(String status, double percentage) onProgress,
  }) async {
    // Lê formato e qualidade das preferências do usuário
    final prefs = await SharedPreferences.getInstance();
    final audioFormat = prefs.getString('download_audio_format') ?? 'm4a';
    final audioQuality = prefs.getString('download_audio_quality') ?? 'high';
    onProgress("Solicitando ao servidor...", 0.1);
    print('[ServerDownloader] Iniciando download: $artist - $title [$audioFormat/$audioQuality]');

    const githubRepo = 'PietroTy/laplayer';

    try {
      // ── 1. Método principal: GitHub auto-discovery ──────────────────────
      onProgress("Localizando servidor via GitHub...", 0.05);
      try {
        final tempDio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final rawUrl = "https://raw.githubusercontent.com/$githubRepo/main/server_url.txt?t=$timestamp";
        final response = await tempDio.get(rawUrl);
        if (response.statusCode == 200 && response.data != null) {
          final fetchedUrl = response.data.toString().replaceAll(RegExp(r'\s+'), '');
          if (fetchedUrl.startsWith("http")) {
            await prefs.setString('server_url', fetchedUrl);
            print("[ServerDownloader] URL atualizada via GitHub: $fetchedUrl");
          }
        }
      } catch (e) {
        print("[ServerDownloader] GitHub indisponível, usando URL em cache: $e");
      }

      // ── 2. Método fallback: URL manual / cache ──────────────────────────
      var serverUrl = prefs.getString('server_url')?.replaceAll(RegExp(r'\s+'), '') ?? '';

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
      // Extensão temporária sem ext ainda — será determinada depois
      final tempBase = p.join(tempDir.path, "temp_${DateTime.now().millisecondsSinceEpoch}");
      final tempFilePath = '$tempBase.tmp';

      double lastProgress = 0.1;

      // Envia formato e qualidade para o servidor
      final requestData = <String, dynamic>{
        'title': title,
        'artist': artist,
        'album': album,
        'imageUrl': imageUrl,
        'duration_ms': durationMs ?? 0,
        'skip_match': skipMatch ?? 0,
        'youtube_url': youtubeUrl,
        'audio_format': audioFormat,
        'audio_quality': audioQuality,
      };

      Response response;
      try {
        response = await dio.download(
          serverUrl,
          tempFilePath,
          data: requestData,
          options: Options(
            method: 'POST',
            receiveTimeout: const Duration(minutes: 8),
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
      } catch (e) {
        // Tenta extrair mensagem de erro do servidor (ex: sem espaço em disco)
        if (e.toString().contains('507') || e.toString().contains('Sem espaço')) {
          throw Exception('Servidor sem espaço em disco. Libere espaço no servidor e tente novamente.');
        }
        rethrow;
      }

      onProgress("Finalizando arquivo...", 0.9);

      final tempFile = File(tempFilePath);
      if (!tempFile.existsSync() || tempFile.lengthSync() < 4096) {
        throw Exception('Arquivo baixado está vazio ou corrompido (${tempFile.existsSync() ? tempFile.lengthSync() : 0} bytes).');
      }

      // Determina a extensão final a partir do Content-Disposition ou pelo formato pedido
      String finalExt = audioFormat;
      final contentDisposition = response.headers.value('content-disposition') ?? '';
      final cdMatch = RegExp(r'\.([a-z0-9]+)["\s]?\s*\\?$', caseSensitive: false)
          .firstMatch(contentDisposition);
      if (cdMatch != null) {
        finalExt = cdMatch.group(1)!.toLowerCase();
      }

      final musicDirRoot = await AppConstants.getMusicDirectory();
      final musicDir = Directory(p.join(musicDirRoot, playlistId));
      if (!await musicDir.exists()) {
        await musicDir.create(recursive: true);
      }

      final finalPath = p.join(
        musicDir.path,
        "${_sanitizeFileName(artist)} - ${_sanitizeFileName(title)}.$finalExt",
      );

      final finalFile = await tempFile.copy(finalPath);
      await tempFile.delete();

      final fileSizeMb = finalFile.lengthSync() / (1024 * 1024);
      print('[ServerDownloader] Arquivo salvo: $finalPath (${fileSizeMb.toStringAsFixed(1)} MB)');

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
