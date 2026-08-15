import 'dart:io';
import 'package:flutter/foundation.dart';
import '../lib/data/services/native_downloader_service.dart';

void main() async {
  print('===========================================================');
  print(' TESTANDO NATIVE DOWNLOADER SERVICE DART');
  print('===========================================================');

  final downloader = NativeDownloaderService();
  final tempDir = Directory.systemTemp.createTempSync('localify_test_');

  print('Diretório temporário: ${tempDir.path}');

  try {
    print('\n[+] Testando faixa: Rick Astley - Never Gonna Give You Up...');
    final file1 = await downloader.downloadTrack(
      trackTitle: 'Never Gonna Give You Up',
      artistName: 'Rick Astley',
      albumName: 'Whenever You Need Somebody',
      targetDirectory: tempDir.path,
      coverUrl: 'https://i.scdn.co/image/ab67616d0000b2735d4f3b6070a256a29d5b03d6',
      durationMs: 213573,
      year: '1987',
      trackNumber: 1,
      qualityPreset: AudioQualityPreset.veryHigh,
      onProgress: (progress, status) {
        print('    Progresso ${(progress * 100).toStringAsFixed(0)}%: $status');
      },
    );

    if (file1 != null && file1.existsSync()) {
      final size = file1.lengthSync();
      print('\n===========================================================');
      print(' 🎉 SUCESSO! Áudio baixado em Dart Nativo!');
      print('    Caminho: ${file1.path}');
      print('    Tamanho: ${(size / (1024 * 1024)).toStringAsFixed(2)} MB');
      print('===========================================================');
    } else {
      print('\n❌ FALHA: Arquivo não foi gerado.');
    }

  } catch (e, stack) {
    print('\n❌ ERRO NO TESTE DART: $e\n$stack');
  } finally {
    downloader.dispose();
  }
}
