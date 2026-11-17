import 'dart:io';

import 'package:flutter/material.dart';

import '../downloads.dart';
import '../library.dart';
import '../native.dart';
import 'player.dart';
import 'widgets.dart';

String _fmt(int b) {
  if (b <= 0) return '0 MB';
  const gb = 1024 * 1024 * 1024;
  if (b >= gb) return '${(b / gb).toStringAsFixed(2)} GB';
  return '${(b / (1024 * 1024)).toStringAsFixed(0)} MB';
}

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  Future<void> _play(BuildContext context, DownloadTask t) async {
    if (!await File(t.path).exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('File nahi mili. Dobara download karo.')));
      }
      return;
    }
    final e = Library.entry(t.item, t.season, t.episode);
    final start = (e != null && !e.finished && e.positionMs > 30000) ? e.positionMs - 3000 : 0;
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        item: t.item,
        season: t.season,
        episode: t.episode,
        info: PlayInfo(t.path, {}, null, false),
        startMs: start,
        title: t.title,
        captions: const [],
        subHeaders: const [],
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Downloads.I,
      builder: (context, _) {
        final tasks = Downloads.I.tasks;
        if (tasks.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Koi download nahi.\nKisi movie/episode ke page pe Download dabao.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(10),
          itemCount: tasks.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final t = tasks[i];
            final done = t.status == 'done';
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(width: 48, height: 68, child: PosterImage(t.item.poster)),
              ),
              title: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SizedBox(height: 4),
                if (!done)
                  LinearProgressIndicator(
                      value: t.total > 0 ? t.progress : null, minHeight: 4),
                const SizedBox(height: 4),
                Text(
                  done
                      ? 'Ready · ${_fmt(t.total)}'
                      : t.status == 'error'
                          ? 'Error: ${t.error ?? ''}'
                          : '${t.status == 'paused' ? 'Paused' : 'Downloading'} · ${_fmt(t.received)}${t.total > 0 ? ' / ${_fmt(t.total)}' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color: t.status == 'error' ? Colors.redAccent : Colors.white60),
                ),
              ]),
              onTap: done ? () => _play(context, t) : null,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (done)
                  IconButton(icon: const Icon(Icons.play_circle_fill), onPressed: () => _play(context, t))
                else if (t.status == 'downloading')
                  IconButton(icon: const Icon(Icons.pause), onPressed: () => Downloads.I.pause(t))
                else
                  IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => Downloads.I.resume(t)),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Delete?'),
                        content: Text(t.title),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                        ],
                      ),
                    );
                    if (ok == true) await Downloads.I.remove(t);
                  },
                ),
              ]),
            );
          },
        );
      },
    );
  }
}
