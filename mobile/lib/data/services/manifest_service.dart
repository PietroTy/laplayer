import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../database/database.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import 'sync_service.dart';
import 'spotify_service.dart';
import 'server_downloader.dart';

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

      final manifest = {
        'version': _currentVersion,
        'exported_at': DateTime.now().toIso8601String(),
        'playlists': playlists.map((pl) => pl.toJson()).toList(),
        'tracks': allTracks.map((t) => t.toJson()).toList(),
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
    int revalidated = 0;
    final syncService = SyncService(SpotifyService(), ServerDownloader(), null as dynamic);
    final byPlaylist = <String, List<Track>>{};
    for (final t in tracks) {
      byPlaylist.putIfAbsent(t.playlistId, () => []).add(t);
    }

    for (final entry in byPlaylist.entries) {
      final playlistPath = p.join(directoryPath, entry.key);
      final found = await syncService.findLocalPathsBulk(
        entry.key,
        entry.value,
        overrideMusicDir: directoryPath,
      );
      for (final trackId in found.keys) {
        await AppDatabase.instance.markCached(trackId, true);
        revalidated++;
      }
    }

    // 4. Atualiza o diretório de música nas prefs
    await AppConstants.setMusicDirectory(directoryPath);

    return RecoveryResult(
      playlistsImported: playlists.length,
      tracksImported: tracks.length,
      tracksFound: revalidated,
      exportedAt: data['exported_at'] as String? ?? '',
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
