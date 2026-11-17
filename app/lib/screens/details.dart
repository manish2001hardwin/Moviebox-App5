import 'package:flutter/material.dart';

import '../downloads.dart';
import '../library.dart';
import '../native.dart';
import 'player.dart';
import '../theme.dart';
import 'widgets.dart';
import 'dart:math' as math;

class DetailsScreen extends StatefulWidget {
  final Item item;
  const DetailsScreen({super.key, required this.item});
  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends State<DetailsScreen> {
  Details? _d;
  String? _error;
  int _season = 1;
  String? _activeId; // selected dub (subject id); null = original
  bool _busy = false;
  bool _fav = false;
  bool _descOpen = false;

  @override
  void initState() {
    super.initState();
    _fav = Library.isFav(widget.item);
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await Api.details(widget.item.provider, widget.item.id);
      if (!mounted) return;
      setState(() {
        _d = d;
        if (d.seasons.isNotEmpty && !d.seasons.containsKey(_season)) {
          _season = d.seasons.keys.first;
        }
        final last = Library.lastFor(widget.item);
        if (last != null && d.seasons.containsKey(last.season)) _season = last.season;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  String get _streamId => _activeId ?? widget.item.id;

  // ---- play flow: streams -> pick release -> (quality) -> resolve -> (subtitle) -> player
  // With download: true the flow ends by queueing a download instead of playing.
  Future<void> _play(int season, int episode, {bool download = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      var releases = await Api.streams(widget.item.provider, _streamId,
          season: season, episode: episode);
      if (!mounted) return;
      if (download) releases = releases.where((r) => !r.isMulti).toList();
      if (releases.isEmpty) {
        _snack(download
            ? 'Download-yogya source nahi mila (Auto/multi-quality streams download nahi hote).'
            : 'No streams found for this title.');
        return;
      }
      releases.sort((a, b) => b.height.compareTo(a.height));

      final Release? rel = (releases.length == 1 && !download)
          ? releases.first
          : await _pickRelease(releases);
      if (rel == null || !mounted) return;

      if (download) {
        await _enqueueDownload(rel, season, episode);
        return;
      }

      int? maxHeight;
      if (rel.isMulti) {
        maxHeight = await _pickQuality();
        if (!mounted) return;
        if (maxHeight == -1) return; // dismissed
        if (maxHeight == 0) maxHeight = null; // auto
      }

      final source = await Api.resolve(rel, maxHeight: maxHeight);
      final subHeaders = <List<String>>[
        for (final h in (source['headers'] as List? ?? [])) ['${h[0]}', '${h[1]}']
      ];

      String? subtitle;
      var capList = <Map<String, String>>[];
      final rid = rel.resourceId;
      if (rel.provider == 'moviebox' && rid != null && rid.isNotEmpty) {
        try {
          final caps = await Api.captions(
            subjectId: _streamId,
            resourceId: rid,
            siblings: _d?.dubs.map((e) => e['subject_id']!).toList() ?? const [],
            season: season,
            episode: episode,
          );
          if (!mounted) return;
          capList = caps;
          if (caps.isNotEmpty) {
            final choice = await _pickSubtitle(caps);
            if (!mounted) return;
            if (choice == '__cancel__') return;
            subtitle = (choice == null || choice.isEmpty) ? null : choice;
          }
        } catch (_) {
          // subtitles are optional; keep going
        }
      }

      final info = await Api.preparePlay(source, subtitle: subtitle);
      if (!mounted) return;
      final entry = Library.entry(widget.item, season, episode);
      final startMs = (entry != null && !entry.finished && entry.positionMs > 30000)
          ? entry.positionMs - 3000
          : 0;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerScreen(
          item: widget.item,
          season: season,
          episode: episode,
          info: info,
          startMs: startMs,
          captions: capList,
          subHeaders: subHeaders,
          title: _d?.isSeries == true
              ? '${widget.item.title} · S$season E$episode'
              : widget.item.title,
        ),
      ));
      if (mounted) setState(() {});
    } catch (e) {
      _snack('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enqueueDownload(Release rel, int season, int episode) async {
    final source = await Api.resolve(rel);
    final url = '${source['url']}';
    final lower = url.toLowerCase();
    if (lower.contains('.mpd') || lower.contains('.m3u8')) {
      _snack('Ye source sirf streaming ke liye hai (DASH/HLS), download nahi ho sakta. Doosra source chuno.');
      return;
    }
    final headers = <String, String>{};
    for (final h in (source['headers'] as List? ?? [])) {
      headers['${h[0]}'] = '${h[1]}';
    }
    final title = _d?.isSeries == true
        ? '${widget.item.title} S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}'
        : widget.item.title;
    await Downloads.I.enqueue(widget.item, season, episode, title, url, headers);
    _snack('Download shuru ho gaya. "Downloads" tab me dekho.');
  }

  Future<Release?> _pickRelease(List<Release> rels) {
    return showModalBottomSheet<Release>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Choose source', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final r in rels)
              ListTile(
                leading: CircleAvatar(
                  child: Text(r.isMulti ? 'AUTO' : (r.quality ?? '?'),
                      style: const TextStyle(fontSize: 10), textAlign: TextAlign.center),
                ),
                title: Text(r.filename, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text([
                  r.sourceLabel,
                  if (r.codec != null) r.codec!,
                  if (r.language != null) r.language!,
                  if (r.sizeText.isNotEmpty) r.sizeText,
                ].join(' · ')),
                onTap: () => Navigator.pop(c, r),
              ),
          ]),
        ),
      ),
    );
  }

