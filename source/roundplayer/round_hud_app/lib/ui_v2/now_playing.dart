// Now Playing, direction D "Gallery x Editorial": the album art fills the disc and the lower half belongs to typography - a condensed white title on the chord, artist/album
// in a light weight, a mono readout above. Controls are monochrome; the only colour on screen is the album's.
// Coordinates are 1080-panel pixels; every band was checked against the circle's chord.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'model.dart';
import 'tokens.dart';

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key, required this.view, required this.actions, required this.onOpenLibrary, this.onOpenSettings, this.bitPerfect = false, this.eqActive = false, this.dacRate, this.isFavorite = false, this.onToggleFavorite, this.onMore});
  final HudView view;
  final HudActions actions;
  final VoidCallback onOpenLibrary;
  final VoidCallback? onOpenSettings;
  final bool bitPerfect;
  final bool eqActive;
  final int? dacRate;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onMore;   // "…": the track sheet (queue, playlists, go to artist/album, like this)

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  bool _controls = true;
  bool _lyricsOn = false;   // long-press the title: synced lyrics over the cover (LRCLIB via the daemon)
  DateTime _lastInteraction = DateTime.now();
  int _seekFlash = 0;
  double? _scrubFraction;

  @override
  void initState() {
    super.initState();
    widget.view.isPlaying.addListener(_onPlayingChanged);
    _tick();
  }

  @override
  void didUpdateWidget(covariant NowPlayingScreen old) {
    super.didUpdateWidget(old);
    if (old.view.isPlaying != widget.view.isPlaying) {
      old.view.isPlaying.removeListener(_onPlayingChanged);
      widget.view.isPlaying.addListener(_onPlayingChanged);
    }
    if (old.view.activeId != widget.view.activeId) _show();
  }

  @override
  void dispose() {
    widget.view.isPlaying.removeListener(_onPlayingChanged);
    super.dispose();
  }

  void _onPlayingChanged() {
    if (!widget.view.isPlaying.value && mounted) setState(() => _controls = true);
  }

  // Video controls fade after 4 s of playback; Hi-Fi, paused and standby keep them.
  void _tick() async {
    while (mounted) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      final hide = !widget.view.isHiFi && widget.view.isPlaying.value && !widget.view.isStandby &&
          DateTime.now().difference(_lastInteraction).inSeconds >= 4;
      if (hide && _controls) setState(() => _controls = false);
    }
  }

  void _show() {
    _lastInteraction = DateTime.now();
    if (!_controls && mounted) setState(() => _controls = true);
  }

  void _onTap() {
    widget.actions.touch();
    if (widget.view.isHiFi || !widget.view.isPlaying.value) return;
    setState(() {
      _controls = !_controls;
      _lastInteraction = DateTime.now();
    });
  }

  void _onDoubleTap(TapDownDetails d) {
    widget.actions.touch();
    final right = d.localPosition.dx > T.panel / 2;
    widget.actions.seekBy(right ? 10 : -10);
    setState(() => _seekFlash = right ? 1 : -1);
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _seekFlash = 0);
    });
    _show();
  }

  String _kicker(HudView v) {
    if (v.isStandby) return 'STANDBY';
    if (v.isExternal) return v.activeId == 'ext:airplay' ? 'AIRPLAY' : 'SPOTIFY CONNECT';
    if (v.isHiFi) {
      final khz = v.sampleRateHz % 1000 == 0 ? (v.sampleRateHz ~/ 1000).toString() : (v.sampleRateHz / 1000).toStringAsFixed(1);
      return '${v.audioFormat.toUpperCase()} ${v.bitDepth} · $khz kHz';
    }
    if (v.audioOnly) return 'YOUTUBE MUSIC${v.audioFormat.isNotEmpty ? ' · ${v.audioFormat.toUpperCase()}' : ''}';
    return '${v.videoHeight ?? 1080}P · YOUTUBE';
  }

  String? _kickerTail(HudView v) {
    if (v.sleepInS != null && !v.isStandby) return 'SLEEP IN ${(v.sleepInS! / 60).ceil()} MIN';
    if (v.isHiFi && !v.isStandby) {
      if (widget.eqActive) return 'EQ';
      return widget.bitPerfect ? 'BIT-PERFECT' : (widget.dacRate != null ? 'DAC ${(widget.dacRate! / 1000).toStringAsFixed(1)} kHz' : null);
    }
    if (!v.isHiFi && v.castSenders.isNotEmpty) return 'CASTING · ${v.castSenders.first.toUpperCase()}';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final hifi = v.isHiFi || v.isExternal || v.audioOnly;   // external sources and audio-only streams use the art layout
    final showControls = _controls || v.isStandby || hifi;
    final video = !hifi && !v.isStandby;
    final tail = _kickerTail(v);
    final tailGood = tail != null && (tail.startsWith('BIT') || tail.startsWith('CASTING'));

    return Stack(
      fit: StackFit.expand,
      children: [
        // Surface: cover art (Hi-Fi) or the video, with a gesture layer
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          onDoubleTapDown: _onDoubleTap,
          onDoubleTap: () {},
          onHorizontalDragEnd: (d) {
            final vx = d.primaryVelocity ?? 0;
            if (vx < -250) widget.actions.next();
            if (vx > 250) widget.actions.prev();
          },
          onVerticalDragEnd: (d) {
            final vy = d.primaryVelocity ?? 0;
            widget.actions.touch();
            if (vy > 600) widget.onOpenLibrary();
            if (vy < -600) widget.onOpenSettings?.call();
          },
          child: video ? Video(controller: v.videoController, fit: BoxFit.cover, controls: NoVideoControls) : _ArtBackdrop(view: v),
        ),
        // Gradient: dark only where text and controls sit (never blur). On video it only exists while the controls
        // are up - once they hide, the picture is shown untouched (it used to stay, dimming the lower half).
        IgnorePointer(
          child: AnimatedOpacity(
          opacity: video && !showControls ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 220),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: video
                    ? const [Color(0xC4070709), Color(0x00070709), Color(0x00070709), Color(0xD1070709), Color(0xF7070709)]
                    : const [Color(0x59070709), Color(0x00070709), Color(0x00070709), Color(0xE0070709), Color(0xFA070709)],
                stops: video ? const [0.0, 0.34, 0.46, 0.68, 1.0] : const [0.0, 0.26, 0.40, 0.60, 1.0],
              ),
            ),
          ),
          ),
        ),
        // Controls hidden (video playing): 4 px edge line keeps the position glanceable
        if (!showControls)
          Positioned(
            left: 340, right: 340, bottom: 66,
            child: IgnorePointer(
              child: ValueListenableBuilder<Duration>(
                valueListenable: v.position,
                builder: (_, pos, __) {
                  final total = v.duration.value.inMilliseconds;
                  final f = total > 0 ? (pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
                  return Stack(children: [
                    Container(height: 4, color: const Color(0x4DFFFFFF)),
                    FractionallySizedBox(widthFactor: f, child: Container(height: 4, color: Colors.white)),
                  ]);
                },
              ),
            ),
          ),
        if (_seekFlash != 0)
          Positioned(
            left: _seekFlash < 0 ? 150 : null,
            right: _seekFlash > 0 ? 150 : null,
            top: 480,
            child: IgnorePointer(
              child: Container(
                width: 120, height: 120,
                decoration: const BoxDecoration(color: Color(0x66FFFFFF), shape: BoxShape.circle),
                child: Icon(_seekFlash < 0 ? Icons.replay_10_rounded : Icons.forward_10_rounded, size: 64, color: T.fg),
              ),
            ),
          ),

        // Overlay
        IgnorePointer(
          ignoring: !showControls,
          child: AnimatedOpacity(
            opacity: showControls ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: Stack(
              children: [
                if (video) ...[
                  // Video: title block at the top, centred, so the picture stays clear
                  Positioned(
                    left: 230, right: 230, top: 118,
                    child: Column(
                      children: [
                        _FitTitle(v.title, maxWidth: 620, maxSize: 72, minSize: 56, align: TextAlign.center, maxLines: 2),
                        const SizedBox(height: 10),
                        Text(v.artist, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: T.subtitle.copyWith(fontWeight: FontWeight.w600, color: Colors.white)),
                        const SizedBox(height: 12),
                        _Kicker(head: _kicker(v), tail: tail, tailGood: tailGood, align: TextAlign.center),
                      ],
                    ),
                  ),
                ] else ...[
                  // Hi-Fi / standby: editorial block on the lower half. Kicker 556, title 584..702, subtitle 712..748.
                  Positioned(left: 180, right: 330, top: 556, child: _Kicker(head: _kicker(v), tail: tail, tailGood: tailGood)),
                  if (!v.isStandby && v.isHiFi)
                    Positioned(
                      right: 246, top: 536,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () { widget.actions.touch(); widget.onMore?.call(); },
                        child: const SizedBox(width: 64, height: 64, child: Icon(Icons.more_horiz_rounded, size: 44, color: Color(0xFFAAB2C2))),
                      ),
                    ),
                  if (!v.isStandby)
                    Positioned(
                      right: 176, top: 536,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () { widget.actions.touch(); widget.onToggleFavorite?.call(); },
                        child: SizedBox(width: 64, height: 64, child: Icon(widget.isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded, size: 40, color: widget.isFavorite ? T.bad : const Color(0xFFAAB2C2))),
                      ),
                    ),
                  Positioned(
                    left: 176, right: 176, top: 584, height: 118,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onLongPress: () { if (!v.isStandby && hifi) { widget.actions.touch(); setState(() => _lyricsOn = !_lyricsOn); } },
                      child: Align(alignment: Alignment.bottomLeft, child: _FitTitle(v.isStandby ? 'Standby' : v.title, maxWidth: 728, maxSize: 124, minSize: 60)),   // long titles shrink before they ellipsise
                    ),
                  ),
                  if (_lyricsOn && hifi && !v.isStandby)
                    Positioned(left: 140, right: 140, top: 150, height: 380, child: _LyricsPane(key: ValueKey('ly${v.activeId}'), view: v, onMissing: () { if (mounted) setState(() => _lyricsOn = false); })),
                  Positioned(
                    left: 180, right: 180, top: 712,
                    child: RichText(
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      text: TextSpan(
                        style: T.subtitle,
                        children: v.isStandby
                            ? const [TextSpan(text: 'Pick something from the library')]
                            : [
                                TextSpan(text: v.artist, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
                                if (v.album.isNotEmpty) TextSpan(text: '  ${v.album}'),
                                if ((v.upNextTitle ?? '').isNotEmpty) TextSpan(text: '  ·  up next ${v.upNextTitle}', style: const TextStyle(color: T.mute)),
                              ],
                      ),
                    ),
                  ),
                ],

                // Diameter buttons
                Positioned(left: 96, top: T.diameterY, child: _Outlined(onTap: () { widget.actions.touch(); widget.onOpenLibrary(); }, child: const Icon(Icons.menu_rounded, size: 50, color: T.fg))),
                Positioned(
                  right: 96, top: T.diameterY,
                  child: _Outlined(onTap: () { widget.actions.touch(); widget.onOpenSettings?.call(); }, child: const Icon(Icons.settings_rounded, size: 48, color: T.fg)),
                ),

                // Seek (bar 790..794, times 806..830) or the preparing line in the same place
                Positioned(
                  left: 250, right: 250, top: 772,
                  child: v.preparingId != null
                      ? _PreparingLine(view: v, onCancel: widget.actions.cancelPreparing)
                      : _Seek(view: v, onScrub: (f) => setState(() => _scrubFraction = f), onSeek: (d) { widget.actions.touch(); widget.actions.seekTo(d); setState(() => _scrubFraction = null); }, scrubFraction: _scrubFraction),
                ),

                // Transport: play 136 px at 860..996, prev/next 112 px (chord at 996 is 2x289)
                Positioned(
                  left: 0, right: 0, top: 860,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _Outlined(onTap: () { widget.actions.touch(); widget.actions.prev(); }, child: const Icon(Icons.skip_previous_rounded, size: 54, color: T.fg)),
                      const SizedBox(width: 40),
                      ValueListenableBuilder<bool>(
                        valueListenable: v.isPlaying,
                        builder: (_, playing, __) => RoundButton(
                          size: 136,
                          fill: Colors.white,
                          border: Colors.transparent,
                          onTap: () { widget.actions.touch(); _show(); v.isStandby ? widget.actions.wake() : widget.actions.togglePlay(); },
                          child: Icon(playing && !v.isStandby ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 70, color: const Color(0xFF070709)),
                        ),
                      ),
                      const SizedBox(width: 40),
                      _Outlined(onTap: () { widget.actions.touch(); widget.actions.next(); }, child: const Icon(Icons.skip_next_rounded, size: 54, color: T.fg)),
                    ],
                  ),
                ),

                // Volume: lowest band 1002..1046 (chord at 1046 is 2x189 -> 360 wide)
                Positioned(
                  left: 360, right: 360, top: 1002,
                  child: _VolumeSlider(view: v, onChange: (x) { widget.actions.touch(); widget.actions.setVolume(x); }),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Bebas title that shrinks from maxSize to minSize to fit, then ellipsises.
/// Synced lyrics (LRC) that follow the player's position: the current line large, neighbours dimmed, on a soft scrim.
class _LyricsPane extends StatefulWidget {
  const _LyricsPane({super.key, required this.view, required this.onMissing});
  final HudView view;
  final VoidCallback onMissing;
  @override
  State<_LyricsPane> createState() => _LyricsPaneState();
}

class _LyricsPaneState extends State<_LyricsPane> {
  List<(double, String)>? _lines; // (seconds, text)
  List<String>? _plain;
  bool _loading = true;
  String _status = 'Looking for lyrics…';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/lyrics?track_id=${widget.view.activeId}')).timeout(const Duration(seconds: 10));
      final d = jsonDecode(r.body) as Map;
      if (!mounted) return;
      if (d['found'] != true) { setState(() { _loading = false; _status = 'No lyrics for this one'; }); Future.delayed(const Duration(milliseconds: 1600), widget.onMissing); return; }
      final synced = d['synced']?.toString();
      if (synced != null && synced.trim().isNotEmpty) {
        final re = RegExp(r'^\[(\d+):(\d+(?:\.\d+)?)\](.*)$');
        final out = <(double, String)>[];
        for (final raw in synced.split('\n')) {
          final m = re.firstMatch(raw.trim());
          if (m == null) continue;
          out.add((int.parse(m.group(1)!) * 60 + double.parse(m.group(2)!), m.group(3)!.trim()));
        }
        out.sort((a, b) => a.$1.compareTo(b.$1));
        setState(() { _lines = out; _loading = false; });
      } else {
        setState(() { _plain = (d['plain']?.toString() ?? '').split('\n').where((l) => l.trim().isNotEmpty).toList(); _loading = false; });
      }
    } catch (_) {
      if (mounted) { setState(() { _loading = false; _status = 'Lyrics unavailable'; }); Future.delayed(const Duration(milliseconds: 1600), widget.onMissing); }
    }
  }

  @override
  Widget build(BuildContext context) {
    const big = TextStyle(fontFamily: T.display, fontSize: 64, height: 1.0, color: Colors.white, letterSpacing: 0.5);
    const dim = TextStyle(fontFamily: T.text, fontSize: 30, fontWeight: FontWeight.w300, color: Color(0xB3FFFFFF), height: 1.2);
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(color: const Color(0x8C070709), borderRadius: BorderRadius.circular(32)),
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
        child: _loading || (_lines == null && _plain == null)
            ? Center(child: Text(_status, style: dim))
            : _lines != null
                ? ValueListenableBuilder<Duration>(
                    valueListenable: widget.view.position,
                    builder: (_, pos, __) {
                      final t = pos.inMilliseconds / 1000.0 + 0.15;
                      int i = -1;
                      for (int k = 0; k < _lines!.length; k++) { if (_lines![k].$1 <= t) i = k; else break; }
                      String at(int k) => k >= 0 && k < _lines!.length ? _lines![k].$2 : '';
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(at(i - 1), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: dim),
                          const SizedBox(height: 14),
                          Text(i < 0 ? '♪' : (at(i).isEmpty ? '♪' : at(i)), maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: big),
                          const SizedBox(height: 14),
                          Text(at(i + 1), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: dim),
                        ],
                      );
                    },
                  )
                : SingleChildScrollView(child: Text(_plain!.join('\n'), textAlign: TextAlign.center, style: dim)),
      ),
    );
  }
}

