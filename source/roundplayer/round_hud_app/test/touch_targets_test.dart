// Geometry checks for the round panel: every tappable control on Now Playing must sit entirely on the glass
// (a 1080 px circle), and the play button must show the requested state before mpv confirms it.
//
//   flutter test
//
// Runs without a Pi or libmpv: the view has no VideoController, so only the art layouts (standby, Hi-Fi) render.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:round_hud_app/ui_v2/model.dart';
import 'package:round_hud_app/ui_v2/now_playing.dart';
import 'package:round_hud_app/ui_v2/tokens.dart';

HudActions _noActions() {
  Future<void> none() async {}
  return HudActions(
    togglePlay: () {}, next: () {}, prev: () {}, seekTo: (_) {}, seekBy: (_) {}, setVolume: (_) {}, standby: () {}, wake: () {},
    playHiFi: (_, {playlist, index}) {}, playYouTube: (_) {}, playSearchResult: (_) {}, addToQueue: (_) {}, cancelPreparing: () {},
    loadHiFiTree: ({force = false}) => none(), syncHiFiLibrary: none, loadCachedTracks: none, searchYouTube: (_) => none(),
    searchHiFi: (_) => none(), saveSettings: (_) => none(), updateAudioSetting: (_, _) => none(), loadAudioSettings: none,
    loadNetworkStatus: none, scanNetworks: none, connectWifi: (_, _) => none(), forgetWifi: (_) => none(), setBand: (_) => none(),
    toggleHotspot: none, toggleShuffle: () {}, toggleRepeat: () {}, restartServices: none, touch: () {}, loadPlaylists: none,
    playPlaylist: (_, {shuffle = false}) => none(), playSmartMix: (_) => none(), searchCity: (_) => none(),
    selectCity: (_, {lat, lon}) => none(), playSimilar: ({trackId, artist}) => none(), setRepeat: (_) => none(),
  );
}

HudView _view({required String activeId, ValueNotifier<bool?>? playIntent, ValueNotifier<bool>? isPlaying}) => HudView(
      activeId: activeId,
      title: 'A Fairly Long Track Title For Fitting',
      artist: 'Artist',
      album: 'Album',
      isHiFi: activeId.startsWith('hifi_'),
      audioFormat: 'FLAC',
      bitDepth: 24,
      sampleRateHz: 96000,
      videoController: null,
      position: ValueNotifier(const Duration(seconds: 30)),
      duration: ValueNotifier(const Duration(minutes: 4)),
      isPlaying: isPlaying ?? ValueNotifier(false),
      volume: ValueNotifier(60),
      accent: ValueNotifier(const Color(0xFF00E5FF)),
      playIntent: playIntent,
    );

Future<void> _pump(WidgetTester tester, HudView view) async {
  tester.view.physicalSize = const Size(T.panel, T.panel);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Center(
      child: SizedBox(
        width: T.panel,
        height: T.panel,
        child: NowPlayingScreen(view: view, actions: _noActions(), onOpenLibrary: () {}, onOpenSettings: () {}),
      ),
    ),
  ));
  await tester.pump();
}

// Unmount and let the screen's timers (controls fade loop, cover retries) run out.
Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
}

/// Rects of everything that reacts to a tap, minus the full-panel gesture surface.
List<Rect> _tapTargets(WidgetTester tester) {
  final rects = <Rect>[];
  for (final e in find.byWidgetPredicate((w) => w is GestureDetector && (w.onTap != null || w.onTapUp != null)).evaluate()) {
    final box = e.renderObject as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) continue;
    final r = box.localToGlobal(Offset.zero) & box.size;
    if (r.width >= T.panel * 0.8 && r.height >= T.panel * 0.8) continue;   // the backdrop itself
    rects.add(r);
  }
  return rects;
}

double _farthestCorner(Rect r) {
  const c = Offset(T.panel / 2, T.panel / 2);
  return [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight].map((p) => (p - c).distance).reduce(math.max);
}

void main() {
  for (final id in ['standby', 'hifi_abc123']) {
    testWidgets('every tap target on Now Playing ($id) is on the glass', (tester) async {
      await _pump(tester, _view(activeId: id));
      final targets = _tapTargets(tester);
      expect(targets, isNotEmpty);
      final off = targets.where((r) => _farthestCorner(r) > T.panel / 2).toList();
      expect(off, isEmpty, reason: 'targets reaching past the 540 px edge: $off');
      await _finish(tester);
    });
  }

  testWidgets('play button shows the requested state before mpv confirms', (tester) async {
    final intent = ValueNotifier<bool?>(null);
    final playing = ValueNotifier(false);
    await _pump(tester, _view(activeId: 'hifi_abc123', playIntent: intent, isPlaying: playing));
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

    intent.value = true;          // tapped: the engine records the intent at once
    await tester.pump();
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);

    playing.value = true;         // mpv confirms, the engine clears the intent
    intent.value = null;
    await tester.pump();
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    await _finish(tester);
  });
}
