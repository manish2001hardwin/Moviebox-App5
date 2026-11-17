import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// Thin dart:ffi layer over libmoviebox_mobile.so (Rust core).
/// Every call is JSON in / JSON out and runs on a background isolate,
/// so the UI thread is never blocked by network work.
const _libName = 'libmoviebox_mobile.so';

typedef _InitC = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _CallC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeC = Void Function(Pointer<Utf8>);
typedef _FreeD = void Function(Pointer<Utf8>);

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

// Opening the .so and resolving symbols on every single call was wasted
// native-call overhead; the library stays loaded for the process lifetime
// anyway, so resolve it once (lazily) and reuse the handle.
DynamicLibrary? _lib;
DynamicLibrary _library() => _lib ??= DynamicLibrary.open(_libName);

String _callSync(String method, String argsJson) {
  final lib = _library();
  final call = lib.lookupFunction<_CallC, _CallC>('mb_call');
  final free = lib.lookupFunction<_FreeC, _FreeD>('mb_free');
  final m = method.toNativeUtf8();
  final a = argsJson.toNativeUtf8();
  Pointer<Utf8>? r;
  try {
    r = call(m, a);
    // toDartString() copies the bytes into a Dart string; if it somehow throws
    // (malformed UTF-8), the finally block below still frees the native buffer.
    return r.toDartString();
  } finally {
    if (r != null) free(r);
    malloc.free(m);
    malloc.free(a);
  }
}

class Api {
  static void init(String dataDir) {
    final lib = _library();
    final init = lib.lookupFunction<_InitC, _InitC>('mb_init');
    final free = lib.lookupFunction<_FreeC, _FreeD>('mb_free');
    final d = dataDir.toNativeUtf8();
    Pointer<Utf8>? r;
    try {
      r = init(d);
      // Free the native buffer in `finally` below regardless of whether
      // decoding it succeeds, instead of only freeing on the success path.
      final res = jsonDecode(r.toDartString()) as Map<String, dynamic>;
      if (res['ok'] != true) {
        throw ApiException('Core init failed: ${res['error']}');
      }
    } finally {
      if (r != null) free(r);
      malloc.free(d);
    }
  }

  static Future<dynamic> call(String method,
      [Map<String, dynamic> args = const {}]) async {
    final argsJson = jsonEncode(args);
    final raw = await Isolate.run(() => _callSync(method, argsJson));
    final res = jsonDecode(raw) as Map<String, dynamic>;
    if (res['ok'] == true) return res['data'];
    throw ApiException('${res['error']}');
  }

  static Future<List<dynamic>> providers() async =>
      (await call('providers')) as List<dynamic>;

  static Future<List<Item>> search(String provider, String query,
      {int page = 1}) async {
    final r = await call(
        'search', {'provider': provider, 'query': query, 'page': page});
    return (r as List).map((e) => Item.fromJson(e)).toList();
  }

  static Future<List<Item>> homepage({String tab = '2', int page = 1}) async {
    final r = await call('homepage', {'tab': tab, 'page': page});
    return ((r as Map)['items'] as List).map((e) => Item.fromJson(e)).toList();
  }

  static Future<Details> details(String provider, String id) async =>
      Details.fromJson(await call('details', {'provider': provider, 'id': id}));

  static Future<List<Release>> streams(String provider, String id,
      {int season = 0, int episode = 0}) async {
    final r = await call('streams', {
      'provider': provider,
      'id': id,
      'season': season,
      'episode': episode,
    });
    return (r as List).map((e) => Release(Map<String, dynamic>.from(e))).toList();
  }

  static Future<Map<String, dynamic>> resolve(Release rel,
      {int mirror = 0, int? maxHeight}) async {
    final r = await call('resolve', {
      'release': rel.raw,
      'mirror': mirror,
      if (maxHeight != null) 'max_height': maxHeight,
    });
    return Map<String, dynamic>.from(r as Map);
  }

  static Future<List<Map<String, String>>> captions(
      {required String subjectId,
      required String resourceId,
      List<String> siblings = const [],
      int season = 0,
      int episode = 0}) async {
    final r = await call('captions', {
      'subject_id': subjectId,
      'resource_id': resourceId,
      'siblings': siblings,
      'season': season,
      'episode': episode,
    });
    return (r as List)
        .map((e) => {'name': '${e['name']}', 'url': '${e['url']}'})
        .toList();
  }

  static Future<PlayInfo> preparePlay(Map<String, dynamic> source,
      {String? subtitle}) async {
    final r = await call('prepare_play', {
      'source': source,
      if (subtitle != null) 'subtitle': subtitle,
    });
    return PlayInfo.fromJson(Map<String, dynamic>.from(r as Map));
  }

