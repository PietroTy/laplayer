import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

enum AudioQualityPreset {
  normal,   // ~96-128 kbps
  high,     // ~160 kbps
  veryHigh, // Highest available
}

class InnerTubeSearchResult {
  final String id;
  final String title;
  final String owner;
  final int durationSec;

  InnerTubeSearchResult({
    required this.id,
    required this.title,
    required this.owner,
    required this.durationSec,
  });
}

class NativeDownloaderService {
  static final NativeDownloaderService _instance = NativeDownloaderService._internal();
  factory NativeDownloaderService() => _instance;
  NativeDownloaderService._internal();

  final YoutubeExplode _yt = YoutubeExplode();
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 25),
    receiveTimeout: const Duration(seconds: 60),
  ));

  /// Flag que indica se o cipher do YouTube já foi baixado e compilado
  bool _cipherReady = false;

  /// Helper para log com timestamp relativo
  final Stopwatch _sw = Stopwatch();

  void _log(String msg) {
    final elapsed = _sw.elapsedMilliseconds;
    debugPrint('[NativeDownloader +${elapsed}ms] $msg');
  }

  /// Pré-aquece o engine baixando o cipher script do YouTube (4.7MB, ~15-20s na primeira vez)
  Future<void> warmUp() async {
    if (_cipherReady) return;
    _sw.reset();
    _sw.start();
    _log('🔥 warmUp() INICIANDO — pré-carregando cipher do YouTube...');
    try {
      final manifest = await _yt.videos.streamsClient
          .getManifest(VideoId('dQw4w9WgXcQ'))
          .timeout(const Duration(seconds: 45));
      _cipherReady = true;
      _log('✅ warmUp() SUCESSO — ${manifest.audioOnly.length} streams disponíveis');
    } catch (e) {
      _log('❌ warmUp() FALHOU: $e (continuando)');
    }
  }

  /// Sanitiza o texto para busca unindo letras isoladas (ex: S U R F I N G) e tratando símbolos exóticos (Braille/Kaomojis)
  String sanitizeQuery(String text) {
    if (text.isEmpty) return '';
    var str = text;
    // Se o texto tiver densidade extrema de símbolos (Braille/Kaomojis), remove parênteses e limita o prefixo
    final symbolCount = RegExp(r'[^\w\s]').allMatches(str).length;
    if (symbolCount > 3) {
      final cleanedSymbols = str.replaceAll(RegExp(r'[\(\)\[\]\}/\\\|]'), '');
      if (cleanedSymbols.length > 8) {
        str = cleanedSymbols.substring(0, 8).trim();
      } else {
        str = cleanedSymbols;
      }
    }
    // Junta letras isoladas por espaço (ex: "S U R F I N G" -> "SURFING")
    var cleaned = str.replaceAllMapped(RegExp(r'(?<=\b[A-Za-z])\s+(?=[A-Za-z]\b)'), (m) => '');
    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Sanitiza termos NSFW que o YouTube SafeSearch filtra, substituindo por versões censuradas.
  /// Isso permite que a busca encontre vídeos que existem mas cujo título contém palavras explícitas.
  String sanitizeNsfwQuery(String query) {
    final replacements = {
      // PT-BR
      'sexo': 's3xo',
      'sex': 's3x',
      'sexy': 's3xy',
      'pau': 'p4u',
      'duro': 'dur0',
      'cu ': 'c* ',
      'puta': 'put4',
      'foda': 'f0da',
      'foder': 'f0der',
      'buceta': 'buc3ta',
      'piroca': 'pir0ca',
      'caralho': 'car4lho',
      'porra': 'p0rra',
      'gozar': 'g0zar',
      'orgasmo': '0rgasmo',
      'punheta': 'punh3ta',
      'anal': '4nal',
      'vagina': 'v4gina',
      'penis': 'p3nis',
      'pênis': 'p3nis',
      'nude': 'nud3',
      'nudes': 'nud3s',
      'safada': 'saf4da',
      'safado': 'saf4do',
      'gostosa': 'gost0sa',
      'tesão': 'tes4o',
      'tesao': 'tes4o',
      'putaria': 'put4ria',
      // EN
      'fuck': 'f*ck',
      'pussy': 'pu$$y',
      'dick': 'd!ck',
      'cock': 'c0ck',
      'porn': 'p0rn',
      'cum': 'c*m',
      'ass ': 'a** ',
      'boob': 'b00b',
      'tits': 't!ts',
      'orgasm': '0rgasm',
      'erotic': 'er0tic',
      'horny': 'h0rny',
      'naked': 'nak3d',
      'slut': 'sl*t',
      'whore': 'wh0re',
    };
    var result = query.toLowerCase();
    var changed = false;
    for (final entry in replacements.entries) {
      if (result.contains(entry.key)) {
        result = result.replaceAll(entry.key, entry.value);
        changed = true;
      }
    }
    return changed ? result : query; // retorna original se nada mudou
  }

  /// Sanitiza o nome do arquivo para gravação em disco
  String sanitizeFilename(String filename) {
    return filename
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Converte string de tempo (ex: "4:07" ou "1:02:15") em segundos
  int _parseDurationSec(String durationStr) {
    if (durationStr.isEmpty) return 0;
    final parts = durationStr.split(':');
    if (parts.length == 2) {
      return (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
    } else if (parts.length == 3) {
      return (int.tryParse(parts[0]) ?? 0) * 3600 +
          (int.tryParse(parts[1]) ?? 0) * 60 +
          (int.tryParse(parts[2]) ?? 0);
    }
    return 0;
  }

  /// Busca ultra-rápida via InnerTube JSON API trazendo ID, Título, Canal e Duração Exata
  Future<List<InnerTubeSearchResult>> searchInnerTube(String query) async {
    final t0 = _sw.elapsedMilliseconds;
    _log('🔍 InnerTube search POST: "$query"');
    try {
      final response = await _dio.post(
        'https://www.youtube.com/youtubei/v1/search',
        data: {
          'context': {
            'client': {
              'clientName': 'WEB',
              'clientVersion': '2.20240308.00.00',
              'hl': 'pt',
              'gl': 'BR',
            }
          },
          'query': query,
        },
        options: Options(
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          },
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data is Map ? response.data as Map : jsonDecode(response.data.toString());
        final contents = data['contents']?['twoColumnSearchResultsRenderer']?['primaryContents']?['sectionListRenderer']?['contents'] as List?;
        
        final results = <InnerTubeSearchResult>[];
        if (contents != null) {
          for (final sec in contents) {
            final items = sec['itemSectionRenderer']?['contents'] as List?;
            if (items != null) {
              for (final item in items) {
                final vr = item['videoRenderer'];
                if (vr != null) {
                  final vid = vr['videoId']?.toString() ?? '';
                  if (vid.isEmpty) continue;

                  // Título
                  final titleRuns = vr['title']?['runs'] as List?;
                  final title = titleRuns != null ? titleRuns.map((r) => r['text'] ?? '').join() : '';

                  // Autor / Canal
                  final ownerRuns = vr['ownerText']?['runs'] as List?;
                  final owner = ownerRuns != null ? ownerRuns.map((r) => r['text'] ?? '').join() : '';

                  // Duração
                  var durStr = vr['lengthText']?['simpleText']?.toString() ?? '';
                  if (durStr.isEmpty) {
                    final durRuns = vr['lengthText']?['runs'] as List?;
                    if (durRuns != null) {
                      durStr = durRuns.map((r) => r['text'] ?? '').join();
                    }
                  }

                  final durSec = _parseDurationSec(durStr);
                  results.add(InnerTubeSearchResult(
                    id: vid,
                    title: title,
                    owner: owner,
                    durationSec: durSec,
                  ));
                }
              }
            }
          }
        }
        _log('🔍 InnerTube search retornou ${results.length} resultados completos em ${_sw.elapsedMilliseconds - t0}ms');
        return results;
      }
    } catch (e) {
      _log('❌ InnerTube search error: $e');
    }
    return [];
  }

  /// Baixa a faixa do Spotify buscando a música completa oficial no YouTube
  Future<File?> downloadTrack({
    required String trackTitle,
    required String artistName,
    required String albumName,
    required String targetDirectory,
    String? coverUrl,
    int? durationMs,
    String? year,
    int? trackNumber,
    AudioQualityPreset qualityPreset = AudioQualityPreset.veryHigh,
    Function(double progress, String status)? onProgress,
  }) async {
    _sw.reset();
    _sw.start();
    
    final cleanTitle = sanitizeQuery(trackTitle);
    final cleanArtist = sanitizeQuery(artistName);
    final targetDurSec = durationMs != null ? durationMs ~/ 1000 : 0;

    _log('════════════════════════════════════════════');
    _log('▶ INÍCIO: "$cleanArtist - $cleanTitle" (dur esperada: ${targetDurSec}s)');
    _log('════════════════════════════════════════════');

    bool isMostlySymbols(String s) {
      final clean = s.replaceAll(RegExp(r'[\s\(\)\[\]\-_]'), '');
      if (clean.isEmpty) return true;
      final letters = RegExp(r'[\w\u3040-\u30FF\u4E00-\u9FFF]').allMatches(clean).length;
      final symbols = clean.length - letters;
      return symbols > letters || letters < 2;
    }

    final queries = <String>[];
    if (isMostlySymbols(trackTitle) || isMostlySymbols(artistName)) {
      queries.add('$cleanArtist Topic');
    }
    queries.addAll([
      '$cleanArtist - $cleanTitle Audio',
      '$cleanArtist $cleanTitle',
      cleanTitle,
    ]);

    onProgress?.call(0.05, 'Buscando áudio oficial...');

    // ═══════════════════════════════════════
    // ETAPA 1: BUSCA INNERTUBE INSTANTÂNEA
    // ═══════════════════════════════════════
    List<InnerTubeSearchResult> candidates = [];

    for (final q in queries) {
      final searchResults = await searchInnerTube(q);
      if (searchResults.isNotEmpty) {
        for (final item in searchResults) {
          final diffSec = targetDurSec > 0 && item.durationSec > 0 ? (item.durationSec - targetDurSec).abs() : 0;
          if (targetDurSec > 0 && item.durationSec > 0 && diffSec > 25) {
            _log('  ❌ DESCARTADO "${item.title}" (${item.durationSec}s, diff=${diffSec}s)');
            continue;
          }
          _log('  ✅ ACEITO "${item.title}" (${item.durationSec}s, diff=${diffSec}s, owner: "${item.owner}") [ID: ${item.id}]');
          candidates.add(item);
        }
        if (candidates.isNotEmpty) break;
      }
    }

    // ═══════════════════════════════════════
    // RETRY NSFW: Se 0 resultados, tenta com termos sanitizados
    // YouTube SafeSearch filtra queries com palavras explícitas mesmo quando os vídeos existem
    // ═══════════════════════════════════════
    if (candidates.isEmpty) {
      _log('⚠ 0 candidatos nas queries normais. Tentando retry com sanitização NSFW...');
      
      final nsfwQueries = <String>{};
      for (final q in queries) {
        final sanitized = sanitizeNsfwQuery(q);
        if (sanitized != q) { // só adiciona se a sanitização realmente mudou algo
          nsfwQueries.add(sanitized);
        }
      }
      
      // Adiciona também busca só pelo artista + "audio" como último recurso
      final artistOnlyQuery = '$cleanArtist $cleanTitle audio';
      final sanitizedArtistQuery = sanitizeNsfwQuery(artistOnlyQuery);
      if (!nsfwQueries.contains(sanitizedArtistQuery)) {
        nsfwQueries.add(sanitizedArtistQuery);
      }
      
      for (final q in nsfwQueries) {
        _log('🔍 NSFW retry: "$q"');
        final searchResults = await searchInnerTube(q);
        if (searchResults.isNotEmpty) {
          for (final item in searchResults) {
            final diffSec = targetDurSec > 0 && item.durationSec > 0 ? (item.durationSec - targetDurSec).abs() : 0;
            if (targetDurSec > 0 && item.durationSec > 0 && diffSec > 25) {
              continue;
            }
            _log('  ✅ NSFW retry ACEITO "${item.title}" (${item.durationSec}s) [ID: ${item.id}]');
            candidates.add(item);
          }
          if (candidates.isNotEmpty) break;
        }
      }
    }

    if (candidates.isEmpty) {
      _log('💀 NENHUM CANDIDATO VÁLIDO ENCONTRADO (incluindo retry NSFW). ABORTANDO.');
      throw Exception('Nenhum vídeo completo encontrado no YouTube para "$cleanArtist - $cleanTitle"');
    }

    // Ordenar com Algoritmo Inteligente v2.0 (Validação de Artista, Título, Remix e Duração)
    int scoreCandidate(InnerTubeSearchResult item) {
      final title = item.title.toLowerCase();
      final uploader = item.owner.toLowerCase();
      final dur = item.durationSec;

      int score = 0;
      final artistClean = cleanArtist.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '');
      final artistWords = artistClean.split(' ').where((w) => w.isNotEmpty).toSet();
      final uploaderWords = uploader.replaceAll(RegExp(r'[^\w\s]'), '').split(' ').toSet();
      final titleWords = title.replaceAll(RegExp(r'[^\w\s]'), '').split(' ').toSet();

      final artistInUploader = artistWords.any((w) => uploaderWords.contains(w));
      final artistInTitle = artistWords.any((w) => titleWords.contains(w));

      if (uploader.contains('topic')) {
        if (artistInUploader || artistInTitle) {
          score += 120;
        } else {
          score -= 150; // Penaliza Topic Channel de OUTRO artista!
        }
      }

      int nameSimilarityScore = 0;
      final expectedTitleClean = cleanTitle.toLowerCase().replaceAll(RegExp(r'[\(\[][^\)\]]*[\)\]]'), '');
      final expectedTitleWords = expectedTitleClean.replaceAll(RegExp(r'[^\w\s]'), '').split(' ').where((w) => w.isNotEmpty).toSet();
      if (expectedTitleWords.isNotEmpty) {
        final overlap = expectedTitleWords.intersection(titleWords).length / expectedTitleWords.length;
        nameSimilarityScore = (overlap * 100).toInt();
        score += nameSimilarityScore;

        if (overlap < 0.15) {
          score -= 200; // Título totalmente incompatível
        }
      }

      if (title.contains('official audio') || title.contains('audio oficial')) {
        score += 60;
      } else if (title.contains('audio')) {
        score += 30;
      }

      final versionKeywords = ['remix', 'edit', 'radio', 'live', 'ao vivo', 'acoustic', 'acustico', 'instrumental', 'mix'];
      final expectedFull = '$trackTitle $artistName'.toLowerCase();
      for (final kw in versionKeywords) {
        if (expectedFull.contains(kw) && title.contains(kw)) {
          score += 50;
        } else if (expectedFull.contains(kw) && !title.contains(kw)) {
          score -= 40;
        } else if (!expectedFull.contains(kw) && title.contains(kw)) {
          score -= 30; // Vídeo é remix/live mas o Spotify pede a faixa original solo!
        }
      }

      if (targetDurSec > 0 && dur > 0) {
        final diff = (dur - targetDurSec).abs();
        if (diff <= 2) {
          // Duração praticamente idêntica: usa a similaridade do nome como desempate decisivo!
          score += 80 + nameSimilarityScore;
        } else if (diff <= 5) {
          score += 50 + (nameSimilarityScore ~/ 2);
        } else if (diff <= 15) {
          score += 10;
        } else if (diff <= 25) {
          score -= 60;
        } else {
          score -= 250; // Diferença grotesca de duração
        }
      }

      return score;
    }

    candidates.sort((a, b) => scoreCandidate(b).compareTo(scoreCandidate(a)));

    _log('📋 ${candidates.length} candidatos válidos. Vencedor: "${candidates.first.title}" [ID: ${candidates.first.id}]');

    // ═══════════════════════════════════════
    // ETAPA 2: OBTER MANIFEST (STREAM)
    // ═══════════════════════════════════════
    onProgress?.call(0.20, 'Obtendo fluxo de áudio HD...');

    StreamManifest? manifest;
    InnerTubeSearchResult? selectedCandidate;

    for (final candidate in candidates.take(3)) {
      try {
        final timeout = _cipherReady ? const Duration(seconds: 15) : const Duration(seconds: 45);
        final t0 = _sw.elapsedMilliseconds;
        _log('🔐 getManifest("${candidate.title}", ID: ${candidate.id}) [timeout: ${timeout.inSeconds}s, cipherReady: $_cipherReady]');
        
        manifest = await _yt.videos.streamsClient
            .getManifest(VideoId(candidate.id))
            .timeout(timeout);
        
        final manifestTime = _sw.elapsedMilliseconds - t0;
        _log('🔐 getManifest SUCESSO em ${manifestTime}ms — ${manifest.audioOnly.length} audio streams');
        
        if (manifest.audioOnly.isNotEmpty) {
          selectedCandidate = candidate;
          _cipherReady = true;
          break;
        }
      } catch (e) {
        _log('❌ getManifest FALHOU para ${candidate.id}: $e');
      }
    }

    if (manifest == null || selectedCandidate == null) {
      _log('💀 NENHUM MANIFEST OBTIDO. ABORTANDO.');
      throw Exception('Não foi possível obter a stream para "$cleanArtist - $cleanTitle"');
    }

    // ═══════════════════════════════════════
    // ETAPA 3: SELECIONAR STREAM M4A/AAC
    // ═══════════════════════════════════════
    final audioStreams = manifest.audioOnly.toList();
    
    // Dar preferência a M4A/AAC com o maior bitrate disponível (160k - 256k)
    audioStreams.sort((a, b) {
      final aIsM4a = a.container.name.toLowerCase().contains('m4a') || a.codec.mimeType.contains('mp4');
      final bIsM4a = b.container.name.toLowerCase().contains('m4a') || b.codec.mimeType.contains('mp4');
      if (aIsM4a && !bIsM4a) return -1;
      if (!aIsM4a && bIsM4a) return 1;
      return b.bitrate.compareTo(a.bitrate);
    });

    final preferredStream = audioStreams.first;
    final isM4a = preferredStream.container.name.toLowerCase().contains('m4a') || preferredStream.codec.mimeType.contains('mp4');
    final ext = isM4a ? '.m4a' : '.webm';
    
    _log('✨ Stream selecionada: ${preferredStream.container.name} ${preferredStream.bitrate.kiloBitsPerSecond} kbps ext=$ext');

    final sanitizedFilename = sanitizeFilename('$artistName - $trackTitle$ext');
    final targetFile = File(p.join(targetDirectory, sanitizedFilename));

    if (targetFile.existsSync()) {
      try {
        targetFile.deleteSync();
      } catch (_) {}
    }

    // ═══════════════════════════════════════
    // ETAPA 4: DOWNLOAD DO ARQUIVO
    // ═══════════════════════════════════════
    onProgress?.call(0.35, 'Baixando áudio HD...');

    bool downloadSuccess = false;

    for (final streamInfo in audioStreams) {
      _log('⬇ Baixando via Dio: ${streamInfo.container.name} ${streamInfo.bitrate.kiloBitsPerSecond} kbps');

      try {
        final t0 = _sw.elapsedMilliseconds;
        await _dio.download(
          streamInfo.url.toString(),
          targetFile.path,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              final downloadProgress = 0.35 + (0.45 * (received / total));
              onProgress?.call(
                downloadProgress,
                'Baixando HD (${(received / (1024 * 1024)).toStringAsFixed(1)} / ${(total / (1024 * 1024)).toStringAsFixed(1)} MB)...',
              );
            }
          },
          options: Options(
            headers: {
              'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
              'Range': 'bytes=0-',
            },
          ),
        );

        final dlTime = _sw.elapsedMilliseconds - t0;
        if (targetFile.existsSync() && targetFile.lengthSync() > 10000) {
          final sizeMb = targetFile.lengthSync() / (1024 * 1024);
          _log('✅ Dio download SUCESSO: ${sizeMb.toStringAsFixed(2)} MB em ${dlTime}ms');
          downloadSuccess = true;
          break;
        }
      } catch (dioErr) {
        _log('❌ Dio download falhou: $dioErr. Tentando stream chunking...');

        try {
          final t0 = _sw.elapsedMilliseconds;
          final audioStream = _yt.videos.streamsClient.get(streamInfo);
          final outputStream = targetFile.openWrite();
          final totalBytes = streamInfo.size.totalBytes;
          int downloadedBytes = 0;

          await for (final chunk in audioStream.timeout(const Duration(seconds: 45))) {
            downloadedBytes += chunk.length;
            outputStream.add(chunk);

            if (totalBytes > 0) {
              final downloadProgress = 0.35 + (0.45 * (downloadedBytes / totalBytes));
              onProgress?.call(
                downloadProgress,
                'Baixando HD (${(downloadedBytes / (1024 * 1024)).toStringAsFixed(1)} MB)...',
              );
            }
          }

          await outputStream.flush();
          await outputStream.close();

          final dlTime = _sw.elapsedMilliseconds - t0;
          if (targetFile.existsSync() && targetFile.lengthSync() > 10000) {
            final sizeMb = targetFile.lengthSync() / (1024 * 1024);
            _log('✅ Stream chunking SUCESSO: ${sizeMb.toStringAsFixed(2)} MB em ${dlTime}ms');
            downloadSuccess = true;
            break;
          }
        } catch (ytErr) {
          _log('❌ Stream chunking também falhou: $ytErr');
          if (targetFile.existsSync()) {
            try {
              targetFile.deleteSync();
            } catch (_) {}
          }
        }
      }
    }

    final totalTime = _sw.elapsedMilliseconds;

    if (!downloadSuccess || !targetFile.existsSync() || targetFile.lengthSync() < 10000) {
      _log('💀 DOWNLOAD TOTAL FALHOU em ${totalTime}ms');
      throw Exception('Não foi possível salvar a faixa "$cleanArtist - $cleanTitle"');
    }

    final fileSizeMb = targetFile.lengthSync() / (1024 * 1024);
    _log('════════════════════════════════════════════');
    _log('🏁 CONCLUÍDO: "$cleanArtist - $cleanTitle" (${fileSizeMb.toStringAsFixed(2)} MB em ${totalTime}ms)');
    _log('════════════════════════════════════════════');

    onProgress?.call(1.0, 'Download concluído!');
    return targetFile;
  }

  void dispose() {
    try {
      _yt.close();
      _dio.close();
    } catch (_) {}
  }
}
