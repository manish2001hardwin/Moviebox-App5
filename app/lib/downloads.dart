import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native.dart';

/// status: queued | downloading | paused | done | error
class DownloadTask {
  final String id;
  final Item item;
  final int season;
  final int episode;
  final String title;
  final String url;
  final Map<String, String> headers;
  final String path;
  int received;
  int total;
  String status;
  String? error;

  DownloadTask({
    required this.id,
    required this.item,
    required this.season,
    required this.episode,
    required this.title,
    required this.url,
    required this.headers,
    required this.path,
    this.received = 0,
    this.total = 0,
    this.status = 'queued',
    this.error,
  });

  double get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : 0;

  Map<String, dynamic> toJson() => {
        'id': id,
        'item': item.toJson(),
        'season': season,
        'episode': episode,
        'title': title,
        'url': url,
        'headers': headers,
        'path': path,
        'received': received,
        'total': total,
        'status': status,
        'error': error,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) => DownloadTask(
        id: j['id'],
        item: Item.fromStored(Map<String, dynamic>.from(j['item'])),
        season: j['season'] ?? 0,
        episode: j['episode'] ?? 0,
        title: j['title'] ?? '',
        url: j['url'],
        headers: Map<String, String>.from(j['headers'] ?? {}),
        path: j['path'],
        received: j['received'] ?? 0,
        total: j['total'] ?? 0,
        status: j['status'] ?? 'paused',
        error: j['error'],
      );
}

/// Simple resumable HTTP downloader (works for direct mp4/mkv links).
/// Files go to the app's own storage, so no storage permission is needed.
class Downloads extends ChangeNotifier {
  Downloads._();
  static final Downloads I = Downloads._();

