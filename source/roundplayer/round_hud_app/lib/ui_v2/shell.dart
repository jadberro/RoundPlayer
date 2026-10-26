// HudShell: four screens + one screensaver, nothing else. The engine (main.dart)
// keeps owning playback; this widget only decides what is on screen.
import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'library.dart';
import 'model.dart';
import 'now_playing.dart';
import 'screensaver.dart';
import 'settings.dart';
import 'tokens.dart';

enum HudScreen { nowPlaying, library, settings }

class HudShell extends StatefulWidget {
  const HudShell({super.key, required this.view, required this.actions, required this.size});
  final HudView view;
  final HudActions actions;
  final double size;

  @override
  State<HudShell> createState() => _HudShellState();
}

class _HudShellState extends State<HudShell> {
  HudScreen _screen = HudScreen.nowPlaying;
  LibTab _libTab = LibTab.library;
  bool _saver = false;
  Timer? _idleTimer;
  Timer? _audioPoll;
  Map<String, dynamic>? _liveAudio;
  bool _fav = false;
  String? _favFor;
  bool _locate = false; // library opened from the player: land on the playing track
  Map<String, dynamic>? _sheetFor; // library opened from "…": start on this track's sheet

  Map<String, dynamic>? _trackFromTree(String activeId) {
    if (!activeId.startsWith('hifi_')) return null;
    final clean = activeId.substring(5);
    final tree = widget.view.hifiTree;
    for (final a in (tree?['artists'] as List? ?? []).cast<Map>()) {
      for (final al in (a['albums'] as List? ?? []).cast<Map>()) {
        for (final t in (al['tracks'] as List? ?? []).cast<Map>()) {
          if (t['track_id'].toString() == clean) return {...Map<String, dynamic>.from(t), 'track_id': clean, 'artist': a['name'], 'album': al['name']};
        }
      }
    }
    return {'track_id': clean, 'title': widget.view.title, 'artist': widget.view.artist, 'album': widget.view.album};
  }

  // Touch latency metric (HUD_PERF=1): time from pointer-down to the next frame painted, p50/p95 every 20 taps.
  static final bool _perf = Platform.environment['HUD_PERF'] == '1';
  final List<double> _tapToPaintMs = [];


  @override
  void initState() {
    super.initState();
    // HUD_DEBUG_SCREEN=library|queue|search|youtube|settings[:audio|wifi|system|password] - start on that screen
    // (used to screenshot every screen from the build box without touching the panel).
    final dbg = Platform.environment['HUD_DEBUG_SCREEN'] ?? '';
    if (dbg.startsWith('settings')) {
      _screen = HudScreen.settings;
    } else if (dbg == 'library') { _screen = HudScreen.library; _libTab = LibTab.library; }
    else if (dbg == 'queue') { _screen = HudScreen.library; _libTab = LibTab.queue; }
    else if (dbg == 'search') { _screen = HudScreen.library; _libTab = LibTab.search; }
    else if (dbg == 'youtube') { _screen = HudScreen.library; _libTab = LibTab.youtube; }
    else if (dbg == 'saver') { _saver = true; }
    debugPrint('[v2] shell init screen=$_screen saver=$_saver dbg="$dbg"');
    _listenPlaying();
    _armIdle();
    _audioPoll = Timer.periodic(const Duration(seconds: 5), (_) => _pollAudio());
    _pollAudio();
    _checkFavorite();
  }

  @override
  void didUpdateWidget(covariant HudShell old) {
    super.didUpdateWidget(old);
    _listenPlaying();
    // A new track arriving (cast from a phone, queue advance) wakes the screen and shows the player.
    if (old.view.activeId != widget.view.activeId) _checkFavorite();
    if (old.view.activeId != widget.view.activeId && !widget.view.isStandby) {
      _awakeInStandby = false;
      if (_saver) setState(() => _saver = false);
      if (_screen != HudScreen.nowPlaying && old.view.isStandby) setState(() => _screen = HudScreen.nowPlaying);
      _armIdle();
    }
    if (widget.view.isStandby && !old.view.isStandby) _awakeInStandby = false; // going to sleep: the clock comes up
    if (old.view.idleTimeoutSeconds != widget.view.idleTimeoutSeconds) _armIdle();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _audioPoll?.cancel();
    _playingListened?.removeListener(_onPlayingChanged);
    super.dispose();
  }