  /// Downloads a subtitle (with the stream headers) and returns the local file path.
  static Future<String> fetchSubtitle(String url, List<List<String>> headers,
      {String? name}) async {
    final r = await call('subtitle_fetch', {
      'url': url,
      'headers': headers,
      if (name != null) 'name': name,
    });
    return '$r';
  }

  static Future<void> stopProxy() async {
    try {
      await call('stop_proxy');
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// Models (thin wrappers over the Rust JSON)
// ---------------------------------------------------------------------------

class Item {
  final String provider;
  final String id;
  final String title;
  final bool isSeries;
  final String? year;
  final String? poster;

  Item(this.provider, this.id, this.title, this.isSeries, this.year, this.poster);

  factory Item.fromJson(dynamic j) {
    final idm = j['id'] as Map;
    return Item(
      '${idm['provider']}',
      '${idm['value']}',
      '${j['title']}',
      j['media_type'] == 'series',
      j['year'] as String?,
      j['poster_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'id': id,
        'title': title,
        'series': isSeries,
        'year': year,
        'poster': poster,
      };

  factory Item.fromStored(Map<String, dynamic> j) => Item(
        j['provider'], j['id'], j['title'], j['series'] == true, j['year'], j['poster']);

  String get key => '$provider:$id';
}

class Episode {
  final int season;
  final int number;
  final String? title;
  Episode(this.season, this.number, this.title);
}

class Details {
  final Item item;
  final String? description;
  final String? rating;
  final String? duration;
  final String? stars;
  final List<String> genres;
  final Map<int, List<Episode>> seasons;
  final List<Map<String, String>> dubs; // {subject_id, label}

  Details(this.item, this.description, this.rating, this.duration, this.stars,
      this.genres, this.seasons, this.dubs);

  factory Details.fromJson(dynamic j) {
    final seasons = <int, List<Episode>>{};
    for (final s in (j['seasons'] as List? ?? [])) {
      final seasonNo = (s['number'] as num).toInt();
      seasons[seasonNo] = [
        for (final e in (s['episodes'] as List? ?? []))
          Episode(seasonNo, (e['number'] as num).toInt(), e['title'] as String?)
      ];
    }
    return Details(
      Item.fromJson(j),
      j['description'] as String?,
      j['imdb_rating'] as String?,
      j['duration'] as String?,
      j['stars'] as String?,
      [for (final g in (j['genres'] as List? ?? [])) '$g'],
      seasons,
      [
        for (final d in (j['dubs'] as List? ?? []))
          {'subject_id': '${d['subject_id']}', 'label': '${d['label']}'}
      ],
    );
  }

  bool get isSeries => item.isSeries || seasons.isNotEmpty;
}

class Release {
  final Map<String, dynamic> raw;
  Release(this.raw);

  String get provider => '${raw['provider']}';
  String get filename => '${raw['filename']}';
  String? get quality => raw['quality'] as String?;
  String? get codec => raw['codec'] as String?;
  String? get language => raw['language'] as String?;
  int? get sizeBytes => (raw['size_bytes'] as num?)?.toInt();
  String? get resourceId => raw['resource_id'] as String?;
  int get mirrorCount => (raw['mirrors'] as List?)?.length ?? 0;
  String get sourceLabel {
    final m = raw['mirrors'] as List?;
    return (m != null && m.isNotEmpty) ? '${m.first['label']}' : provider;
  }

  bool get isMulti {
    final q = (quality ?? '').toLowerCase();
    return q == 'multi' || q == 'multi-res';
  }

  int get height {
    final q = (quality ?? '').trim().toLowerCase();
    if (q == '4k' || q == 'uhd') return 2160;
    return int.tryParse(q.replaceAll('p', '')) ?? (isMulti ? 9999 : 0);
  }

  String get sizeText {
    final b = sizeBytes;
    if (b == null || b <= 0) return '';
    const gb = 1024 * 1024 * 1024;
    if (b >= gb) return '${(b / gb).toStringAsFixed(1)} GB';
    return '${(b / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
}

class PlayInfo {
  final String url;
  final Map<String, String> headers;
  final String? subtitle;
  final bool proxied;
  PlayInfo(this.url, this.headers, this.subtitle, this.proxied);

  factory PlayInfo.fromJson(Map<String, dynamic> j) {
    final h = <String, String>{};
    for (final p in (j['headers'] as List? ?? [])) {
      h['${p[0]}'] = '${p[1]}';
    }
    return PlayInfo(j['url'] as String, h, j['subtitle'] as String?, j['proxied'] == true);
  }
}