  final List<DownloadTask> tasks = [];
  final Set<String> _active = {};
  final Set<String> _stop = {};
  final Map<String, Completer<void>> _stopAck = {};
  late SharedPreferences _p;
  late Directory _dir;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    Directory base;
    try {
      base = (await getExternalStorageDirectory()) ?? await getApplicationSupportDirectory();
    } catch (_) {
      base = await getApplicationSupportDirectory();
    }
    _dir = Directory('${base.path}/downloads');
    await _dir.create(recursive: true);
    try {
      final raw = jsonDecode(_p.getString('downloads') ?? '[]');
      if (raw is! List) return;
      for (final e in raw) {
        // One corrupted record (bad JSON shape, missing field) must not drop the
        // other valid downloads that happen to be stored after it.
        try {
          final t = DownloadTask.fromJson(Map<String, dynamic>.from(e));
          if (t.status == 'downloading' || t.status == 'queued') t.status = 'paused';
          tasks.add(t);
        } catch (_) {
          // skip just this one record
        }
      }
    } catch (_) {
      // the whole 'downloads' value wasn't valid JSON at all: start clean
    }
  }

  String _safe(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_').trim();
    // Slashes/backslashes are already stripped above, so ".." cannot escape the
    // downloads directory via a real path separator — this just avoids ugly/
    // confusing filenames like "....mp4".
    final noDotRuns = cleaned.replaceAll(RegExp(r'\.{2,}'), '.');
    return noDotRuns.isEmpty ? 'download' : noDotRuns;
  }

  String _ext(String url) {
    try {
      final p = Uri.parse(url).path.toLowerCase();
      for (final e in ['.mkv', '.mp4', '.webm', '.avi', '.mov', '.m4v']) {
        if (p.endsWith(e)) return e;
      }
    } catch (_) {}
    return '.mp4';
  }

  DownloadTask? find(Item item, int season, int episode) {
    for (final t in tasks) {
      if (t.item.key == item.key && t.season == season && t.episode == episode) return t;
    }
    return null;
  }

  Future<void> enqueue(Item item, int season, int episode, String title, String url,
      Map<String, String> headers) async {
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw ArgumentError('Refusing to download a non-http(s) URL');
    }
    final existing = find(item, season, episode);
    if (existing != null) {
      if (existing.status != 'done' && existing.status != 'downloading') resume(existing);
      return;
    }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final t = DownloadTask(
      id: id,
      item: item,
      season: season,
      episode: episode,
      title: title,
      url: url,
      headers: headers,
      path: '${_dir.path}/${_safe(title)}_$id${_ext(url)}',
    );
    tasks.insert(0, t);
    _changed(true);
    unawaited(_run(t));
  }

  void pause(DownloadTask t) {
    if (t.status == 'downloading') _stop.add(t.id);
  }

  void resume(DownloadTask t) {
    if (t.status == 'paused' || t.status == 'error') unawaited(_run(t));
  }

  Future<void> remove(DownloadTask t) async {
    final wasActive = _active.contains(t.id);
    _stop.add(t.id);
    tasks.remove(t);
    _changed(true);
    if (wasActive) {
      // _run() is still writing to t.path on another async turn. Wait for it to
      // actually acknowledge the stop and close its file handle before we delete
      // the file out from under it (bounded wait so a stuck task can't hang this).
      final c = Completer<void>();
      _stopAck[t.id] = c;
      await c.future.timeout(const Duration(seconds: 8), onTimeout: () {});
      _stopAck.remove(t.id);
    }
    try {
      final f = File(t.path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // best-effort: a lingering partial file isn't a correctness problem
    }
  }

  void _changed(bool force) {
    final now = DateTime.now();
    if (!force && now.difference(_lastNotify).inMilliseconds < 400) return;
    _lastNotify = now;
    notifyListeners();
    if (force || now.difference(_lastSave).inSeconds >= 3) {
      _lastSave = now;
      _p.setString('downloads', jsonEncode(tasks.map((e) => e.toJson()).toList()));
    }
  }

  Future<void> _run(DownloadTask t) async {
    if (!_active.add(t.id)) return;
    _stop.remove(t.id);
    t.status = 'downloading';
    t.error = null;
    _changed(true);

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..autoUncompress = false;
    IOSink? sink;
    try {
      final file = File(t.path);
      var have = await file.exists() ? await file.length() : 0;

      // A resume attempt can be invalidated by the server in two ways we must
      // check for explicitly, rather than trusting the status code alone:
      //  - 416 (no Range satisfiable): could mean "already fully downloaded",
      //    but could also mean our local partial file is stale/too-large for a
      //    link that has changed. We re-check the true length with a HEAD-ish
      //    request before trusting it.
      //  - 206 (partial content): the server might ignore Range and still send
      //    a 206 covering a different span than we asked for. We validate
      //    Content-Range against what we already have on disk.
      // In both mismatch cases we wipe the partial file and restart from zero,
      // once, rather than silently producing a corrupted file.
      var restarted = false;
      while (true) {
        final req = await client.getUrl(Uri.parse(t.url));
        t.headers.forEach((k, v) {
          try {
            req.headers.set(k, v);
          } catch (_) {}
        });
        req.headers.set('Accept-Encoding', 'identity');
        if (have > 0) req.headers.set('Range', 'bytes=$have-');
        final res = await req.close().timeout(const Duration(seconds: 30));

        if (res.statusCode == 416 && have > 0) {
          final trueTotal = await _verifyTrueLength(client, t);
          if (trueTotal != null && trueTotal == have) {
            t.received = have;
            t.total = have;
            t.status = 'done';
            return;
          }
          // Stale/mismatched partial file: wipe it and retry from scratch, once.
          if (restarted) throw 'Server se size match nahi hua (link badal gaya ho sakta hai)';
          restarted = true;
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
          have = 0;
          continue;
        }

        if (res.statusCode != 200 && res.statusCode != 206) {
          await res.drain();
          throw 'Server ne HTTP ${res.statusCode} diya (link expire ho gaya ho sakta hai)';
        }

        var resumed = res.statusCode == 206 && have > 0;
        if (resumed) {
          final range = res.headers.value('content-range');
          final start = _rangeStart(range);
          // A compliant server always sends Content-Range on a 206. If it's
          // missing, or doesn't start where we asked, don't trust the bytes
          // we're about to append — restart from zero instead of risking a
          // corrupted file.
          if (start == null || start != have) {
            if (restarted) {
              throw 'Server ne galat Content-Range diya, resume nahi ho saka';
            }
            restarted = true;
            await res.drain();
            try {
              if (await file.exists()) await file.delete();
            } catch (_) {}
            have = 0;
            continue;
          }
        } else {
          have = 0;
        }

        t.total = res.contentLength > 0 ? res.contentLength + have : 0;
        t.received = have;
        sink = file.openWrite(mode: resumed ? FileMode.append : FileMode.write);

        var stopped = false;
        await for (final chunk in res.timeout(const Duration(seconds: 45))) {
          if (_stop.contains(t.id) || !tasks.contains(t)) {
            stopped = true;
            break;
          }
          sink.add(chunk);
          t.received += chunk.length;
          _changed(false);
        }
        await sink.flush();
        await sink.close();
        sink = null;

        if (stopped) {
          t.status = 'paused';
        } else {
          if (t.total > 0 && t.received < t.total) {
            throw 'Download beech me ruk gaya (${t.received}/${t.total})';
          }
          if (t.total == 0) {
            // No Content-Length from the server (chunked transfer): only trust
            // this as "done" if we actually received bytes, not on a silently
            // empty response.
            if (t.received <= 0) throw 'Server se khaali response mila';
            t.total = t.received;
          }
          t.status = 'done';
        }
        return;
      }
    } catch (e) {
      t.status = 'error';
      t.error = '$e';
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
      _active.remove(t.id);
      _stop.remove(t.id);
      _changed(true);
      _stopAck.remove(t.id)?.complete();
    }
  }

  /// Issues a fresh, non-Range GET to discover the server's true current
  /// content length (used to validate a 416 before trusting it means "done").
  /// Drains and discards the body; this is only safe for the small,
  /// metadata-only purpose of comparing lengths.
  Future<int?> _verifyTrueLength(HttpClient client, DownloadTask t) async {
    // Use HEAD, not GET: this is only a metadata check (does the server's
    // current length match what we already have on disk?). Some providers
    // issue single-use signed links, where a second GET can itself get
    // rejected (observed as HTTP 429). HEAD asks for the same metadata
    // without "spending" the link.
    try {
      final req = await client.headUrl(Uri.parse(t.url));
      t.headers.forEach((k, v) {
        try {
          req.headers.set(k, v);
        } catch (_) {}
      });
      final res = await req.close().timeout(const Duration(seconds: 15));
      final len = res.contentLength;
      await res.drain();
      return len > 0 ? len : null;
    } catch (_) {
      // Some servers don't support HEAD at all (405/501) - in that case we
      // simply can't verify, and the caller falls back to a full restart,
      // which is the safe choice over trusting an unverifiable 416.
      return null;
    }
  }

  /// Parses the start offset out of a `Content-Range: bytes START-END/TOTAL` header.
  int? _rangeStart(String? headerValue) {
    if (headerValue == null) return null;
    final m = RegExp(r'^bytes\s+(\d+)-').firstMatch(headerValue.trim());
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }
}
