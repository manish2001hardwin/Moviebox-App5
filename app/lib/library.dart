import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'native.dart';

/// Local-only watch history + favorites (stored on the phone, nothing is sent anywhere).
class HistoryEntry {
  final Item item;
  final int season;
  final int episode;
  final int positionMs;
  final int durationMs;
  final int updatedAt;
  HistoryEntry(this.item, this.season, this.episode, this.positionMs,
      this.durationMs, this.updatedAt);

  double get progress => durationMs <= 0 ? 0 : positionMs / durationMs;
  bool get finished => durationMs > 0 && progress >= 0.95;

  Map<String, dynamic> toJson() => {
        'item': item.toJson(),
        'season': season,
        'episode': episode,
        'pos': positionMs,
        'dur': durationMs,
        'at': updatedAt,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        Item.fromStored(Map<String, dynamic>.from(j['item'])),
        j['season'] ?? 0,
        j['episode'] ?? 0,
        j['pos'] ?? 0,
        j['dur'] ?? 0,
        j['at'] ?? 0,
      );

  String get label => item.isSeries || season > 0
      ? '${item.title} · S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
      : item.title;
}

class Library {
  static late SharedPreferences _p;
  static final Map<String, HistoryEntry> _history = {};
  static final Map<String, Item> _favs = {};

  static Future<void> init() async {
    _p = await SharedPreferences.getInstance();

    // History and favorites are independent stores: a corrupted history blob
    // must not prevent favorites from loading, and vice versa (previously
    // both lived in one try/catch, so either could wipe out the other).
    try {
      final raw = jsonDecode(_p.getString('history') ?? '{}');
      if (raw is Map) {
        raw.forEach((k, v) {
          // One bad record shouldn't drop every other history entry.
          try {
            _history['$k'] = HistoryEntry.fromJson(Map<String, dynamic>.from(v));
          } catch (_) {}
        });
      }
    } catch (_) {
      // 'history' value wasn't valid JSON at all: leave it empty, don't throw
    }

    try {
      final raw = jsonDecode(_p.getString('favs') ?? '[]');
      if (raw is List) {
        for (final e in raw) {
          try {
            final it = Item.fromStored(Map<String, dynamic>.from(e));
            _favs[it.key] = it;
          } catch (_) {}
        }
      }
    } catch (_) {
      // 'favs' value wasn't valid JSON at all: leave it empty, don't throw
    }
  }

  static String _hk(Item i, int s, int e) => '${i.key}:$s:$e';

  static Future<void> _saveHistory() async {
    try {
      await _p.setString(
          'history', jsonEncode(_history.map((k, v) => MapEntry(k, v.toJson()))));
    } catch (_) {
      // best-effort: in-memory history stays correct for this session even if
      // the write to disk failed (e.g. storage full)
    }
  }

  static Future<void> saveProgress(
      Item item, int season, int episode, int posMs, int durMs) async {
    if (durMs <= 0 || posMs < 5000) return;
    // Clamp instead of trusting the player: a transient seek/EOF glitch can
    // report a position past the duration, which would otherwise persist a
    // >100% progress value forever.
    final clampedPos = posMs > durMs ? durMs : posMs;
    _history[_hk(item, season, episode)] = HistoryEntry(
        item, season, episode, clampedPos, durMs, DateTime.now().millisecondsSinceEpoch);
    // keep the store small
    if (_history.length > 150) {
      final sorted = _history.entries.toList()
        ..sort((a, b) => a.value.updatedAt.compareTo(b.value.updatedAt));
      for (final e in sorted.take(_history.length - 150)) {
        _history.remove(e.key);
      }
    }
    await _saveHistory();
  }

  static HistoryEntry? entry(Item item, int season, int episode) =>
      _history[_hk(item, season, episode)];

  /// Most recent entry for a title (any episode).
  static HistoryEntry? lastFor(Item item) {
    HistoryEntry? best;
    for (final h in _history.values) {
      if (h.item.key == item.key && (best == null || h.updatedAt > best.updatedAt)) {
        best = h;
      }
    }
    return best;
  }

  static List<HistoryEntry> continueWatching() {
    final latest = <String, HistoryEntry>{};
    for (final h in _history.values) {
      final cur = latest[h.item.key];
      if (cur == null || h.updatedAt > cur.updatedAt) latest[h.item.key] = h;
    }
    final list = latest.values.where((h) => !h.finished).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  static Future<void> removeHistoryFor(Item item) async {
    _history.removeWhere((_, v) => v.item.key == item.key);
    await _saveHistory();
  }

  static bool isFav(Item i) => _favs.containsKey(i.key);
  static List<Item> favorites() => _favs.values.toList();

  static Future<void> toggleFav(Item i) async {
    if (_favs.containsKey(i.key)) {
      _favs.remove(i.key);
    } else {
      _favs[i.key] = i;
    }
    try {
      await _p.setString('favs', jsonEncode(_favs.values.map((e) => e.toJson()).toList()));
    } catch (_) {
      // best-effort persistence; the in-memory toggle already happened
    }
  }
}
