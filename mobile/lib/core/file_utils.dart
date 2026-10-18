import 'dart:convert';
import 'dart:io';

/// Utilitários centralizados para manipulação de arquivos de áudio.
/// Substitui as ~6 implementações duplicadas espalhadas pelo codebase.
abstract class FileUtils {
  /// Extensões de áudio suportadas (em ordem de preferência)
  static const audioExtensions = ['m4a', 'opus', 'mp3', 'flac', 'webm', 'ogg'];

  /// Sanitiza um nome de arquivo removendo caracteres proibidos pelo SO.
  /// Usado para construir nomes de arquivo no formato "Artist - Title.ext".
  static String sanitizeFilename(String s) =>
      s.replaceAll(RegExp(r'[\\/*?:"<>|]'), '_').trim();

  /// Nome-base "Artista - Título" dos arquivos da faixa (áudio e .lrc).
  /// O Android limita nomes a 255 bytes; títulos de símbolos/Zalgo passam disso,
  /// então corta em 250 bytes UTF-8 (sobra espaço pra extensão).
  static String trackBaseName(String artist, String title) {
    const maxBytes = 250;
    final full = '${sanitizeFilename(artist)} - ${sanitizeFilename(title)}';
    if (utf8.encode(full).length <= maxBytes) return full;
    final buf = StringBuffer();
    var bytes = 0;
    for (final rune in full.runes) {
      final n = utf8.encode(String.fromCharCode(rune)).length;
      if (bytes + n > maxBytes) break;
      buf.writeCharCode(rune);
      bytes += n;
    }
    return buf.toString().trim();
  }

  /// Verifica se um arquivo de áudio existe e tem tamanho mínimo válido (> 1KB).
  /// Arquivos menores são considerados corrompidos/incompletos.
  static Future<bool> isValidAudioFile(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    return file.lengthSync() > 1024;
  }

  /// Varre um diretório e retorna um mapa de {filename_lowercase: absolute_path}
  /// contendo apenas arquivos de áudio válidos (> 1KB).
  static Future<Map<String, String>> scanAudioDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    final Map<String, String> filenameToPath = {};
    if (!await dir.exists()) return filenameToPath;

    try {
      final entities = await dir.list().toList();
      for (final entity in entities) {
        if (entity is File) {
          final ext = entity.path.split('.').last.toLowerCase();
          if (audioExtensions.contains(ext) && entity.lengthSync() > 1024) {
            filenameToPath[entity.uri.pathSegments.last.toLowerCase()] = entity.path;
          }
        }
      }
    } catch (e) {
      print('[FileUtils] Erro ao varrer diretório: $e');
    }
    return filenameToPath;
  }

  /// Tenta encontrar o arquivo de áudio local para uma track,
  /// primeiro pelo localFilename exato, depois por "Artist - Title.ext".
  static String? findTrackFile(
    Map<String, String> filenameToPath, {
    required String? localFilename,
    required String artist,
    required String title,
  }) {
    // 1. Caminho exato pelo localFilename
    if (localFilename != null && localFilename.isNotEmpty) {
      final key = localFilename.toLowerCase();
      if (filenameToPath.containsKey(key)) {
        return filenameToPath[key];
      }
    }

    // 2. Fallback: "Artist - Title" com qualquer extensão suportada
    final baseName = trackBaseName(artist, title);
    for (final ext in audioExtensions) {
      final key = '$baseName.$ext'.toLowerCase();
      if (filenameToPath.containsKey(key)) {
        return filenameToPath[key];
      }
    }

    return null;
  }
}