class _FitTitle extends StatelessWidget {
  const _FitTitle(this.text, {required this.maxWidth, required this.maxSize, required this.minSize, this.align = TextAlign.left, this.maxLines = 1});
  final String text;
  final double maxWidth;
  final double maxSize;
  final double minSize;
  final TextAlign align;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final t = text.toUpperCase();
    double size = maxSize;
    for (double s = maxSize; s >= minSize; s -= 4) {
      final tp = TextPainter(text: TextSpan(text: t, style: T.title.copyWith(fontSize: s)), textDirection: TextDirection.ltr, maxLines: maxLines)..layout(maxWidth: maxWidth);
      size = s;
      if (!tp.didExceedMaxLines) break;
    }
    return Text(
      t,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: T.title.copyWith(fontSize: size, shadows: const [Shadow(color: Color(0x99000000), blurRadius: 30, offset: Offset(0, 2))]),
    );
  }
}

class _Kicker extends StatelessWidget {
  const _Kicker({required this.head, this.tail, this.tailGood = false, this.align = TextAlign.left});
  final String head;
  final String? tail;
  final bool tailGood;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      text: TextSpan(
        style: T.eyebrow.copyWith(color: const Color(0xFFAAB2C2)),
        children: [
          TextSpan(text: head),
          if (tail != null) TextSpan(text: ' · $tail', style: TextStyle(color: tailGood ? T.good : const Color(0xFFAAB2C2))),
        ],
      ),
    );
  }
}

