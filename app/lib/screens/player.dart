import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../library.dart';
import '../native.dart';
import '../theme.dart';

class _FitOpt {
  final String label;
  final BoxFit fit;
  final double? aspect;
  const _FitOpt(this.label, this.fit, this.aspect);
}

const _fitOpts = [
  _FitOpt('Fit (original)', BoxFit.contain, null),
  _FitOpt('Zoom (crop)', BoxFit.cover, null),
  _FitOpt('Stretch (fill screen)', BoxFit.fill, null),
  _FitOpt('16:9', BoxFit.contain, 16 / 9),
  _FitOpt('4:3', BoxFit.contain, 4 / 3),
];

class PlayerScreen extends StatefulWidget {
  final Item item;
  final int season;
  final int episode;
  final PlayInfo info;
  final int startMs;
  final String title;
  final List<Map<String, String>> captions; // external subtitles to offer
  final List<List<String>> subHeaders; // headers needed to fetch those subtitles
  const PlayerScreen({
    super.key,
    required this.item,
    required this.season,
    required this.episode,
    required this.info,
    required this.startMs,
    required this.title,
    this.captions = const [],
    this.subHeaders = const [],
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  // Bigger demuxer cache = smoother playback on flaky mobile networks.
  late final Player _player = Player(
    configuration: PlayerConfiguration(bufferSize: 64 * 1024 * 1024),
  );
  late final VideoController _video = VideoController(_player);
  Timer? _saver;
  StreamSubscription? _errSub;
  String? _error;

  int _fitIndex = 0;
  int _orient = 0; // 0 landscape (both), 1 portrait, 2 auto-rotate
  double _speed = 1.0;
  double _volume = 100.0;
  double _subSize = 34;

  @override
  void initState() {
    super.initState();
    _applyOrientation();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _errSub = _player.stream.error.listen((e) {
      if (mounted && e.isNotEmpty) setState(() => _error = e);
    });
    _start();
    _saver = Timer.periodic(const Duration(seconds: 10), (_) => _save());
  }

  Future<void> _start() async {
    try {
      // allow volume boost above 100% (mpv default cap is 130)
      try {
        await (_player.platform as dynamic).setProperty('volume-max', '200');
      } catch (_) {}
      final i = widget.info;
      await _player.open(
        Media(
          i.url,
          httpHeaders: i.headers.isEmpty ? null : i.headers,
          start: widget.startMs > 0 ? Duration(milliseconds: widget.startMs) : null,
        ),
      );
      final sub = i.subtitle;
      if (sub != null && sub.isNotEmpty) {
        await _player.setSubtitleTrack(SubtitleTrack.uri(sub));
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _save() async {
    final pos = _player.state.position.inMilliseconds;
    final dur = _player.state.duration.inMilliseconds;
    await Library.saveProgress(widget.item, widget.season, widget.episode, pos, dur);
  }

  void _applyOrientation() {
    switch (_orient) {
      case 1:
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
        break;
      case 2:
        SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        break;
      default:
        SystemChrome.setPreferredOrientations(
            [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
  }

  @override
  void dispose() {
    _saver?.cancel();
    _errSub?.cancel();
    _save();
    _player.dispose();
    Api.stopProxy();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ----------------------------------------------------------------- helpers

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
  }

  Future<void> _sheet(String title, List<Widget> children) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16161D),
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.85),
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            ...children,
          ]),
        ),
      ),
    );
  }

  Widget _opt(String label, bool selected, VoidCallback onTap) => ListTile(
        dense: true,
        title: Text(label),
        trailing: selected ? const Icon(Icons.check, color: Colors.redAccent) : null,
        onTap: () {
          Navigator.of(context).pop();
          onTap();
        },
      );

  String _trackName(String? title, String? lang, String id) {
    final parts = <String>[
      if (title != null && title.isNotEmpty) title,
      if (lang != null && lang.isNotEmpty && lang != title) lang,
    ];
    return parts.isEmpty ? 'Track $id' : parts.join(' · ');
  }

  // ------------------------------------------------------------------ sheets

  void _audioSheet() {
    final tracks =
        _player.state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    final cur = _player.state.track.audio;
    _sheet('Audio / Language', [
      if (tracks.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Is video me sirf ek audio track hai.'),
        ),
      for (final t in tracks)
        _opt(_trackName(t.title, t.language, t.id), cur.id == t.id, () => _player.setAudioTrack(t)),
    ]);
  }

