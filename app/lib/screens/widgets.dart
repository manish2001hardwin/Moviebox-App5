import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../library.dart';
import '../native.dart';
import '../theme.dart';

const kPosterHeaders = {'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36'};

class PosterImage extends StatelessWidget {
  final String? url;
  final BoxFit fit;
  final String? label;
  const PosterImage(this.url, {super.key, this.fit = BoxFit.cover, this.label});

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      color: C.surface2,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(8),
      child: label == null
          ? const Icon(Icons.movie_outlined, size: 32, color: Colors.white24)
          : Text(label!,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600)),
    );
    if (url == null || url!.isEmpty) return placeholder;
    return Image.network(
      url!,
      fit: fit,
      alignment: Alignment.topCenter,
      headers: kPosterHeaders,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => placeholder,
      loadingBuilder: (c, child, p) => p == null ? child : placeholder,
    );
  }
}

class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const ErrorView({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off_rounded, size: 44, color: Colors.white38),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: C.text2)),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: onRetry,
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              child: const Text('Try again'),
            ),
          ]),
        ),
      );
}

class SectionTitle extends StatelessWidget {
  final String text;
  const SectionTitle(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 10),
        child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      );
}

/// Netflix-style horizontal row of posters.
class PosterRow extends StatelessWidget {
  final String title;
  final List<Item> items;
  final void Function(Item) onTap;
  final double cardWidth;
  const PosterRow(
      {super.key, required this.title, required this.items, required this.onTap, this.cardWidth = 118});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionTitle(title),
      SizedBox(
        height: cardWidth * 1.5,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final it = items[i];
            return GestureDetector(
              onTap: () => onTap(it),
              child: SizedBox(
                width: cardWidth,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: PosterImage(it.poster, label: it.title),
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

/// "Continue watching" row: poster + red progress bar + episode label.
class ContinueRow extends StatelessWidget {
  final List<HistoryEntry> entries;
  final void Function(Item) onTap;
  const ContinueRow({super.key, required this.entries, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    const w = 118.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionTitle('Continue watching'),
      SizedBox(
        height: w * 1.5 + 22,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: entries.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final h = entries[i];
            return GestureDetector(
              onTap: () => onTap(h.item),
              child: SizedBox(
                width: w,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Stack(fit: StackFit.expand, children: [
                        PosterImage(h.item.poster, label: h.item.title),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.center,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Color(0xCC000000)],
                            ),
                          ),
                        ),
                        const Center(
                          child: Icon(Icons.play_circle_outline, size: 40, color: Colors.white),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: h.progress.clamp(0.0, 1.0),
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                            color: C.accent,
                          ),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    h.season > 0 ? 'S${h.season} E${h.episode}' : h.item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: C.text2),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

/// Big featured poster with gradient, title and Play / My List buttons.
class HeroBanner extends StatefulWidget {
  final Item item;
  final VoidCallback onPlay;
  const HeroBanner({super.key, required this.item, required this.onPlay});
  @override
  State<HeroBanner> createState() => _HeroBannerState();
}

class _HeroBannerState extends State<HeroBanner> {
  @override
  Widget build(BuildContext context) {
    final h = math.min(MediaQuery.of(context).size.height * 0.62, 560.0);
    final it = widget.item;
    final inList = Library.isFav(it);
    return SizedBox(
      height: h,
      child: Stack(fit: StackFit.expand, children: [
        GestureDetector(onTap: widget.onPlay, child: PosterImage(it.poster, label: it.title)),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.25, 0.6, 1],
                colors: [Color(0xCC000000), Colors.transparent, Colors.transparent, C.bg],
              ),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 14,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              it.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                height: 1.1,
                shadows: [Shadow(blurRadius: 12, color: Colors.black87)],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              [if (it.year != null) it.year!, it.isSeries ? 'TV Show' : 'Movie'].join('  •  '),
              style: const TextStyle(color: C.text2, fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: widget.onPlay,
                  icon: const Icon(Icons.play_arrow_rounded, size: 28),
                  label: const Text('Play', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await Library.toggleFav(it);
                    if (mounted) setState(() {});
                  },
                  icon: Icon(inList ? Icons.check : Icons.add),
                  label: const Text('My List', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0x99333333),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// Grid used by search results (poster + title below).
class PosterGrid extends StatelessWidget {
  final List<Item> items;
  final void Function(Item) onTap;
  const PosterGrid({super.key, required this.items, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 130,
        childAspectRatio: 0.56,
        crossAxisSpacing: 8,
        mainAxisSpacing: 10,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        return GestureDetector(
          onTap: () => onTap(it),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(width: double.infinity, child: PosterImage(it.poster, label: it.title)),
              ),
            ),
            const SizedBox(height: 4),
            Text(it.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            if (it.year != null)
              Text(it.year!, style: const TextStyle(fontSize: 11, color: C.text2)),
          ]),
        );
      },
    );
  }
}
