// Screensaver: an overlay, not a mode. The clock uses the player's display face (Bebas, 300 px) at 30 % grey, so
// the idle screen and Now Playing are one object; nothing underneath is unmounted, a tap brings the player back.
import 'dart:async';
import 'package:flutter/material.dart';
import 'model.dart';
import 'tokens.dart';

const _dim = Color(0xFF5E6572);
const _dimmer = Color(0xFF4B515D);

class Screensaver extends StatelessWidget {
  const Screensaver({super.key, required this.view, required this.onWake, this.standby = false});
  final HudView view;
  final VoidCallback onWake;
  final bool standby; // asleep (playback stopped): show the hint instead of the "still playing" line

  @override
  Widget build(BuildContext context) {
    final v = view;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onWake,
      onPanDown: (_) => onWake(),
      child: Container(
        color: const Color(0xFF030304),
        child: Stack(
          children: [
            // Paused (not asleep): the cover, blurred and barely there - "it's still here", not a wallpaper. The blur is
            // a 32 px decode stretched over the disc (bilinear) at 10 % instead of a sigma-36 Gaussian over a full-size
            // decode inside an opacity layer: at this alpha they should read the same, and it costs one textured quad.
            if (!standby && !v.isStandby)
              Positioned.fill(
                child: RepaintBoundary(
                  child: Cover(v.isHiFi ? 'http://127.0.0.1:8000/api/hifi/cover?track_id=${v.activeId}' : 'http://127.0.0.1:8000/media/${v.activeId}/cover.jpg',
                      decodeSize: 32, opacity: 0.10, filterQuality: FilterQuality.medium),
                ),
              ),
            // Only the clock (and its date line) ticks every second
            Positioned.fill(child: RepaintBoundary(child: _ClockFace(view: v))),
            Positioned(
              left: 160, right: 160, top: 700,
              child: ValueListenableBuilder<bool>(
                valueListenable: v.isPlaying,
                builder: (_, playing, __) => standby
                    ? const Text('TAP TO WAKE', textAlign: TextAlign.center, style: TextStyle(fontFamily: T.monoFace, fontSize: 20, fontWeight: FontWeight.w500, color: _dimmer, letterSpacing: 6))
                    : playing && !v.isStandby
                    ? Column(
                        children: [
                          Text(v.title.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                              style: const TextStyle(fontFamily: T.display, fontSize: 54, height: 1.0, color: _dimmer, letterSpacing: 1)),
                          const SizedBox(height: 6),
                          Text('${v.artist}  ·  still playing', maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                              style: const TextStyle(fontFamily: T.text, fontSize: 24, fontWeight: FontWeight.w300, color: _dimmer)),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClockFace extends StatefulWidget {
  const _ClockFace({required this.view});
  final HudView view;

  @override
  State<_ClockFace> createState() => _ClockFaceState();
}

class _ClockFaceState extends State<_ClockFace> {
  Timer? _t;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() => _now = DateTime.now()); });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final h12 = _now.hour % 12 == 0 ? 12 : _now.hour % 12;
    final hh = v.clock24h ? _now.hour.toString().padLeft(2, '0') : h12.toString();
    final mm = _now.minute.toString().padLeft(2, '0');
    final ampm = v.clock24h ? '' : (_now.hour < 12 ? 'AM' : 'PM');
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    final date = '${days[_now.weekday - 1]} ${_now.day} ${months[_now.month - 1]}';
    final blink = _now.second.isEven;
    const clock = TextStyle(fontFamily: T.display, fontSize: 300, height: 1.0, color: Color(0xFFB7BDC9), letterSpacing: 4, fontFeatures: [FontFeature.tabularFigures()]);

    return Stack(
      children: [
        Positioned(
          left: 0, right: 0, top: 296,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(hh, style: clock),
              // The colon dims via its colour (an Opacity here was a compositing layer every other second)
              Text(':', style: TextStyle(fontFamily: T.display, fontSize: 260, height: 1.15, color: blink ? _dim : _dim.withValues(alpha: 0.3))),
              Text(mm, style: clock),
              if (ampm.isNotEmpty) ...[
                const SizedBox(width: 18),
                Padding(
                  padding: const EdgeInsets.only(top: 196),
                  child: Text(ampm, style: const TextStyle(fontFamily: T.display, fontSize: 64, height: 1.0, color: _dim, letterSpacing: 2)),
                ),
              ],
            ],
          ),
        ),
        Positioned(
          left: 0, right: 0, top: 612,
          child: Text(
            v.weatherCity.isNotEmpty ? '$date  ·  ${v.weatherTemp.round()}° ${v.weatherCondition}  ·  ${v.weatherCity}' : date,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontFamily: T.text, fontSize: 32, fontWeight: FontWeight.w300, color: _dim),
          ),
        ),
      ],
    );
  }
}
