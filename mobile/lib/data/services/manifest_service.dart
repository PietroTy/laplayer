import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/file_utils.dart';

import '../../core/constants.dart';
import '../database/database.dart';
import '../models/playlist.dart';
import '../models/track.dart';

/// Serviço de backup/recuperação de metadados via manifest.json no diretório de música.
/// O arquivo sobrevive à desinstalação do app por ficar no armazenamento externo.
class ManifestService {
  ManifestService._();
  static final instance = ManifestService._();

  static const _filename = 'manifest.json';
  static const _currentVersion = 2;

  Timer? _debounceTimer;

  // ── Export ────────────────────────────────────────────────────────────────

  /// Salva o manifesto imediatamente. Use [scheduleSave] para debounce automático.
  Future<File?> saveNow() async {
    try {
      final musicDir = await AppConstants.getMusicDirectory();
      final file = File(p.join(musicDir, _filename));

      final db = AppDatabase.instance;
      final playlists = await db.getPlaylists();
      final allTracks = <Track>[];
      for (final pl in playlists) {
        final tracks = await db.getTracksForPlaylist(pl.id);
        allTracks.addAll(tracks);
      }

      final prefs = await SharedPreferences.getInstance();
      final manifest = {
        'version': _currentVersion,
        'exported_at': DateTime.now().toIso8601String(),
        'playlists': playlists.map((pl) => pl.toJson()).toList(),
        'tracks': allTracks.map((t) => t.toJson()).toList(),
        'settings': {
          'access_key': prefs.getString('access_key') ?? '',
          'server_url': prefs.getString('server_url') ?? '',
          'download_audio_format': prefs.getString('download_audio_format') ?? 'm4a',
          'download_audio_quality': prefs.getString('download_audio_quality') ?? 'high',
        },
      };

      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest),
        flush: true,
      );
      print('[ManifestService] Manifesto salvo: ${file.path} (${allTracks.length} tracks)');
      return file;
    } catch (e) {
      print('[ManifestService] Erro ao salvar manifesto: $e');
      return null;
    }
  }

  /// Agenda um save com debounce de 5s para não bloquear downloads em sequência.
  void scheduleSave() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 5), () {
      saveNow();
    });
  }

  // ── Import / Recovery ──────────────────────────────────────────────────────

  /// Lê um manifest.json de [directoryPath] e reimporta os dados no banco.
  /// Retorna um resumo do resultado.
  Future<RecoveryResult> recoverFromDirectory(String directoryPath) async {
    final manifestFile = File(p.join(directoryPath, _filename));
    if (!await manifestFile.exists()) {
      throw Exception('Nenhum arquivo manifest.json encontrado em:\n$directoryPath');
    }

    final raw = await manifestFile.readAsString();
    final Map<String, dynamic> data = json.decode(raw);

    final version = data['version'] as int? ?? 1;
    print('[ManifestService] Lendo manifesto v$version de $directoryPath');

    // 1. Upsert playlists
    final playlistsJson = data['playlists'] as List? ?? [];
    final playlists = playlistsJson
        .map((j) => Playlist.fromJson(j as Map<String, dynamic>))
        .toList();

    for (final pl in playlists) {
      await AppDatabase.instance.upsertPlaylist(pl);
    }

    // 2. Upsert tracks com status pending (serão revalidados)
    final tracksJson = data['tracks'] as List? ?? [];
    final tracks = tracksJson
        .map((j) => Track.fromJson(j as Map<String, dynamic>).copyWith(
              isCached: false,       // Vai revalidar via disco
              downloadStatus: 'pending',
            ))
        .toList();

    if (tracks.isNotEmpty) {
      await AppDatabase.instance.upsertTracks(tracks);
    }

    // 3. Revalida quais arquivos existem fisicamente no diretório
    //    (inline, sem precisar de SyncService/Ref)
    int revalidated = 0;

    final rootDir = Directory(directoryPath);
    final Map<String, String> filenameToPath = {};
    if (await rootDir.exists()) {
      try {
        final entities = await rootDir.list().toList();
        for (final entity in entities) {
          if (entity is File) {
            final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
            if (FileUtils.audioExtensions.contains(ext) && entity.lengthSync() > 1024) {
              filenameToPath[p.basename(entity.path).toLowerCase()] = entity.path;
            }
          }
        }
      } catch (_) {}
    }

    // Tenta vincular cada track a um arquivo local
    for (final track in tracks) {
      String? matchedPath;

      // 1. Pelo localFilename
      if (track.localFilename != null && track.localFilename!.isNotEmpty) {
        final key = track.localFilename!.toLowerCase();
        if (filenameToPath.containsKey(key)) {
          matchedPath = filenameToPath[key];
        }
      }

      // 2. Fallback: "Artist - Title" com qualquer extensão
      if (matchedPath == null) {
        final baseName = '${FileUtils.sanitizeFilename(track.artist)} - ${FileUtils.sanitizeFilename(track.title)}';
        for (final ext in FileUtils.audioExtensions) {
          final key = '$baseName.$ext'.toLowerCase();
          if (filenameToPath.containsKey(key)) {
            matchedPath = filenameToPath[key];
            break;
          }
        }
      }

      // 3. Último recurso: qualquer arquivo com o título no nome
      if (matchedPath == null) {
        final titleLower = track.title.toLowerCase();
        for (final fileEntry in filenameToPath.entries) {
          if (fileEntry.key.contains(titleLower)) {
            matchedPath = fileEntry.value;
            break;
          }
        }
      }

      if (matchedPath != null) {
        await AppDatabase.instance.markCached(track.id, true);
        revalidated++;
      }
    }

    // 4. Atualiza o diretório de música nas prefs
    await AppConstants.setMusicDirectory(directoryPath);

    // 5. Restaura as configurações se presentes no manifest
    if (data.containsKey('settings')) {
      final settings = data['settings'] as Map<String, dynamic>?;
      if (settings != null) {
        final prefs = await SharedPreferences.getInstance();
        if (settings.containsKey('access_key')) {
          await prefs.setString('access_key', settings['access_key'] as String? ?? '');
        }
        if (settings.containsKey('server_url')) {
          await prefs.setString('server_url', settings['server_url'] as String? ?? '');
        }
        if (settings.containsKey('download_audio_format')) {
          await prefs.setString('download_audio_format', settings['download_audio_format'] as String? ?? 'm4a');
        }
        if (settings.containsKey('download_audio_quality')) {
          await prefs.setString('download_audio_quality', settings['download_audio_quality'] as String? ?? 'high');
        }
        if (settings.containsKey('theme_palette_index')) {
          await prefs.setInt('theme_palette_index', settings['theme_palette_index'] as int? ?? 0);
        }
        if (settings.containsKey('tts_announcer_enabled')) {
          await prefs.setBool('tts_announcer_enabled', settings['tts_announcer_enabled'] as bool? ?? false);
        }
        if (settings.containsKey('tts_announcer_pitch')) {
          await prefs.setDouble('tts_announcer_pitch', (settings['tts_announcer_pitch'] as num?)?.toDouble() ?? 1.5);
        }
        if (settings.containsKey('tts_announcer_rate')) {
          await prefs.setDouble('tts_announcer_rate', (settings['tts_announcer_rate'] as num?)?.toDouble() ?? 0.55);
        }
        print('[ManifestService] Configurações e tema restaurados com sucesso.');
      }
    }

    return RecoveryResult(
      playlistsImported: playlists.length,
      tracksImported: tracks.length,
      tracksFound: revalidated,
      exportedAt: data['exported_at'] as String? ?? '',
    );
  }

  /// Clona tudo (playlists, banco, preferências, músicas e letras) para um diretório escolhido.
  Future<BackupExportResult> exportFullBackup(String targetDirectoryPath, {Function(String status, double progress)? onProgress}) async {
    final targetDir = Directory(targetDirectoryPath);
    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    final db = AppDatabase.instance;
    final playlists = await db.getPlaylists();
    final allTracks = <Track>[];
    for (final pl in playlists) {
      final tracks = await db.getTracksForPlaylist(pl.id);
      allTracks.addAll(tracks);
    }

    final prefs = await SharedPreferences.getInstance();
    final settingsMap = {
      'access_key': prefs.getString('access_key') ?? '',
      'server_url': prefs.getString('server_url') ?? '',
      'download_audio_format': prefs.getString('download_audio_format') ?? 'm4a',
      'download_audio_quality': prefs.getString('download_audio_quality') ?? 'high',
      'theme_palette_index': prefs.getInt('theme_palette_index') ?? 0,
      'tts_announcer_enabled': prefs.getBool('tts_announcer_enabled') ?? false,
      'tts_announcer_pitch': prefs.getDouble('tts_announcer_pitch') ?? 1.5,
      'tts_announcer_rate': prefs.getDouble('tts_announcer_rate') ?? 0.55,
    };

    // Copia arquivos de música e letras da pasta atual de música para o targetDir
    final srcMusicDir = await AppConstants.getMusicDirectory();
    final srcDir = Directory(srcMusicDir);
    int copiedFiles = 0;

    if (await srcDir.exists() && srcMusicDir != targetDirectoryPath) {
      try {
        final list = await srcDir.list().toList();
        final filesToCopy = list.whereType<File>().toList();
        int count = 0;

        for (final entity in filesToCopy) {
          count++;
          onProgress?.call('Copiando arquivos ($count/${filesToCopy.length})...', count / (filesToCopy.isEmpty ? 1 : filesToCopy.length));
          final ext = p.extension(entity.path).toLowerCase().replaceFirst('.', '');
          if (FileUtils.audioExtensions.contains(ext) || ext == 'lrc' || ext == 'json') {
            final destPath = p.join(targetDirectoryPath, p.basename(entity.path));
            if (entity.path != destPath) {
              await entity.copy(destPath);
              copiedFiles++;
            }
          }
        }
      } catch (e) {
        print('[ManifestService] Erro ao copiar arquivos de áudio: $e');
      }
    }

    final manifest = {
      'version': _currentVersion,
      'exported_at': DateTime.now().toIso8601String(),
      'playlists': playlists.map((pl) => pl.toJson()).toList(),
      'tracks': allTracks.map((t) => t.toJson()).toList(),
      'settings': settingsMap,
    };

    final manifestFile = File(p.join(targetDirectoryPath, _filename));
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
      flush: true,
    );

    return BackupExportResult(
      manifestPath: manifestFile.path,
      playlistCount: playlists.length,
      trackCount: allTracks.length,
      copiedFiles: copiedFiles,
    );
  }

  /// Verifica se um diretório tem manifesto válido (para preview antes de recuperar).
  Future<ManifestPreview?> previewManifest(String directoryPath) async {
    try {
      final file = File(p.join(directoryPath, _filename));
      if (!await file.exists()) return null;
      final data = json.decode(await file.readAsString()) as Map<String, dynamic>;
      return ManifestPreview(
        exportedAt: data['exported_at'] as String? ?? '',
        playlistCount: (data['playlists'] as List? ?? []).length,
        trackCount: (data['tracks'] as List? ?? []).length,
        version: data['version'] as int? ?? 1,
      );
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _debounceTimer?.cancel();
  }
}

class RecoveryResult {
  final int playlistsImported;
  final int tracksImported;
  final int tracksFound; // quantos arquivos foram encontrados no disco
  final String exportedAt;

  const RecoveryResult({
    required this.playlistsImported,
    required this.tracksImported,
    required this.tracksFound,
    required this.exportedAt,
  });
}

class BackupExportResult {
  final String manifestPath;
  final int playlistCount;
  final int trackCount;
  final int copiedFiles;

  const BackupExportResult({
    required this.manifestPath,
    required this.playlistCount,
    required this.trackCount,
    required this.copiedFiles,
  });
}

class ManifestPreview {
  final String exportedAt;
  final int playlistCount;
  final int trackCount;
  final int version;

  const ManifestPreview({
    required this.exportedAt,
    required this.playlistCount,
    required this.trackCount,
    required this.version,
  });
}


