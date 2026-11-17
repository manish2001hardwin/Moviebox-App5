import 'dart:async';

import 'package:flutter/material.dart';

import '../library.dart';
import '../native.dart';
import '../theme.dart';
import 'details.dart';
import 'downloads.dart';
import 'widgets.dart';

void openDetails(BuildContext context, Item it) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => DetailsScreen(item: it)));
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      _HomeTab(onSearch: () => setState(() => _tab = 1)),
      const SafeArea(bottom: false, child: _SearchTab()),
      const SafeArea(bottom: false, child: DownloadsScreen()),
      SafeArea(bottom: false, child: _MySpaceTab(key: UniqueKey())),
    ];
    return Scaffold(
      body: IndexedStack(index: _tab, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_filled), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.search), selectedIcon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(icon: Icon(Icons.download_outlined), selectedIcon: Icon(Icons.download), label: 'Downloads'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'My Space'),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------- Home

class _HomeTab extends StatefulWidget {
  final VoidCallback onSearch;
  const _HomeTab({required this.onSearch});
  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> with AutomaticKeepAliveClientMixin {
  final List<Item> _all = [];
  int _nextPage = 1;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<List<Item>> _pages(int from, int count) async {
    String? firstError;
    final results = await Future.wait([
      for (var p = from; p < from + count; p++)
        Api.homepage(page: p).catchError((e) {
          firstError ??= '$e';
          return <Item>[];
        }),
    ]);
    final out = <Item>[];
    final seen = <String>{};
    for (final r in results) {
      for (final it in r) {
        if (seen.add(it.key)) out.add(it);
      }
    }
    if (out.isEmpty && firstError != null) throw firstError!;
    return out;
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _pages(1, 3);
      if (!mounted) return;
      setState(() {
        _all
          ..clear()
          ..addAll(r);
        _nextPage = 4;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final r = await _pages(_nextPage, 2);
      if (!mounted) return;
      setState(() {
        final seen = _all.map((e) => e.key).toSet();
        _all.addAll(r.where((e) => !seen.contains(e.key)));
        _nextPage += 2;
      });
    } catch (_) {
      // ignore: keep what we have
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_all.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator(color: C.accent));
    }
    if (_all.isEmpty) {
      return SafeArea(child: ErrorView(message: _error ?? 'Nothing to show right now.', onRetry: _refresh));
    }
    final hero = _all.firstWhere((e) => e.poster != null && e.poster!.isNotEmpty, orElse: () => _all.first);
    final rest = _all.where((e) => e.key != hero.key).toList();
    final movies = rest.where((e) => !e.isSeries).toList();
    final shows = rest.where((e) => e.isSeries).toList();
    final cont = Library.continueWatching();
    final favs = Library.favorites();
    final top = MediaQuery.of(context).padding.top;

    return RefreshIndicator(
      color: C.accent,
      backgroundColor: C.surface2,
      onRefresh: _refresh,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Stack(children: [
            HeroBanner(item: hero, onPlay: () => openDetails(context, hero)),
            Positioned(
              top: top + 6,
              left: 16,
              right: 8,
              child: Row(children: [
                const Text(
                  'MELYQON',
                  style: TextStyle(
                    color: C.accent,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                    shadows: [Shadow(blurRadius: 10, color: Colors.black87)],
                  ),
                ),
                const Spacer(),
                IconButton(icon: const Icon(Icons.search, size: 28), onPressed: widget.onSearch),
              ]),
            ),
          ]),
          ContinueRow(entries: cont, onTap: (it) => openDetails(context, it)),
          PosterRow(
              title: 'Trending now',
              items: rest.take(16).toList(),
              onTap: (it) => openDetails(context, it)),
          PosterRow(title: 'My List', items: favs, onTap: (it) => openDetails(context, it)),
          PosterRow(title: 'Movies', items: movies, onTap: (it) => openDetails(context, it)),
          PosterRow(title: 'TV shows', items: shows, onTap: (it) => openDetails(context, it)),
          if (rest.length > 16)
            PosterRow(
                title: 'More to explore',
                items: rest.skip(16).toList(),
                onTap: (it) => openDetails(context, it)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: Center(
              child: _loadingMore
                  ? const CircularProgressIndicator(color: C.accent)
                  : OutlinedButton(
                      onPressed: _more,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white24),
                      ),
                      child: const Text('Load more'),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------- Search

class _SearchTab extends StatefulWidget {
  const _SearchTab();
  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> with AutomaticKeepAliveClientMixin {
  final _ctl = TextEditingController();
  Timer? _debounce;
  List<Item> _items = [];
  List<dynamic> _providers = [];
  String _provider = 'moviebox';
  bool _loading = false;
  String? _error;
  int _seq = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Api.providers().then((p) {
      if (mounted) setState(() => _providers = p);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), _search);
  }

  Future<void> _search() async {
    final q = _ctl.text.trim();
    if (q.isEmpty) {
      // Bump the sequence so any still-in-flight request from before the
      // clear can't land afterwards and silently repopulate the list.
      ++_seq;
      setState(() {
        _items = [];
        _error = null;
        _loading = false;
      });
      return;
    }
    final mySeq = ++_seq; // ignore out-of-order responses
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Api.search(_provider, q);
      if (mounted && mySeq == _seq) setState(() => _items = r);
    } catch (e) {
      if (mounted && mySeq == _seq) setState(() => _error = '$e');
    } finally {
      if (mounted && mySeq == _seq) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: TextField(
          controller: _ctl,
          onChanged: _onChanged,
          onSubmitted: (_) => _search(),
          textInputAction: TextInputAction.search,
          cursorColor: C.accent,
          decoration: InputDecoration(
            hintText: 'Search movies, shows…',
            hintStyle: const TextStyle(color: C.text2),
            prefixIcon: const Icon(Icons.search, color: C.text2),
            filled: true,
            fillColor: C.surface2,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
            suffixIcon: _ctl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, color: C.text2),
                    onPressed: () {
                      _ctl.clear();
                      _search();
                    }),
          ),
        ),
      ),
      if (_providers.length > 1)
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final p in _providers)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                  child: ChoiceChip(
                    label: Text('${p['label']}'),
                    selected: _provider == p['id'],
                    onSelected: (_) {
                      setState(() => _provider = '${p['id']}');
                      _search();
                    },
                  ),
                ),
            ],
          ),
        ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: C.accent))
            : _error != null
                ? ErrorView(message: _error!, onRetry: _search)
                : _items.isEmpty
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(_ctl.text.isEmpty ? Icons.movie_filter_outlined : Icons.search_off,
                              size: 56, color: Colors.white24),
                          const SizedBox(height: 10),
                          Text(_ctl.text.isEmpty ? 'Find something to watch' : 'No results found',
                              style: const TextStyle(color: C.text2)),
                        ]),
                      )
                    : PosterGrid(items: _items, onTap: (it) => openDetails(context, it)),
      ),
    ]);
  }
}

// -------------------------------------------------------------------------- My Space

class _MySpaceTab extends StatelessWidget {
  const _MySpaceTab({super.key});

  @override
  Widget build(BuildContext context) {
    final cont = Library.continueWatching();
    final favs = Library.favorites();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text('My Space', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        ),
        if (cont.isEmpty && favs.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 120),
            child: Column(children: [
              Icon(Icons.bookmark_border, size: 56, color: Colors.white24),
              SizedBox(height: 10),
              Text('Titles you watch or add to My List\nshow up here.',
                  textAlign: TextAlign.center, style: TextStyle(color: C.text2)),
            ]),
          ),
        ContinueRow(entries: cont, onTap: (it) => openDetails(context, it)),
        PosterRow(title: 'My List', items: favs, onTap: (it) => openDetails(context, it)),
      ],
    );
  }
}
