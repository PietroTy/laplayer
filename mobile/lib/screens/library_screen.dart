import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme.dart';
import '../data/models/playlist.dart';
import '../data/services/sync_service.dart';
import '../providers/library_provider.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Biblioteca'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'Adicionar playlist',
            onPressed: () => context.push('/add-playlist'),
          ),
        ],
      ),
      body: playlists.when(
        loading: () => Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        ),
        error: (e, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: AppColors.error, size: 48),
              const SizedBox(height: 16),
              Text('$e', style: const TextStyle(color: AppColors.textMuted), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => ref.invalidate(playlistsProvider),
                child: const Text('Tentar novamente'),
              ),
            ],
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.library_music_rounded, color: AppColors.textMuted, size: 64),
                  const SizedBox(height: 16),
                  const Text('Nenhuma playlist ainda.',
                    style: TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  const Text('Faça um sync ou adicione uma playlist do Spotify.',
                    style: TextStyle(color: AppColors.textMuted, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Adicionar playlist'),
                    onPressed: () => context.push('/add-playlist'),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            color: AppColors.accent,
            backgroundColor: AppColors.surface,
            onRefresh: () async {
              await ref.read(syncProvider.notifier).syncAll();
              ref.invalidate(playlistsProvider);
            },
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _PlaylistTile(playlist: list[i]),
            ),
          );
        },
      ),
    );
  }
}

class _PlaylistTile extends ConsumerWidget {
  final Playlist playlist;
  const _PlaylistTile({required this.playlist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 6),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: playlist.imageUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: playlist.imageUrl,
                width: 52, height: 52,
                fit: BoxFit.cover,
                errorWidget: (_, __, ___) => _placeholder(),
              )
            : _placeholder(),
      ),
      title: Text(
        playlist.name,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (playlist.description.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              playlist.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textSecond, fontSize: 12),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            '${playlist.downloaded}/${playlist.totalTracks} músicas',
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: playlist.progress,
            backgroundColor: AppColors.border,
            color: playlist.isComplete ? AppColors.accent : AppColors.accentDim,
            minHeight: 2,
            borderRadius: BorderRadius.circular(2),
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textMuted),
      onTap: () => context.push(
        '/library/playlist/${playlist.id}?name=${Uri.encodeComponent(playlist.name)}',
      ),
      onLongPress: () {
        showModalBottomSheet(
          context: context,
          backgroundColor: AppColors.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          builder: (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('Playlist: ${playlist.name}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_forever_rounded, color: AppColors.error),
                  title: const Text('Remover Playlist', style: TextStyle(color: AppColors.error)),
                  subtitle: const Text('Apaga arquivos no servidor e no celular'),
                  onTap: () {
                    Navigator.pop(context);
                    _showDeleteConfirm(context, ref);
                  },
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showDeleteConfirm(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        title: const Text('Apagar Playlist?'),
        content: Text('Isso removerá "${playlist.name}" permanentemente.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(libraryProvider.notifier).deletePlaylist(playlist.id);
            },
            child: const Text('APAGAR', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }
  Widget _placeholder() => Container(
    width: 52,
    height: 52,
    color: AppColors.surfaceHigh,
    child: Icon(Icons.library_music_rounded, color: AppColors.accent, size: 26),
  );
}