/// 112 px outlined control (prev/next/library/standby): a 2 px line over dark glass, no fill colour.
class _Outlined extends StatelessWidget {
  const _Outlined({required this.child, required this.onTap});
  final Widget child;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => RoundButton(onTap: onTap, fill: const Color(0x73070709), border: const Color(0x38FFFFFF), child: child);
}

/// Full-bleed cover art (Hi-Fi), or a quiet dark field (standby).
class _ArtBackdrop extends StatelessWidget {
  const _ArtBackdrop({required this.view});
  final HudView view;

  @override
  Widget build(BuildContext context) {
    final clean = view.activeId.replaceFirst('hifi_', '');
    final coverUrl = view.isExternal
        ? 'http://127.0.0.1:8000/api/external/cover?t=${Uri.encodeComponent(view.title)}'
        : (view.audioOnly && !view.isStandby
            ? 'http://127.0.0.1:8000/media/${view.activeId}/cover.jpg'
            : (view.isHiFi && !view.isStandby ? 'http://127.0.0.1:8000/api/hifi/cover?track_id=hifi_$clean' : null));
    return ValueListenableBuilder<Color>(
      valueListenable: view.accent,
      builder: (_, c, __) => Stack(
        fit: StackFit.expand,
        children: [
          if (coverUrl != null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              // The switcher lays its children out loosely, which let a 600 px cover sit at its native size in the
              // middle of the disc. Pin it to the full panel so BoxFit.cover scales it edge to edge.
              layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
              child: SizedBox.expand(key: ValueKey(coverUrl), child: Cover(coverUrl, fallbackIcon: Icons.album_rounded)),
            )
          else
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(center: const Alignment(0, -0.2), radius: 0.9, colors: [Color.lerp(c, Colors.black, 0.8)!, const Color(0xFF070709)]),
              ),
            ),
        ],
      ),
    );
  }
}