  Future<void> _checkFavorite() async {
    final id = widget.view.activeId;
    if (!id.startsWith('hifi_')) { if (_fav) setState(() => _fav = false); return; }
    _favFor = id;
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/hifi/favorites/check?track_id=${id.replaceFirst('hifi_', '')}')).timeout(const Duration(seconds: 3));
      if (r.statusCode == 200 && mounted && _favFor == id) setState(() => _fav = (jsonDecode(r.body) as Map)['is_favorite'] == true);
    } catch (_) {}
  }

  Future<void> _toggleFavorite() async {
    final id = widget.view.activeId;
    if (!id.startsWith('hifi_')) return;
    setState(() => _fav = !_fav);
    try {
      final r = await http.post(Uri.parse('http://127.0.0.1:8000/api/hifi/favorites/toggle'), headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'track_id': id.replaceFirst('hifi_', '')})).timeout(const Duration(seconds: 4));
      if (r.statusCode == 200 && mounted) setState(() => _fav = (jsonDecode(r.body) as Map)['is_favorite'] == true);
      widget.actions.loadPlaylists();
    } catch (_) {}
  }

  Future<void> _pollAudio() async {
    if (_saver || (!widget.view.isHiFi && _screen != HudScreen.settings)) return;
    try {
      final r = await http.get(Uri.parse('http://127.0.0.1:8000/api/audio/live')).timeout(const Duration(seconds: 3));
      if (r.statusCode == 200 && mounted) setState(() => _liveAudio = Map<String, dynamic>.from(jsonDecode(r.body) as Map));
    } catch (_) {}
  }

  // Clock after the idle timeout, but only when nothing is playing: while music or video plays the player stays
  // on screen by design. Paused or standby for the timeout -> clock; playback starting takes the clock down.
  void _armIdle() {
    _idleTimer?.cancel();
    final secs = widget.view.idleTimeoutSeconds;
    if (secs <= 0) return;
    _idleTimer = Timer(Duration(seconds: secs), () {
      if (!mounted) return;
      final playing = !widget.view.isStandby && widget.view.isPlaying.value;
      if (playing) { _armIdle(); return; }
      setState(() { _saver = true; _awakeInStandby = false; _screen = HudScreen.nowPlaying; });
    });
  }

  // Standby with nothing to resume (fresh boot, or sleep after a cast): a tap must still get past the clock,
  // so the shell remembers it is awake and shows the library to pick from. The idle timer brings the clock back.
  bool _awakeInStandby = false;

  ValueNotifier<bool>? _playingListened;
  void _listenPlaying() {
    final n = widget.view.isPlaying;
    if (identical(n, _playingListened)) return;
    _playingListened?.removeListener(_onPlayingChanged);
    _playingListened = n;
    n.addListener(_onPlayingChanged);
  }

  void _onPlayingChanged() {
    if (!mounted) return;
    if (_playingListened?.value == true && _saver && !widget.view.isStandby) setState(() => _saver = false);
    _armIdle();
  }

  void _touch() {
    widget.actions.touch();
    _armIdle();
  }

  void _measureTap() {
    if (!_perf) return;
    final t0 = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tapToPaintMs.add(DateTime.now().difference(t0).inMicroseconds / 1000.0);
      if (_tapToPaintMs.length >= 20) {
        final sorted = List<double>.from(_tapToPaintMs)..sort();
        final p50 = sorted[sorted.length ~/ 2];
        final p95 = sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
        debugPrint('[perf] tap->paint p50 ${p50.toStringAsFixed(1)} ms  p95 ${p95.toStringAsFixed(1)} ms  (n=${sorted.length})');
        _tapToPaintMs.clear();
      }
    });
  }

  void _wake() {
    if (_saver) debugPrint('[v2] wake');
    setState(() {
      _saver = false;
      if (widget.view.isStandby) { _awakeInStandby = true; _screen = HudScreen.library; _libTab = LibTab.library; _locate = false; }
    });
    _touch();
  }

  HudScreen? _lastLogged;
  bool? _lastSaverLogged;

  @override
  Widget build(BuildContext context) {
    if (_lastLogged != _screen || _lastSaverLogged != _saver) {
      _lastLogged = _screen; _lastSaverLogged = _saver;
      debugPrint('[v2] screen=$_screen saver=$_saver');
    }
    final v = widget.view;

    final nowPlaying = NowPlayingScreen(
      key: const ValueKey('np'),
      view: v,
      actions: widget.actions,
      bitPerfect: _liveAudio?['bit_perfect'] == true,
      eqActive: _liveAudio?['eq_active'] == true,
      isFavorite: _fav,
      onToggleFavorite: _toggleFavorite,
      dacRate: ((_liveAudio?['pipewire'] as Map?)?['sink'] as Map?)?['rate'] as int?,
      onOpenLibrary: () => setState(() { _screen = HudScreen.library; _libTab = LibTab.library; _locate = true; _sheetFor = null; }),
      onMore: () {
        final t = _trackFromTree(v.activeId);
        setState(() { _screen = HudScreen.library; _libTab = LibTab.library; _locate = false; _sheetFor = t; });
      },
      onOpenSettings: () => setState(() => _screen = HudScreen.settings),
    );

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) { _touch(); _measureTap(); },
      child: ClipOval(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: FittedBox(
            fit: BoxFit.fill,
            child: _Contrast(
              fx: v.displayFx,
              child: SizedBox(
              width: T.panel,
              height: T.panel,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The player surface is always mounted so a wake-up is instant (video decoder stays warm)
                  Offstage(offstage: _screen != HudScreen.nowPlaying, child: nowPlaying),
                  if (_screen == HudScreen.library)
                    LibraryScreen(
                      key: const ValueKey('lib'),
                      view: v,
                      actions: widget.actions,
                      tab: _libTab,
                      onTab: (t) { _touch(); setState(() => _libTab = t); },
                      locateActive: _locate,
                      initialSheetTrack: _sheetFor,
                      onPlayed: () { if (mounted) setState(() => _screen = HudScreen.nowPlaying); },
                      onClose: () { debugPrint('[v2] library close'); setState(() => _screen = HudScreen.nowPlaying); _checkFavorite(); },
                      onOpenSettings: () { _touch(); setState(() => _screen = HudScreen.settings); },
                    ),
                  if (_screen == HudScreen.settings)
                    SettingsScreen(
                      key: const ValueKey('set'),
                      view: v,
                      actions: widget.actions,
                      liveAudio: _liveAudio,
                      onClose: () => setState(() { _screen = HudScreen.library; _locate = false; }),
                    ),
                  // Preparing something while on a list screen: a 6 px progress line under the header
                  if (_screen != HudScreen.nowPlaying && v.preparingId != null)
                    Positioned(
                      left: 300, right: 300, top: 196,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(value: v.preparingPercent > 0 ? v.preparingPercent / 100 : null, minHeight: 6, backgroundColor: const Color(0x22FFFFFF), color: v.isHiFi || (v.preparingId?.startsWith('hifi_') ?? false) ? T.gold : T.cyan),
                      ),
                    ),
                  // Sleep (standby) and idle both show the clock; a tap wakes. From standby the daemon reloads the last track paused.
                  if (_saver || (v.isStandby && !_awakeInStandby)) Screensaver(view: v, standby: v.isStandby, onWake: () { _wake(); if (v.isStandby) widget.actions.wake(); }),
                  // Display settings (brightness / warmth / contrast): the panel has no backlight or gamma table, so the
                  // HUD darkens and tints its own output with full-panel quads blended onto what is already drawn - no
                  // extra layer. Contrast below neutral is x*c + o, so it folds in here as a modulate by c and an
                  // add of o (same result as the old colour-matrix layer, which now only runs for contrast > 1).
                  // modulate == multiply over the opaque panel, and it is a plain coefficient blend on the GPU.
                  if (v.displayFx != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ValueListenableBuilder<Map<String, dynamic>>(
                          valueListenable: v.displayFx!,
                          builder: (_, fx, _) {
                            final b = ((fx['brightness'] as num?)?.toDouble() ?? 1.0).clamp(0.05, 1.0);
                            final k = ((fx['warmth'] as num?)?.toDouble() ?? 6500).clamp(1500.0, 6500.0);
                            final c = contrastOf(fx);
                            final cm = c < 1 ? c : 1.0;                               // > 1 is the _Contrast layer's job
                            final o = c < 1 ? (128.0 * (1 - c)).round() : 0;
                            final tint = kelvinTint(k);
                            if (b >= 0.995 && k >= 6499 && cm >= 0.995) return const SizedBox.shrink();
                            int ch(double t) => (255 * b * t * cm).round();
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                DecoratedBox(
                                  decoration: BoxDecoration(color: Color.fromARGB(255, ch(tint[0]), ch(tint[1]), ch(tint[2])), backgroundBlendMode: BlendMode.modulate),
                                ),
                                if (o > 0)
                                  DecoratedBox(decoration: BoxDecoration(color: Color.fromARGB(255, o, o, o), backgroundBlendMode: BlendMode.plus)),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Colour temperature -> RGB multiplier normalised so 6500 K is (1,1,1). Tanner Helland's fit; good enough for a tint.
List<double> kelvinTint(double kelvin) {
  final t = kelvin / 100.0;
  double r, g, b;
  if (t <= 66) {
    r = 255;
    g = 99.4708025861 * math.log(t) - 161.1195681661;
    b = t <= 19 ? 0 : 138.5177312231 * math.log(t - 10) - 305.0447927307;
  } else {
    r = 329.698727446 * math.pow(t - 60, -0.1332047592);
    g = 288.1221695283 * math.pow(t - 60, -0.0755148492);
    b = 255;
  }
  double c(double x) => (x.clamp(0, 255)) / 255.0;
  final rr = c(r), gg = c(g), bb = c(b);
  final m = math.max(rr, math.max(gg, bb));
  return [rr / m, gg / m, bb / m];
}

/// Effective contrast from the daemon's display telemetry; within 1 % of neutral counts as neutral.
double contrastOf(Map<String, dynamic> fx) {
  final c = ((fx['contrast'] as num?)?.toDouble() ?? 1.0).clamp(0.3, 2.0);
  return (c - 1.0).abs() < 0.01 ? 1.0 : c;
}

/// Contrast above neutral as a colour matrix around the whole panel. It costs a full-screen layer, so it is only
/// mounted for contrast > 1 (below 1 is done by the display overlay). The panel sits under a GlobalKey: adding or
/// removing the layer reparents it instead of rebuilding it (that used to reset the video surface, the library's
/// scroll position and any open sheet whenever contrast crossed neutral).
class _Contrast extends StatefulWidget {
  const _Contrast({required this.fx, required this.child});
  final ValueNotifier<Map<String, dynamic>>? fx;
  final Widget child;

  @override
  State<_Contrast> createState() => _ContrastState();
}

class _ContrastState extends State<_Contrast> {
  final _panelKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final panel = KeyedSubtree(key: _panelKey, child: widget.child);
    if (widget.fx == null) return panel;
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: widget.fx!,
      builder: (_, v, child) {
        final c = contrastOf(v);
        if (c <= 1.0) return child!;
        final o = 128.0 * (1 - c);
        return ColorFiltered(
          colorFilter: ColorFilter.matrix(<double>[
            c, 0, 0, 0, o,
            0, c, 0, 0, o,
            0, 0, c, 0, o,
            0, 0, 0, 1, 0,
          ]),
          child: child,
        );
      },
      child: panel,
    );
  }
}
