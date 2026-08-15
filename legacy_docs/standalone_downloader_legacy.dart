import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../../core/constants.dart';
import '../database/database.dart';

class StandaloneDownloader {
  static final YoutubeExplode _yt = YoutubeExplode();

  /// Baixa a faixa diretamente do YouTube/Fontes Web sem necessidade de servidor Node.js
  Future<File?> downloadTrack({
    required String title,
    required String artist,
    required String album,
    required String? imageUrl,
    required String playlistId,
    required String trackId,
    String? playlistFolderName,
    int? durationMs,
    String? youtubeUrl,
    required Function(String status, double percentage) onProgress,
  }) async {
    onProgress("Buscando faixa no YouTube...", 0.1);
    print('[StandaloneDownloader] Iniciando busca standalone: $artist - $title');

    try {
      Video? video;

      if (youtubeUrl != null && youtubeUrl.isNotEmpty) {
        onProgress("Carregando URL informada...", 0.2);
        try {
          video = await _yt.videos.get(youtubeUrl);
        } catch (_) {}
      }

      if (video == null) {
        final query = '$artist - $title audio';
        onProgress("Pesquisando: $query...", 0.25);
        final searchResults = await _yt.search.search(query);
        if (searchResults.isNotEmpty) {
          video = searchResults.first;
        }
      }

      if (video == null) {
        throw Exception('Música não encontrada no YouTube.');
      }

      onProgress("Obtendo stream de áudio...", 0.4);
      final manifest = await _yt.videos.streamsClient.getManifest(video.id);
      final audioStreamInfo = manifest.audioOnly.withHighestBitrate();

      onProgress("Preparando armazenamento local...", 0.5);
      final musicDirRoot = await AppConstants.getMusicDirectory();
      
      String folderName = playlistFolderName ?? playlistId;
      if (playlistFolderName == null || playlistFolderName.isEmpty) {
        try {
          final db = await AppDatabase.instance.db;
          final rows = await db.query(
            'playlists',
            columns: ['name'],
            where: 'id = ?',
            whereArgs: [playlistId],
          );
          if (rows.isNotEmpty) {
            final name = rows.first['name'] as String? ?? '';
            if (name.isNotEmpty) {
              final sanitizeStr = (String s) => s.replaceAll(RegExp(r'[<>:"/\\|?*]'), '').trim();
              final cleanName = sanitizeStr(name);
              if (cleanName.isNotEmpty) folderName = cleanName;
            }
          }
        } catch (_) {}
      }

      final targetFolder = Directory(p.join(musicDirRoot, folderName));
      if (!targetFolder.existsSync()) {
        targetFolder.createSync(recursive: true);
      }

      // Sanitiza nome do arquivo
      final safeTitle = title.replaceAll(RegExp(r'[\\/*?:"<>|]'), '_');
      final safeArtist = artist.replaceAll(RegExp(r'[\\/*?:"<>|]'), '_');
      final ext = audioStreamInfo.container.name;
      final finalFileName = '$safeArtist - $safeTitle.$ext';
      final finalFile = File(p.join(targetFolder.path, finalFileName));

      onProgress("Baixando áudio (0%)...", 0.6);
      final stream = _yt.videos.streamsClient.get(audioStreamInfo);
      final output = finalFile.openWrite();

      final totalBytes = audioStreamInfo.size.totalBytes;
      int downloadedBytes = 0;

      await for (final data in stream) {
        downloadedBytes += data.length;
        output.add(data);
        if (totalBytes > 0) {
          final progress = 0.6 + (0.35 * (downloadedBytes / totalBytes));
          final pct = ((downloadedBytes / totalBytes) * 100).toStringAsFixed(0);
          onProgress("Baixando áudio ($pct%)...", progress.clamp(0.6, 0.95));
        }
      }

      await output.flush();
      await output.close();

      onProgress("Registrando faixa no banco de dados...", 0.98);
      // Busca a track atual para preservar os dados e atualizar o status
      final currentTracks = await AppDatabase.instance.getTracksForPlaylist(playlistId);
      final trackMatch = currentTracks.where((t) => t.id == trackId);
      if (trackMatch.isNotEmpty) {
        await AppDatabase.instance.upsertTracks([
          trackMatch.first.copyWith(
            available: true,
            isCached: true,
            downloadStatus: 'success',
            localFilename: finalFileName,
          )
        ]);
      }

      onProgress("Concluído!", 1.0);
      print('[StandaloneDownloader] Sucesso! Baixado em: ${finalFile.path}');
      return finalFile;

    } catch (e) {
      print('[StandaloneDownloader] Erro ao baixar faixa: $e');
      final currentTracks = await AppDatabase.instance.getTracksForPlaylist(playlistId);
      final trackMatch = currentTracks.where((t) => t.id == trackId);
      if (trackMatch.isNotEmpty) {
        await AppDatabase.instance.upsertTracks([
          trackMatch.first.copyWith(downloadStatus: 'failed')
        ]);
      }
      rethrow;
    }
  }

  void dispose() {
    _yt.close();
  }
}