  void _subSheet() {
    final embedded =
        _player.state.tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
    final cur = _player.state.track.subtitle;
    _sheet('Subtitles', [
      _opt('Off', cur.id == 'no', () => _player.setSubtitleTrack(SubtitleTrack.no())),
      for (final t in embedded)
        _opt(_trackName(t.title, t.language, t.id), cur.id == t.id,
            () => _player.setSubtitleTrack(t)),
      for (final c in widget.captions) _opt(c['name'] ?? 'Subtitle', false, () => _loadExternalSub(c)),
      if (embedded.isEmpty && widget.captions.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Is video ke liye subtitles nahi mile.'),
        ),
      const Divider(),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Text('Subtitle size'),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Wrap(spacing: 8, children: [
          for (final e in const [
            ['Small', 26.0],
            ['Medium', 34.0],
            ['Large', 44.0],
          ])
            ChoiceChip(
              label: Text(e[0] as String),
              selected: _subSize == (e[1] as double),
              onSelected: (_) {
                Navigator.of(context).pop();
                setState(() => _subSize = e[1] as double);
              },
            ),
        ]),
      ),
    ]);
  }

  Future<void> _loadExternalSub(Map<String, String> c) async {
    _toast('Subtitle load ho raha hai…');
    try {
      final path = await Api.fetchSubtitle(c['url']!, widget.subHeaders, name: c['name']);
      await _player.setSubtitleTrack(SubtitleTrack.uri(path, title: c['name']));
    } catch (e) {
      _toast('Subtitle load nahi hua: $e');
    }
  }

  void _speedSheet() {
    _sheet('Playback speed', [
      for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
        _opt('${r}x${r == 1.0 ? ' (normal)' : ''}', _speed == r, () {
          setState(() => _speed = r);
          _player.setRate(r);
        }),
    ]);
  }

  void _fitSheet() {
    _sheet('Screen size', [
      for (var i = 0; i < _fitOpts.length; i++)
        _opt(_fitOpts[i].label, _fitIndex == i, () => setState(() => _fitIndex = i)),
    ]);
  }

  void _volumeSheet() {
    _sheet('Volume (boost up to 200%)', [
      StatefulBuilder(
        builder: (c, set) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: Row(children: [
            const Icon(Icons.volume_up),
            Expanded(
              child: Slider(
                value: _volume.clamp(0.0, 200.0).toDouble(),
                min: 0,
                max: 200,
                divisions: 40,
                label: '${_volume.round()}%',
                onChanged: (v) {
                  set(() {});
                  _volume = v;
                  _player.setVolume(v);
                },
              ),
            ),
            SizedBox(width: 48, child: Text('${_volume.round()}%')),
          ]),
        ),
      ),
    ]);
  }

  void _cycleOrientation() {
    setState(() => _orient = (_orient + 1) % 3);
    _applyOrientation();
    _toast(['Landscape lock', 'Portrait lock', 'Auto-rotate'][_orient]);
  }

  // --------------------------------------------------------------------- UI

  Widget _btn(IconData icon, String tip, VoidCallback onTap, {double size = 24}) => IconButton(
        icon: Icon(icon, color: Colors.white, size: size),
        tooltip: tip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        onPressed: onTap,
      );

  void _seekBy(int seconds) {
    final dur = _player.state.duration;
    var t = _player.state.position + Duration(seconds: seconds);
    if (t < Duration.zero) t = Duration.zero;
    if (dur > Duration.zero && t > dur) t = dur;
    _player.seek(t);
  }

  MaterialVideoControlsThemeData _theme() {
    return MaterialVideoControlsThemeData(
      volumeGesture: true, // swipe on the right half
      brightnessGesture: true, // swipe on the left half
      seekGesture: true,
      seekOnDoubleTap: true,
      seekBarColor: Colors.white24,
      seekBarPositionColor: C.accent,
      seekBarBufferColor: Colors.white38,
      seekBarThumbColor: C.accent,
      seekBarThumbSize: 16,
      primaryButtonBar: [
        const Spacer(flex: 2),
        _btn(Icons.replay_10, 'Back 10s', () => _seekBy(-10), size: 42),
        const Spacer(),
        const MaterialPlayOrPauseButton(iconSize: 64),
        const Spacer(),
        _btn(Icons.forward_10, 'Forward 10s', () => _seekBy(10), size: 42),
        const Spacer(flex: 2),
      ],
      topButtonBar: [
        _btn(Icons.arrow_back, 'Back', () => Navigator.of(context).maybePop(), size: 26),
        const SizedBox(width: 6),
        Expanded(
          child: Text(widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
        ),
      ],
      bottomButtonBar: [
        const MaterialPositionIndicator(),
        const Spacer(),
        _btn(Icons.subtitles_outlined, 'Subtitles', _subSheet),
        _btn(Icons.audiotrack_outlined, 'Audio / Language', _audioSheet),
        _btn(Icons.speed, 'Speed', _speedSheet),
        _btn(Icons.aspect_ratio, 'Screen size', _fitSheet),
        _btn(Icons.volume_up_outlined, 'Volume boost', _volumeSheet),
        _btn(Icons.screen_rotation, 'Rotate', _cycleOrientation),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _theme();
    final fit = _fitOpts[_fitIndex];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(
          child: MaterialVideoControlsTheme(
            normal: t,
            fullscreen: t,
            child: Video(
              controller: _video,
              fit: fit.fit,
              aspectRatio: fit.aspect,
              subtitleViewConfiguration: SubtitleViewConfiguration(
                style: TextStyle(
                  height: 1.4,
                  fontSize: _subSize,
                  color: Colors.white,
                  backgroundColor: const Color(0xAA000000),
                ),
              ),
            ),
          ),
        ),
        if (_error != null)
          Center(
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.all(16),
              decoration:
                  BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline, color: Colors.redAccent),
                const SizedBox(height: 8),
                Text('Playback problem:\n$_error', textAlign: TextAlign.center),
                const SizedBox(height: 8),
                TextButton(
                    onPressed: () => Navigator.of(context).maybePop(), child: const Text('Back')),
              ]),
            ),
          ),
      ]),
    );
  }
}
