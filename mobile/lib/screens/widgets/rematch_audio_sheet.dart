import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../data/database/database.dart';
import '../../data/models/track.dart';
import '../../data/services/native_downloader_service.dart';
import '../../data/services/standalone_downloader.dart';
import '../../providers/library_provider.dart';

void showRematchAudioSheet(BuildContext context, WidgetRef ref, Track track) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => RematchAudioSheet(track: track),
  );
}

class RematchAudioSheet extends ConsumerStatefulWidget {
  final Track track;
  const RematchAudioSheet({super.key, required this.track});

  @override
  ConsumerState<RematchAudioSheet> createState() => _RematchAudioSheetState();
}

class _RematchAudioSheetState extends ConsumerState<RematchAudioSheet> {
  late TextEditingController _searchCtrl;
  List<InnerTubeSearchResult> _results = [];
  bool _isLoading = false;
  String? _downloadingId;
  String? _statusText;
  double _downloadProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(
      text: '${widget.track.artist} - ${widget.track.title}',
    );
    _performSearch();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _performSearch() async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isLoading = true;
      _results = [];
    });

    try {
      final results = await NativeDownloaderService().searchInnerTube(query);
      if (mounted) {
        setState(() {
          _results = results;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao buscar vídeos: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _downloadSelectedVideo(InnerTubeSearchResult result) async {
    setState(() {
      _downloadingId = result.id;
      _downloadProgress = 0.1;
      _statusText = 'Baixando "${result.title}"...';
    });

    try {
      final musicDir = await AppConstants.getMusicDirectory();
      final targetFolder = Directory(musicDir);
      if (!targetFolder.existsSync()) {
        targetFolder.createSync(recursive: true);
      }

      final downloadedFile = await StandaloneDownloader().downloadTrack(
        title: widget.track.title,
        artist: widget.track.artist,
        album: widget.track.album,
        imageUrl: widget.track.albumArtUrl,
        playlistId: widget.track.playlistId,
        trackId: widget.track.id,
        durationMs: widget.track.durationMs,
        onProgress: (status, pct) {
          if (mounted) {
            setState(() {
              _statusText = status;
              _downloadProgress = pct;
            });
          }
        },
      );

      if (downloadedFile != null && downloadedFile.existsSync()) {
        final updatedTrack = widget.track.copyWith(
          available: true,
          downloadStatus: 'downloaded',
          localFilename: p.basename(downloadedFile.path),
        );
        await AppDatabase.instance.upsertTracks([updatedTrack]);
        ref.invalidate(playlistTracksProvider(widget.track.playlistId));

        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Versão do áudio atualizada para "${result.title}"!'),
              backgroundColor: AppColors.accent,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloadingId = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao baixar vídeo selecionado: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.youtube_searched_for_rounded, color: AppColors.accent, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Trocar Versão do Áudio (YouTube)',
                        style: TextStyle(color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        '${widget.track.artist} - ${widget.track.title}',
                        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: AppColors.textMuted),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          // Search bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Pesquisar vídeo no YouTube...',
                      hintStyle: const TextStyle(color: AppColors.textMuted),
                      filled: true,
                      fillColor: AppColors.surfaceHigh,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _performSearch(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isLoading ? null : _performSearch,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                  child: const Icon(Icons.search_rounded, size: 20),
                ),
              ],
            ),
          ),

          if (_downloadingId != null)
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.accent.withOpacity(0.4)),
              ),
              child: Column(
                children: [
                  LinearProgressIndicator(
                    value: _downloadProgress > 0 ? _downloadProgress : null,
                    backgroundColor: AppColors.surface,
                    color: AppColors.accent,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _statusText ?? 'Baixando versão selecionada...',
                    style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),

          const Divider(color: AppColors.border, height: 1),

          // Results list
          Expanded(
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: AppColors.accent))
                : _results.isEmpty
                    ? const Center(
                        child: Text('Nenhum vídeo encontrado.', style: TextStyle(color: AppColors.textMuted)),
                      )
                    : ListView.builder(
                        itemCount: _results.length,
                        padding: const EdgeInsets.all(12),
                        itemBuilder: (ctx, i) {
                          final item = _results[i];
                          final isDownloading = _downloadingId == item.id;
                          final isTopic = item.owner.contains('Topic') || item.title.toLowerCase().contains('audio');
                          final durStr = '${item.durationSec ~/ 60}:${(item.durationSec % 60).toString().padLeft(2, '0')}';

                          return Card(
                            color: AppColors.surfaceHigh,
                            margin: const EdgeInsets.only(bottom: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            child: ListTile(
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    CachedNetworkImage(
                                      imageUrl: 'https://img.youtube.com/vi/${item.id}/hqdefault.jpg',
                                      width: 60,
                                      height: 60,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, __, ___) => const Icon(Icons.music_note_rounded, color: AppColors.textMuted),
                                    ),
                                    if (isTopic)
                                      Positioned(
                                        top: 2,
                                        right: 2,
                                        child: Container(
                                          padding: const EdgeInsets.all(2),
                                          decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle),
                                          child: const Icon(Icons.check, size: 10, color: Colors.white),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              title: Text(
                                item.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: AppColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                              subtitle: Text(
                                '${item.owner} • $durStr',
                                style: const TextStyle(color: AppColors.textMuted, fontSize: 11),
                              ),
                              trailing: isDownloading
                                  ? SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.accent))
                                  : ElevatedButton(
                                      onPressed: _downloadingId != null ? null : () => _downloadSelectedVideo(item),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.accent,
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      ),
                                      child: const Text('Baixar esta', style: TextStyle(fontSize: 12)),
                                    ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
