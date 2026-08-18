import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/album_group.dart';
import '../models/artist_group.dart';
import '../models/track.dart';
import '../models/playlist.dart';

/// Banco de dados SQLite local do Localify.
class AppDatabase {
  AppDatabase._();
  static final instance = AppDatabase._();

  static Database? _db;

  Future<Database> get db async {
    _db ??= await _open();
    return _db!;
  }

  Future<void> init() async {
    await db;
    await resetDownloadingStatus();
  }

  Future<void> resetDownloadingStatus() async {
    final database = await db;
    await database.rawUpdate(
      "UPDATE tracks SET download_status = 'pending' WHERE download_status = 'downloading'"
    );
  }

  static const _version = 5;

  Future<Database> _open() async {
    final dbPath = join(await getDatabasesPath(), 'localify.db');
    return openDatabase(
      dbPath,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE playlists (
        id            TEXT PRIMARY KEY,
        name          TEXT NOT NULL,
        description   TEXT,
        image_url     TEXT,
        spotify_url   TEXT,
        total_tracks  INTEGER DEFAULT 0,
        downloaded    INTEGER DEFAULT 0,
        failed        INTEGER DEFAULT 0,
        path          TEXT,
        snapshot_id   TEXT,
        synced_at     TEXT,
        sync_disabled INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE tracks (
        id                TEXT PRIMARY KEY,
        spotify_uri       TEXT,
        isrc              TEXT,
        playlist_position INTEGER,
        title             TEXT NOT NULL,
        artist            TEXT NOT NULL,
        primary_artist    TEXT,
        album             TEXT,
        album_artist      TEXT,
        album_art_url     TEXT,
        release_year      TEXT,
        genres            TEXT,
        duration_ms       INTEGER DEFAULT 0,
        track_number      INTEGER DEFAULT 1,
        total_tracks      INTEGER DEFAULT 1,
        disc_number       INTEGER DEFAULT 1,
        explicit          INTEGER DEFAULT 0,
        spotify_url       TEXT,
        playlist_id       TEXT NOT NULL,
        local_filename    TEXT,
        download_status   TEXT DEFAULT 'pending',
        available         INTEGER DEFAULT 0,
        is_cached         INTEGER DEFAULT 0,
        FOREIGN KEY (playlist_id) REFERENCES playlists(id)
      )
    ''');

    await db.execute('''
      CREATE TABLE play_history (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        track_id    TEXT NOT NULL,
        played_at   TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE favorites (
        track_id    TEXT PRIMARY KEY,
        added_at    TEXT NOT NULL
      )
    ''');

    await db.execute('CREATE INDEX idx_tracks_playlist ON tracks(playlist_id)');
    await db.execute('CREATE INDEX idx_history_played ON play_history(played_at DESC)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS playlist_tracks (
        playlist_id TEXT NOT NULL,
        track_id    TEXT NOT NULL,
        position    INTEGER NOT NULL,
        PRIMARY KEY (playlist_id, track_id),
        FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
        FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS player_state_persistence (
        id              INTEGER PRIMARY KEY CHECK (id = 1),
        track_id        TEXT,
        position_ms     INTEGER DEFAULT 0,
        queue_track_ids TEXT
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    final columns = [
      'snapshot_id',
      'description',
      'image_url',
      'spotify_url',
      'sync_disabled'
    ];

    for (var col in columns) {
      try {
        if (col == 'sync_disabled') {
          await db.execute('ALTER TABLE playlists ADD COLUMN sync_disabled INTEGER DEFAULT 0');
        } else {
          await db.execute('ALTER TABLE playlists ADD COLUMN $col TEXT');
        }
      } catch (_) {}
    }

    if (oldVersion < 5) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS playlist_tracks (
          playlist_id TEXT NOT NULL,
          track_id    TEXT NOT NULL,
          position    INTEGER NOT NULL,
          PRIMARY KEY (playlist_id, track_id),
          FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE,
          FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS player_state_persistence (
          id              INTEGER PRIMARY KEY CHECK (id = 1),
          track_id        TEXT,
          position_ms     INTEGER DEFAULT 0,
          queue_track_ids TEXT
        )
      ''');

      try {
        await db.execute('''
          INSERT OR IGNORE INTO playlist_tracks (playlist_id, track_id, position)
          SELECT playlist_id, id, playlist_position FROM tracks WHERE playlist_id IS NOT NULL AND playlist_id != ''
        ''');
      } catch (_) {}
    }
  }

  // ── Playlists ─────────────────────────────────────────────────────────

  Future<void> upsertPlaylist(Playlist p) async {
    final database = await db;
    await database.insert(
      'playlists',
      {
        'id':           p.id,
        'name':         p.name,
        'description':  p.description,
        'image_url':    p.imageUrl,
        'spotify_url':  p.spotifyUrl,
        'total_tracks': p.totalTracks,
        'downloaded':   p.downloaded,
        'failed':       p.failed,
        'path':         p.path,
        'snapshot_id':  p.snapshotId,
        'synced_at':    DateTime.now().toIso8601String(),
        'sync_disabled': p.syncDisabled ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Playlist>> getPlaylists() async {
    final database = await db;
    // Busca as playlists e conta quantas músicas estão disponíveis (available = 1) para cada uma,
    // utilizando a tabela de junção playlist_tracks que reflete a estrutura relacional correta.
    final rows = await database.rawQuery('''
      SELECT p.*, 
             (SELECT COUNT(*) FROM playlist_tracks pt 
              INNER JOIN tracks t ON t.id = pt.track_id 
              WHERE pt.playlist_id = p.id AND t.available = 1) as real_downloaded
      FROM playlists p
      ORDER BY p.name ASC
    ''');
    
    return rows.map((row) {
      final p = _rowToPlaylist(row);
      // Sobrescreve o campo downloaded com o valor real contado no banco
      return p.copyWith(downloaded: row['real_downloaded'] as int? ?? 0);
    }).toList();
  }

  Playlist _rowToPlaylist(Map<String, dynamic> row) => Playlist(
    id:          row['id']           ?? '',
    name:        row['name']         ?? '',
    description: row['description']  ?? '',
    imageUrl:    row['image_url']    ?? '',
    spotifyUrl:  row['spotify_url']  ?? '',
    totalTracks: row['total_tracks'] ?? 0,
    downloaded:  row['downloaded']   ?? 0,
    failed:      row['failed']       ?? 0,
    path:        row['path']         ?? '',
    snapshotId:  row['snapshot_id']  ?? '',
    syncDisabled: row['sync_disabled'] == 1,
  );

  Future<void> deletePlaylist(String playlistId) async {
    final database = await db;
    await database.transaction((txn) async {
      // 1. Remove a relação na tabela de junção
      await txn.delete('playlist_tracks', where: 'playlist_id = ?', whereArgs: [playlistId]);
      
      // 2. Tenta remover músicas órfãs (não pertencem a nenhuma playlist)
      await txn.rawDelete('''
        DELETE FROM tracks 
        WHERE id NOT IN (SELECT track_id FROM playlist_tracks)
      ''');

      // 3. Remove a própria playlist
      await txn.delete('playlists', where: 'id = ?', whereArgs: [playlistId]);
    });
  }

  Future<int> getNextPlaylistPosition(String playlistId) async {
    final database = await db;
    final row = await database.rawQuery(
      'SELECT MAX(position) as max_pos FROM playlist_tracks WHERE playlist_id = ?',
      [playlistId],
    );
    if (row.isNotEmpty && row.first['max_pos'] != null) {
      return (row.first['max_pos'] as int) + 1;
    }
    return 0;
  }

  Future<void> updateTrackPositions(String playlistId, List<String> trackIds) async {
    final database = await db;
    await database.transaction((txn) async {
      final batch = txn.batch();
      for (int i = 0; i < trackIds.length; i++) {
        batch.update(
          'playlist_tracks',
          {'position': i},
          where: 'track_id = ? AND playlist_id = ?',
          whereArgs: [trackIds[i], playlistId],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  // ── Tracks ─────────────────────────────────────────────────────────────

  Future<void> upsertTracks(List<Track> tracks) async {
    if (tracks.isEmpty) {
      print('DEBUG Database: upsertTracks chamada com lista vazia');
      return;
    }
    
    final database = await db;
    print('DEBUG Database: Iniciando upsertTracks de ${tracks.length} músicas...');
    
    // Split tracks into chunks of 200 to prevent JNI binder transaction buffer overflow
    // and memory issues with huge playlists (e.g. 10,000 tracks)
    const chunkSize = 200;
    int chunkIndex = 0;
    final totalChunks = (tracks.length / chunkSize).ceil();
    
    for (var i = 0; i < tracks.length; i += chunkSize) {
      chunkIndex++;
      final chunk = tracks.sublist(i, i + chunkSize > tracks.length ? tracks.length : i + chunkSize);
      print('DEBUG Database: Preparando lote $chunkIndex/$totalChunks (${chunk.length} músicas)');
      
      final batch = database.batch();
      for (final t in chunk) {
        final row = _trackToRow(t);
        batch.rawInsert('''
          INSERT INTO tracks (
            id, spotify_uri, isrc, playlist_position, title, artist, primary_artist,
            album, album_artist, album_art_url, release_year, genres, duration_ms,
            track_number, total_tracks, disc_number, explicit, spotify_url, playlist_id,
            local_filename, download_status, available, is_cached
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            spotify_uri = excluded.spotify_uri,
            isrc = excluded.isrc,
            playlist_position = excluded.playlist_position,
            title = excluded.title,
            artist = excluded.artist,
            primary_artist = excluded.primary_artist,
            album = excluded.album,
            album_artist = excluded.album_artist,
            album_art_url = excluded.album_art_url,
            release_year = excluded.release_year,
            genres = excluded.genres,
            duration_ms = excluded.duration_ms,
            track_number = excluded.track_number,
            total_tracks = excluded.total_tracks,
            disc_number = excluded.disc_number,
            explicit = excluded.explicit,
            spotify_url = excluded.spotify_url,
            local_filename = COALESCE(excluded.local_filename, tracks.local_filename),
            download_status = CASE WHEN excluded.download_status != 'pending' THEN excluded.download_status ELSE tracks.download_status END,
            available = CASE WHEN excluded.available = 1 THEN 1 ELSE tracks.available END,
            is_cached = CASE WHEN excluded.is_cached = 1 THEN 1 ELSE tracks.is_cached END
        ''', [
          row['id'],
          row['spotify_uri'],
          row['isrc'],
          row['playlist_position'],
          row['title'],
          row['artist'],
          row['primary_artist'],
          row['album'],
          row['album_artist'],
          row['album_art_url'],
          row['release_year'],
          row['genres'],
          row['duration_ms'],
          row['track_number'],
          row['total_tracks'],
          row['disc_number'],
          row['explicit'],
          row['spotify_url'],
          row['playlist_id'],
          row['local_filename'],
          row['download_status'],
          row['available'],
          row['is_cached']
        ]);
        
        batch.rawInsert('''
          INSERT INTO playlist_tracks (playlist_id, track_id, position)
          VALUES (?, ?, ?)
          ON CONFLICT(playlist_id, track_id) DO UPDATE SET
            position = excluded.position
        ''', [
          row['playlist_id'],
          row['id'],
          row['playlist_position']
        ]);
      }
      
      try {
        await batch.commit(noResult: true);
        print('DEBUG Database: Lote $chunkIndex/$totalChunks commitado com sucesso.');
      } catch (e) {
        print('DEBUG Database: ERRO ao commitar lote $chunkIndex/$totalChunks: $e');
        rethrow;
      }
    }
    
    // Validação final do total de faixas inseridas usando a tabela relacional
    final targetPlaylistId = tracks.first.playlistId;
    try {
      final countResult = await database.rawQuery(
        'SELECT COUNT(*) as cnt FROM playlist_tracks WHERE playlist_id = ?', 
        [targetPlaylistId]
      );
      final count = countResult.first['cnt'] as int? ?? 0;
      print('DEBUG Database: Verificação pós-upsert — Total de faixas em playlist_tracks para "$targetPlaylistId": $count');
    } catch (e) {
      print('DEBUG Database: Falha ao rodar verificação de contagem pós-upsert: $e');
    }
  }

  Future<List<Track>> getTracksForPlaylist(String playlistId) async {
    final database = await db;
    final rows = await database.rawQuery('''
      SELECT t.*, pt.position as playlist_position, pt.playlist_id as playlist_id
      FROM tracks t
      INNER JOIN playlist_tracks pt ON t.id = pt.track_id
      WHERE pt.playlist_id = ?
      ORDER BY pt.position ASC
    ''', [playlistId]);
    return rows.map(_rowToTrack).toList();
  }

  Future<List<Track>> searchTracks(String query, {bool? cachedOnly}) async {
    final database = await db;
    final q = '%$query%';
    final where = StringBuffer('(title LIKE ? OR artist LIKE ? OR album LIKE ?)');
    final args = <Object>[q, q, q];
    if (cachedOnly == true) {
      where.write(' AND is_cached = 1');
    } else if (cachedOnly == false) {
      where.write(' AND is_cached = 0');
    }
    final rows = await database.query(
      'tracks',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'title ASC',
      limit: 50,
    );
    return rows.map(_rowToTrack).toList();
  }

  Future<List<Track>> getTracksByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    final database = await db;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await database.query(
      'tracks',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    final map = {for (final row in rows) row['id'] as String: _rowToTrack(row)};
    final result = <Track>[];
    for (final id in ids) {
      if (map.containsKey(id)) {
        result.add(map[id]!);
      }
    }
    return result;
  }

  Future<List<AlbumGroup>> searchAlbums(String query, {String? playlistId}) async {
    final database = await db;
    final q = '%$query%';
    final whereClause = playlistId != null
        ? 'AND (t.playlist_id = ? OR t.id IN (SELECT track_id FROM playlist_tracks WHERE playlist_id = ?))'
        : '';
    final args = playlistId != null
        ? [q, q, q, q, playlistId, playlistId]
        : [q, q, q, q];
    final rows = await database.rawQuery('''
      SELECT
        t.album,
        COALESCE(NULLIF(t.album_artist, ''), NULLIF(t.artist, ''), NULLIF(t.primary_artist, ''), 'Vários Artistas') as album_artist,
        t.album_art_url,
        t.release_year,
        COUNT(*) as total_tracks,
        SUM(COALESCE(t.is_cached, 0)) as downloaded_tracks,
        (SELECT GROUP_CONCAT(DISTINCT pt2.playlist_id) 
         FROM playlist_tracks pt2 WHERE pt2.track_id = t.id) as playlist_ids
      FROM tracks t
      WHERE (t.album LIKE ? OR t.artist LIKE ? OR t.primary_artist LIKE ? OR t.title LIKE ?)
        AND t.album IS NOT NULL AND t.album != ''
        $whereClause
      GROUP BY t.album
      ORDER BY t.album ASC
    ''', args);
    return rows.map((r) => AlbumGroup(
      albumName: r['album'] as String? ?? '',
      albumArtist: r['album_artist'] as String? ?? '',
      albumArtUrl: r['album_art_url'] as String?,
      releaseYear: r['release_year'] as String? ?? '',
      totalTracks: (r['total_tracks'] as num?)?.toInt() ?? 0,
      downloadedTracks: (r['downloaded_tracks'] as num?)?.toInt() ?? 0,
      playlistIds: (r['playlist_ids'] as String? ?? '').split(',').where((s) => s.isNotEmpty).toList(),
    )).toList();
  }

  Future<List<Track>> getTracksForAlbum(String albumName, {String? playlistId}) async {
    final database = await db;
    if (playlistId != null) {
      final rows = await database.rawQuery('''
        SELECT t.* FROM tracks t
        LEFT JOIN playlist_tracks pt ON t.id = pt.track_id
        WHERE t.album = ? AND (t.playlist_id = ? OR pt.playlist_id = ?)
        GROUP BY t.id
        ORDER BY t.track_number ASC
      ''', [albumName, playlistId, playlistId]);
      return rows.map(_rowToTrack).toList();
    } else {
      final rows = await database.query(
        'tracks',
        where: 'album = ?',
        whereArgs: [albumName],
        orderBy: 'track_number ASC',
      );
      return rows.map(_rowToTrack).toList();
    }
  }

  Future<List<ArtistGroup>> searchArtists(String query, {String? playlistId}) async {
    final database = await db;
    final q = '%$query%';
    final whereClause = playlistId != null
        ? 'AND (t.playlist_id = ? OR t.id IN (SELECT track_id FROM playlist_tracks WHERE playlist_id = ?))'
        : '';
    final args = playlistId != null ? [q, q, q, playlistId, playlistId] : [q, q, q];
    final rows = await database.rawQuery('''
      SELECT
        COALESCE(NULLIF(t.primary_artist, ''), NULLIF(t.artist, ''), 'Artista Desconhecido') as artist_name,
        t.album_art_url,
        COUNT(*) as total_tracks,
        SUM(COALESCE(t.is_cached, 0)) as downloaded_tracks,
        COUNT(DISTINCT t.album) as album_count
      FROM tracks t
      WHERE (t.artist LIKE ? OR t.primary_artist LIKE ? OR t.title LIKE ?)
        AND (COALESCE(NULLIF(t.primary_artist, ''), NULLIF(t.artist, ''), '') != '')
        $whereClause
      GROUP BY COALESCE(NULLIF(t.primary_artist, ''), NULLIF(t.artist, ''), 'Artista Desconhecido')
      ORDER BY artist_name ASC
    ''', args);
    return rows.map((r) => ArtistGroup(
      name: r['artist_name'] as String? ?? '',
      coverArtUrl: r['album_art_url'] as String?,
      totalTracks: (r['total_tracks'] as num?)?.toInt() ?? 0,
      downloadedTracks: (r['downloaded_tracks'] as num?)?.toInt() ?? 0,
      albumCount: (r['album_count'] as num?)?.toInt() ?? 0,
    )).toList();
  }

  Future<List<Track>> getTracksForArtist(String artistName, {String? playlistId}) async {
    final database = await db;
    if (playlistId != null) {
      final rows = await database.rawQuery('''
        SELECT t.* FROM tracks t
        LEFT JOIN playlist_tracks pt ON t.id = pt.track_id
        WHERE (t.primary_artist = ? OR t.artist = ?) AND (t.playlist_id = ? OR pt.playlist_id = ?)
        GROUP BY t.id
        ORDER BY t.album ASC, t.track_number ASC
      ''', [artistName, artistName, playlistId, playlistId]);
      return rows.map(_rowToTrack).toList();
    } else {
      final rows = await database.rawQuery('''
        SELECT t.* FROM tracks t
        WHERE (t.primary_artist = ? OR t.artist = ?)
        ORDER BY t.album ASC, t.track_number ASC
      ''', [artistName, artistName]);
      return rows.map(_rowToTrack).toList();
    }
  }

  /// Atualiza explicitamente o status de cache (podendo setar para false/0).
  /// Útil quando arquivos são deletados ou não encontrados, burlando a trava de `upsertTracks`.
  Future<void> updateTracksCacheStatus(List<Track> tracks) async {
    final database = await db;
    final batch = database.batch();
    for (final t in tracks) {
      batch.update(
        'tracks',
        {
          'is_cached': t.isCached ? 1 : 0,
          'available': t.available ? 1 : 0,
          'download_status': t.downloadStatus,
          'local_filename': t.localFilename,
        },
        where: 'id = ?',
        whereArgs: [t.id],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteTrack(String trackId) async {
    final database = await db;
    await database.delete(
      'tracks',
      where: 'id = ?',
      whereArgs: [trackId],
    );
  }

  Future<void> deleteTracks(List<String> trackIds) async {
    if (trackIds.isEmpty) return;
    final database = await db;
    const chunkSize = 200;
    for (var i = 0; i < trackIds.length; i += chunkSize) {
      final chunk = trackIds.sublist(i, i + chunkSize > trackIds.length ? trackIds.length : i + chunkSize);
      final batch = database.batch();
      for (final id in chunk) {
        batch.delete('tracks', where: 'id = ?', whereArgs: [id]);
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> markCached(String trackId, bool cached) async {
    final database = await db;
    await database.update(
      'tracks',
      {'is_cached': cached ? 1 : 0},
      where: 'id = ?',
      whereArgs: [trackId],
    );
  }

  Future<void> markTrackCorrupted(String trackId) async {
    final database = await db;
    await database.update(
      'tracks',
      {
        'local_filename': null,
        'download_status': 'pending',
        'available': 0,
        'is_cached': 0,
      },
      where: 'id = ?',
      whereArgs: [trackId],
    );
  }

  // ── Histórico ──────────────────────────────────────────────────────────

  Future<void> addToHistory(String trackId) async {
    final database = await db;
    await database.insert('play_history', {
      'track_id': trackId,
      'played_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Track>> getRecentlyPlayed({int limit = 30}) async {
    final database = await db;
    final rows = await database.rawQuery('''
      SELECT t.* FROM tracks t
      INNER JOIN (
        SELECT track_id, MAX(played_at) as last_played
        FROM play_history
        GROUP BY track_id
        ORDER BY last_played DESC
        LIMIT ?
      ) h ON t.id = h.track_id
      ORDER BY h.last_played DESC
    ''', [limit]);
    return rows.map(_rowToTrack).toList();
  }

  Future<List<MapEntry<Track, int>>> getMostPlayed({
    int limit = 5,
    String period = 'semana',
  }) async {
    final database = await db;
    String? cutoffDate;
    if (period == 'semana') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 7)).toIso8601String();
    } else if (period == 'mes') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
    } else if (period == 'ano') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 365)).toIso8601String();
    }

    final String query;
    final List<Object?> args;
    if (cutoffDate != null) {
      query = '''
        SELECT t.*, COUNT(h.track_id) as play_count FROM tracks t
        INNER JOIN play_history h ON t.id = h.track_id
        WHERE h.played_at >= ?
        GROUP BY h.track_id
        ORDER BY play_count DESC
        LIMIT ?
      ''';
      args = [cutoffDate, limit];
    } else {
      query = '''
        SELECT t.*, COUNT(h.track_id) as play_count FROM tracks t
        INNER JOIN play_history h ON t.id = h.track_id
        GROUP BY h.track_id
        ORDER BY play_count DESC
        LIMIT ?
      ''';
      args = [limit];
    }

    final rows = await database.rawQuery(query, args);
    return rows.map((row) {
      final track = _rowToTrack(row);
      final count = row['play_count'] as int? ?? 0;
      return MapEntry(track, count);
    }).toList();
  }

  Future<int> getTotalPlayTimeMs({String period = 'alltime'}) async {
    final database = await db;
    String? cutoffDate;
    if (period == 'semana') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 7)).toIso8601String();
    } else if (period == 'mes') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
    } else if (period == 'ano') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 365)).toIso8601String();
    }

    if (cutoffDate != null) {
      final row = await database.rawQuery('''
        SELECT SUM(t.duration_ms) as total_time FROM tracks t
        INNER JOIN play_history h ON t.id = h.track_id
        WHERE h.played_at >= ?
      ''', [cutoffDate]);
      return row.first['total_time'] as int? ?? 0;
    } else {
      final row = await database.rawQuery('''
        SELECT SUM(t.duration_ms) as total_time FROM tracks t
        INNER JOIN play_history h ON t.id = h.track_id
      ''');
      return row.first['total_time'] as int? ?? 0;
    }
  }

  Future<int> getUniqueTracksCount({String period = 'alltime'}) async {
    final database = await db;
    String? cutoffDate;
    if (period == 'semana') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 7)).toIso8601String();
    } else if (period == 'mes') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
    } else if (period == 'ano') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 365)).toIso8601String();
    }

    if (cutoffDate != null) {
      final row = await database.rawQuery('SELECT COUNT(DISTINCT track_id) as unique_count FROM play_history WHERE played_at >= ?', [cutoffDate]);
      return row.first['unique_count'] as int? ?? 0;
    } else {
      final row = await database.rawQuery('SELECT COUNT(DISTINCT track_id) as unique_count FROM play_history');
      return row.first['unique_count'] as int? ?? 0;
    }
  }

  Future<int> getTotalStreamsCount({String period = 'alltime'}) async {
    final database = await db;
    String? cutoffDate;
    if (period == 'semana') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 7)).toIso8601String();
    } else if (period == 'mes') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 30)).toIso8601String();
    } else if (period == 'ano') {
      cutoffDate = DateTime.now().subtract(const Duration(days: 365)).toIso8601String();
    }

    if (cutoffDate != null) {
      final row = await database.rawQuery('SELECT COUNT(*) as total_streams FROM play_history WHERE played_at >= ?', [cutoffDate]);
      return row.first['total_streams'] as int? ?? 0;
    } else {
      final row = await database.rawQuery('SELECT COUNT(*) as total_streams FROM play_history');
      return row.first['total_streams'] as int? ?? 0;
    }
  }

  // ── Persistência de Estado do Player ─────────────────────────────────────

  Future<void> savePlayerState({
    required String trackId,
    required int positionMs,
    required List<String> queueTrackIds,
  }) async {
    final database = await db;
    await database.rawInsert('''
      INSERT INTO player_state_persistence (id, track_id, position_ms, queue_track_ids)
      VALUES (1, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        track_id = excluded.track_id,
        position_ms = excluded.position_ms,
        queue_track_ids = excluded.queue_track_ids
    ''', [trackId, positionMs, queueTrackIds.join(',')]);
  }

  Future<Map<String, dynamic>?> getSavedPlayerState() async {
    final database = await db;
    final rows = await database.query('player_state_persistence', where: 'id = 1');
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<void> mergeArtists(String sourceArtist, String targetArtist) async {
    final database = await db;
    await database.update(
      'tracks',
      {
        'artist': targetArtist,
        'primary_artist': targetArtist,
      },
      where: 'artist = ? OR primary_artist = ?',
      whereArgs: [sourceArtist, sourceArtist],
    );
  }

  // ── Serialização ──────────────────────────────────────────────────────

  Map<String, dynamic> _trackToRow(Track t) => {
    'id':               t.id,
    'spotify_uri':      t.spotifyUri,
    'isrc':             t.isrc,
    'playlist_position': t.playlistPosition,
    'title':            t.title,
    'artist':           t.artist,
    'primary_artist':   t.primaryArtist,
    'album':            t.album,
    'album_artist':     t.albumArtist,
    'album_art_url':    t.albumArtUrl,
    'release_year':     t.releaseYear,
    'genres':           t.genres.join('|'),
    'duration_ms':      t.durationMs,
    'track_number':     t.trackNumber,
    'total_tracks':     t.totalTracks,
    'disc_number':      t.discNumber,
    'explicit':         t.explicit ? 1 : 0,
    'spotify_url':      t.spotifyUrl,
    'playlist_id':      t.playlistId,
    'local_filename':   t.localFilename,
    'download_status':  t.downloadStatus,
    'available':        t.available ? 1 : 0,
    'is_cached':        t.isCached ? 1 : 0,
  };

  Track _rowToTrack(Map<String, dynamic> row) {
    final id = row['id'] as String? ?? '';
    final spotifyUri = row['spotify_uri'] as String? ?? '';
    final isYt = id.startsWith('yt_') || spotifyUri.startsWith('youtube:');

    final rawArtist = row['artist'] as String? ?? '';
    final rawPrimaryArtist = row['primary_artist'] as String? ?? '';
    final rawAlbum = row['album'] as String? ?? '';
    final rawAlbumArtist = row['album_artist'] as String? ?? '';

    final artistVal = (isYt && (rawArtist.trim().isEmpty || rawArtist == 'Desconhecido')) ? 'YouTube' : rawArtist;
    final primaryArtistVal = (isYt && (rawPrimaryArtist.trim().isEmpty || rawPrimaryArtist == 'Desconhecido')) ? 'YouTube' : (rawPrimaryArtist.isEmpty ? artistVal : rawPrimaryArtist);
    final albumVal = (isYt && (rawAlbum.trim().isEmpty || rawAlbum == 'Desconhecido' || rawAlbum == 'YouTube Single')) ? 'YouTube' : rawAlbum;
    final albumArtistVal = (isYt && (rawAlbumArtist.trim().isEmpty || rawAlbumArtist == 'Desconhecido')) ? 'YouTube' : (rawAlbumArtist.isEmpty ? primaryArtistVal : rawAlbumArtist);

    return Track(
      id:               id,
      spotifyUri:       spotifyUri,
      isrc:             row['isrc']            ?? '',
      playlistPosition: row['playlist_position'] ?? 0,
      title:            row['title']           ?? '',
      artist:           artistVal,
      primaryArtist:    primaryArtistVal,
      album:            albumVal,
      albumArtist:      albumArtistVal,
      albumArtUrl:      row['album_art_url'],
      releaseYear:      row['release_year']    ?? '',
      genres: (row['genres'] as String? ?? '')
          .split('|')
          .where((g) => g.isNotEmpty)
          .toList(),
      durationMs:       row['duration_ms']     ?? 0,
      trackNumber:      row['track_number']    ?? 1,
      totalTracks:      row['total_tracks']    ?? 1,
      discNumber:       row['disc_number']     ?? 1,
      explicit:         (row['explicit'] ?? 0) == 1,
      spotifyUrl:       row['spotify_url']     ?? '',
      playlistId:       row['playlist_id']     ?? '',
      localFilename:    row['local_filename'],
      downloadStatus:   row['download_status'] ?? 'pending',
      available:        (row['available'] ?? 0) == 1,
      isCached:         (row['is_cached'] ?? 0) == 1,
    );
  }
}