  /// returns 0 = Auto, >0 = max height, -1 = dismissed
  Future<int> _pickQuality() async {
    final r = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('Quality', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          for (final q in const [
            [0, 'Auto (best available)'],
            [1080, '1080p'],
            [720, '720p'],
            [480, '480p'],
          ])
            ListTile(title: Text(q[1] as String), onTap: () => Navigator.pop(c, q[0] as int)),
        ]),
      ),
    );
    return r ?? -1;
  }

  /// returns subtitle url, '' for none, '__cancel__' when dismissed
  Future<String> _pickSubtitle(List<Map<String, String>> caps) async {
    final r = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Subtitles', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            ListTile(
                leading: const Icon(Icons.subtitles_off_outlined),
                title: const Text('No subtitles'),
                onTap: () => Navigator.pop(c, '')),
            for (final s in caps)
              ListTile(
                leading: const Icon(Icons.subtitles_outlined),
                title: Text(s['name']!),
                onTap: () => Navigator.pop(c, s['url']),
              ),
          ]),
        ),
      ),
    );
    return r ?? '__cancel__';
  }

  // ---------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      body: _error != null
          ? Stack(children: [
              ErrorView(message: _error!, onRetry: _load),
              _topBar(),
            ])
          : d == null
              ? Stack(children: [
                  const Center(child: CircularProgressIndicator(color: C.accent)),
                  _topBar(),
                ])
              : Stack(children: [_content(d), _topBar()]),
    );
  }

  Widget _circle(IconData icon, VoidCallback onTap) => Material(
        color: Colors.black54,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(9), child: Icon(icon, size: 22)),
        ),
      );

  Widget _topBar() {
    final item = widget.item;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(children: [
            _circle(Icons.arrow_back, () => Navigator.of(context).maybePop()),
            const Spacer(),
            _circle(_fav ? Icons.check : Icons.add, () async {
              await Library.toggleFav(item);
              if (mounted) setState(() => _fav = Library.isFav(item));
            }),
          ]),
        ),
      ),
    );
  }

  Widget _content(Details d) {
    final item = widget.item;
    final last = Library.lastFor(item);
    final episodes = d.seasons[_season] ?? const <Episode>[];
    final heroH = math.min(MediaQuery.of(context).size.height * 0.55, 500.0);
    final desc = d.description ?? '';

    return ListView(padding: EdgeInsets.zero, children: [
      SizedBox(
        height: heroH,
        child: Stack(fit: StackFit.expand, children: [
          PosterImage(item.poster ?? d.item.poster, label: item.title),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.3, 0.65, 1],
                colors: [Color(0x99000000), Colors.transparent, Colors.transparent, C.bg],
              ),
            ),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(d.item.title,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, height: 1.1)),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (d.item.year != null)
              Text(d.item.year!, style: const TextStyle(color: C.text2, fontWeight: FontWeight.w600)),
            if (d.rating != null)
              Text('★ ${d.rating}',
                  style: const TextStyle(color: Color(0xFFF5C518), fontWeight: FontWeight.w700)),
            if (d.duration != null)
              Text(d.duration!, style: const TextStyle(color: C.text2, fontWeight: FontWeight.w600)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white38),
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text('HD', style: TextStyle(fontSize: 10, color: C.text2, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 16),

          // --- primary actions
          if (!d.isSeries) ...[
            _bigButton(
              icon: _busy ? null : Icons.play_arrow_rounded,
              label: last != null && !last.finished ? 'Resume' : 'Play',
              busy: _busy,
              white: true,
              onTap: _busy ? null : () => _play(0, 0),
            ),
            const SizedBox(height: 8),
            _bigButton(
              icon: Icons.download_rounded,
              label: 'Download',
              white: false,
              onTap: _busy ? null : () => _play(0, 0, download: true),
            ),
          ] else if (last != null) ...[
            _bigButton(
              icon: _busy ? null : Icons.play_arrow_rounded,
              label: 'Resume S${last.season} E${last.episode}',
              busy: _busy,
              white: true,
              onTap: _busy ? null : () => _play(last.season, last.episode),
            ),
          ],

          // --- description
          if (desc.isNotEmpty) ...[
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => setState(() => _descOpen = !_descOpen),
              child: Text(desc,
                  maxLines: _descOpen ? null : 4,
                  overflow: _descOpen ? TextOverflow.visible : TextOverflow.ellipsis,
                  style: const TextStyle(height: 1.45, fontSize: 14)),
            ),
          ],
          if (d.stars != null && d.stars!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Starring: ${d.stars}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: C.text2, fontSize: 12.5)),
          ],
          if (d.genres.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Genres: ${d.genres.join(', ')}',
                style: const TextStyle(color: C.text2, fontSize: 12.5)),
          ],

          // --- language
          if (d.dubs.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text('Language', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              ChoiceChip(
                label: const Text('Original'),
                selected: _activeId == null,
                onSelected: (_) => setState(() => _activeId = null),
              ),
              for (final dub in d.dubs)
                ChoiceChip(
                  label: Text(dub['label']!),
                  selected: _activeId == dub['subject_id'],
                  onSelected: (_) => setState(() => _activeId = dub['subject_id']),
                ),
            ]),
          ],

          // --- episodes
          if (d.isSeries) ...[
            const SizedBox(height: 22),
            const Text('Episodes', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
            const SizedBox(height: 10),
            if (d.seasons.length > 1)
              SizedBox(
                height: 44,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final sn in d.seasons.keys)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text('Season $sn'),
                        selected: _season == sn,
                        onSelected: (_) => setState(() => _season = sn),
                      ),
                    ),
                ]),
              ),
            const SizedBox(height: 6),
            for (final e in episodes) _episodeTile(item, e),
          ],
        ]),
      ),
    ]);
  }

  Widget _bigButton({
    required String label,
    required bool white,
    required VoidCallback? onTap,
    IconData? icon,
    bool busy = false,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: white ? Colors.white : const Color(0xFF2B2B33),
          foregroundColor: white ? Colors.black : Colors.white,
          disabledBackgroundColor: white ? Colors.white70 : const Color(0xFF2B2B33),
          disabledForegroundColor: white ? Colors.black54 : Colors.white54,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (busy)
            const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black54))
          else if (icon != null)
            Icon(icon, size: 26),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  Widget _episodeTile(Item item, Episode e) {
    final h = Library.entry(item, e.season, e.number);
    final dl = Downloads.I.find(item, e.season, e.number);
    final dlIcon = dl == null
        ? Icons.download_outlined
        : (dl.status == 'done' ? Icons.download_done : Icons.downloading);
    return InkWell(
      onTap: _busy ? null : () => _play(e.season, e.number),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(8)),
            child: Text('${e.number}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: C.text2)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.title?.isNotEmpty == true ? e.title! : 'Episode ${e.number}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              if (h != null) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: h.progress.clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: Colors.white12,
                  color: C.accent,
                ),
              ],
            ]),
          ),
          IconButton(
            icon: Icon(dlIcon, color: C.text2),
            tooltip: 'Download',
            onPressed: _busy ? null : () => _play(e.season, e.number, download: true),
          ),
          const Icon(Icons.play_circle_outline, size: 30),
        ]),
      ),
    );
  }
}