class _Seek extends StatelessWidget {
  const _Seek({required this.view, required this.onScrub, required this.onSeek, this.scrubFraction});
  final HudView view;
  final void Function(double) onScrub;
  final void Function(Duration) onSeek;
  final double? scrubFraction;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Duration>(
      valueListenable: view.duration,
      builder: (_, dur, __) => ValueListenableBuilder<Duration>(
        valueListenable: view.position,
        builder: (_, pos, __) {
          final total = dur.inMilliseconds > 0 ? dur.inMilliseconds : 1;
          final f = scrubFraction ?? (pos.inMilliseconds / total).clamp(0.0, 1.0);
          final shown = scrubFraction != null ? Duration(milliseconds: (f * total).round()) : pos;
          return LayoutBuilder(
            builder: (_, c) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (d) => onScrub((d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0)),
              onHorizontalDragUpdate: (d) => onScrub((d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0)),
              onHorizontalDragEnd: (_) => onSeek(Duration(milliseconds: ((scrubFraction ?? f) * total).round())),
              onTapUp: (d) => onSeek(Duration(milliseconds: ((d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0) * total).round())),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 18), // 46 px touch band around a 4 px bar
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 14,
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          Container(height: 4, color: const Color(0x38FFFFFF)),
                          FractionallySizedBox(widthFactor: f, child: Container(height: 4, color: Colors.white)),
                          if (scrubFraction != null)
                            Align(alignment: Alignment(f * 2 - 1, 0), child: Container(width: 14, height: 14, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle))),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [Text(fmtTime(shown), style: T.mono), Text(fmtTime(dur), style: T.mono)],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PreparingLine extends StatelessWidget {
  const _PreparingLine({required this.view, required this.onCancel});
  final HudView view;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final failed = view.preparingStatus.toLowerCase().contains('fail') || view.preparingStatus.toLowerCase().contains('not responding');
    final color = failed ? T.bad : Colors.white;
    final pct = view.preparingPercent.clamp(0, 100);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('${(view.preparingTitle ?? 'Preparing').toUpperCase()}  ·  ${view.preparingStatus.isEmpty ? 'PREPARING' : view.preparingStatus.toUpperCase()}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: T.eyebrow.copyWith(color: failed ? T.bad : const Color(0xFFAAB2C2), letterSpacing: 2)),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onCancel,
                child: Container(width: 56, height: 56, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0x38FFFFFF), width: 2)), child: const Icon(Icons.close_rounded, size: 32, color: T.fg)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Stack(children: [
            Container(height: 4, color: const Color(0x38FFFFFF)),
            AnimatedFractionallySizedBox(duration: const Duration(milliseconds: 250), widthFactor: math.max(0.02, pct / 100), child: Container(height: 4, color: color)),
          ]),
        ],
      ),
    );
  }
}

class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({required this.view, required this.onChange});
  final HudView view;
  final void Function(double) onChange;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: view.volume,
      builder: (_, vol, __) => LayoutBuilder(
        builder: (_, c) {
          const iconW = 30.0;
          final barW = c.maxWidth - iconW - 14;
          double frac(double dx) => ((dx - iconW - 14) / barW).clamp(0.0, 1.0);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) => onChange(frac(d.localPosition.dx) * 100),
            onHorizontalDragUpdate: (d) => onChange(frac(d.localPosition.dx) * 100),
            onTapUp: (d) => onChange(frac(d.localPosition.dx) * 100),
            child: SizedBox(
              height: 44,
              child: Row(
                children: [
                  Icon(vol <= 0.5 ? Icons.volume_off_rounded : (vol < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded), size: 30, color: T.mute),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Center(
                      child: Stack(children: [
                        Container(height: 4, color: const Color(0x33FFFFFF)),
                        FractionallySizedBox(widthFactor: (vol / 100).clamp(0.0, 1.0), child: Container(height: 4, color: const Color(0xCCFFFFFF))),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
