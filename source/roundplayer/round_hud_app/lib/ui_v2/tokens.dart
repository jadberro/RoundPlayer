// Design tokens for the 1080x1080 round panel (read from an armchair at 60-90 cm, operated with a finger).
// Every size is in panel pixels; the shell scales the whole tree with `s = size / 1080`.
import 'dart:math' as math;
import 'package:flutter/material.dart';

class T {
  // Geometry
  static const double panel = 1080;
  static const double contentRadius = 430; // nothing important beyond this radius
  static const double tap = 112;           // secondary button
  static const double tapPrimary = 152;    // play / pause
  static const double rowH = 112;          // list row
  static const double tabH = 92;

  // List-screen geometry, checked against the circle: header at y 110-180 (chord 2x337 at y 110 -> 250 inset),
  // body 214..830 (inset 180 = 720 wide, chord >= 2x430 over that band), tab pills 838..930 (<= 700 wide fits the
  // chord 2x373 at their bottom edge).
  static const double headerTop = 110;
  static const double headerInset = 250;
  static const double bodyTop = 214;
  static const double bodyBottom = 250;
  static const double bodyInset = 230;  // 620 wide: clears the 112 px diameter buttons at 96..208 / 872..984
  static const double tabsBottom = 150;
  static const double diameterY = 420; // 112 px buttons at (96, 420) and (872, 420): centre r = 388

  // Colors - few, used consistently: cyan = video, gold = Hi-Fi, green = live/healthy, red = error.
  static const Color bg = Color(0xFF05070B);
  static const Color card = Color(0xFF121622);
  static const Color cardRaised = Color(0xFF1A1F2D);
  static const Color line = Color(0x17FFFFFF);
  static const Color fg = Color(0xFFEEF2F8);
  static const Color mute = Color(0xFF8F9AB0);
  static const Color cyan = Color(0xFF4FD6FF);
  static const Color gold = Color(0xFFF2C14E);
  static const Color good = Color(0xFF34D399);
  static const Color bad = Color(0xFFF87171);
  static const Color inkOnAccent = Color(0xFF061018);

  // Type - D "Gallery x Editorial": Bebas (display, caps), Inter Tight (text), IBM Plex Mono (readouts)
  static const String display = 'Bebas';
  static const String text = 'InterTight';
  static const String monoFace = 'PlexMono';
  static const TextStyle title = TextStyle(fontFamily: display, fontSize: 124, height: 0.92, color: Color(0xFFF6F7FA), letterSpacing: 1.2);
  static const TextStyle subtitle = TextStyle(fontFamily: text, fontSize: 30, fontWeight: FontWeight.w300, color: Color(0xFFC3CAD8), height: 1.2);
  static const TextStyle h = TextStyle(fontFamily: display, fontSize: 56, height: 1.0, color: fg, letterSpacing: 1.0);
  static const TextStyle eyebrow = TextStyle(fontFamily: monoFace, fontSize: 19, fontWeight: FontWeight.w500, color: mute, letterSpacing: 5);
  static const TextStyle rowTitle = TextStyle(fontFamily: text, fontSize: 30, fontWeight: FontWeight.w600, color: fg);
  static const TextStyle rowSub = TextStyle(fontFamily: text, fontSize: 22, fontWeight: FontWeight.w400, color: mute);
  static const TextStyle body = TextStyle(fontFamily: text, fontSize: 24, fontWeight: FontWeight.w400, color: fg);
  static const TextStyle mono = TextStyle(fontFamily: monoFace, fontSize: 20, fontWeight: FontWeight.w500, color: Color(0xFFAAB2C2), fontFeatures: [FontFeature.tabularFigures()]);
  static const TextStyle pill = TextStyle(fontFamily: monoFace, fontSize: 19, fontWeight: FontWeight.w600, letterSpacing: 3);
  static const TextStyle tab = TextStyle(fontFamily: text, fontSize: 24, fontWeight: FontWeight.w600);
}

/// Round glass button: >= 96 px, press state within one frame (scale on touch-down, no async wait).
class RoundButton extends StatefulWidget {
  const RoundButton({super.key, required this.child, required this.onTap, this.size = T.tap, this.fill, this.border, this.onLongPress});
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double size;
  final Color? fill;
  final Color? border;

  @override
  State<RoundButton> createState() => _RoundButtonState();
}

class _RoundButtonState extends State<RoundButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final fill = widget.fill ?? const Color(0xB80E121C);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 70),
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: _down ? fill.withValues(alpha: 1.0) : fill,
            shape: BoxShape.circle,
            border: Border.all(color: widget.border ?? const Color(0x33FFFFFF), width: 2),
            boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 30, offset: Offset(0, 10))],
          ),
          child: Center(child: widget.child),
        ),
      ),
    );
  }
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color = T.fg, this.dot = false});
  final String text;
  final Color color;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x59000000),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: color == T.fg ? 0.22 : 0.6), width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(width: 14, height: 14, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 10),
          ],
          Text(text, style: T.pill.copyWith(color: color)),
        ],
      ),
    );
  }
}

/// A 112 px list row with one optional 84 px action. Highlights on touch-down (before the request goes out).
class BigRow extends StatefulWidget {
  const BigRow({super.key, required this.title, this.subtitle, this.leading, this.onTap, this.onLongPress, this.onAction, this.actionIcon, this.active = false, this.height = T.rowH, this.accent = T.cyan, this.trailingIcon});
  final String title;
  final String? subtitle;
  final Widget? leading;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final IconData? trailingIcon; // small status glyph before the action (e.g. cloud = not cached)
  final VoidCallback? onAction;
  final IconData? actionIcon;
  final bool active;
  final double height;
  final Color accent;

  @override
  State<BigRow> createState() => _BigRowState();
}

class _BigRowState extends State<BigRow> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        height: widget.height,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        decoration: BoxDecoration(
          color: _down ? T.cardRaised : (active ? widget.accent.withValues(alpha: 0.10) : T.card),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: active ? widget.accent : (_down ? const Color(0x40FFFFFF) : const Color(0x14FFFFFF)), width: 2),
        ),
        child: Row(
          children: [
            if (widget.leading != null) ...[
              SizedBox(width: 80, height: 80, child: ClipRRect(borderRadius: BorderRadius.circular(14), child: widget.leading)),
              const SizedBox(width: 22),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.rowTitle.copyWith(fontSize: widget.height < 100 ? 26 : 30)),
                  if (widget.subtitle != null && widget.subtitle!.isNotEmpty)
                    Text(widget.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.rowSub),
                ],
              ),
            ),
            if (widget.trailingIcon != null) ...[
              const SizedBox(width: 12),
              Icon(widget.trailingIcon, size: 34, color: T.mute),
            ],
            if (widget.actionIcon != null) ...[
              const SizedBox(width: 16),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onAction,
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: const BoxDecoration(color: Color(0x14FFFFFF), shape: BoxShape.circle),
                  child: Icon(widget.actionIcon, size: 44, color: active ? widget.accent : T.fg),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class TabPill extends StatelessWidget {
  const TabPill({super.key, required this.label, required this.on, required this.onTap, this.icon});
  final String label;
  final bool on;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: T.tabH,
        padding: EdgeInsets.symmetric(horizontal: label.isEmpty ? 30 : 26),
        decoration: BoxDecoration(
          color: on ? T.cyan.withValues(alpha: 0.10) : T.card,
          borderRadius: BorderRadius.circular(46),
          border: Border.all(color: on ? T.cyan : const Color(0x1AFFFFFF), width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon, size: 36, color: on ? T.fg : T.mute),
            if (icon != null && label.isNotEmpty) const SizedBox(width: 12),
            if (label.isNotEmpty) Text(label, style: T.tab.copyWith(color: on ? T.fg : T.mute)),
          ],
        ),
      ),
    );
  }
}

/// Cover art with a quiet fallback (no broken-image icon, no spinner). A 404 is retried twice, 4 s apart, because the
/// daemon may still be fetching the picture (embedded tag / online lookup) when the first request lands.
///
/// Decoded at the size it is shown (the daemon serves the original file - embedded art can be 3000 px - so an 80 px
/// list thumbnail used to hold a 36 MB bitmap). [decodeSize] overrides the layout-derived size.
class Cover extends StatefulWidget {
  const Cover(this.url, {super.key, this.fallbackIcon = Icons.album_rounded, this.round = false, this.decodeSize, this.opacity = 1.0,
      this.filterQuality = FilterQuality.medium});
  final String? url;
  final IconData fallbackIcon;
  final bool round;
  final int? decodeSize;            // device pixels on the image's short side; null = from the layout box
  final double opacity;             // painted with the image (no extra layer)
  final FilterQuality filterQuality;

  /// The provider a Cover of [logicalSize] uses, so the engine can precache exactly what will be shown.
  static ImageProvider providerFor(String url, double logicalSize, double devicePixelRatio) =>
      _provider(url, (logicalSize * devicePixelRatio).ceil());

  // Height only: square art lands exactly on the box, and landscape art (YouTube thumbnails) keeps its full width
  // for BoxFit.cover. Portrait art (rare) comes out slightly soft. Never upscaled.
  static ImageProvider _provider(String url, int? size) => size == null ? NetworkImage(url) : ResizeImage(NetworkImage(url), height: size);

  @override
  State<Cover> createState() => _CoverState();
}

class _CoverState extends State<Cover> {
  int _attempt = 0;
  bool _retryScheduled = false;

  @override
  void didUpdateWidget(covariant Cover old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) { _attempt = 0; _retryScheduled = false; }
  }

  @override
  Widget build(BuildContext context) {
    Widget fallback = Container(color: T.cardRaised, child: Icon(widget.fallbackIcon, color: T.mute, size: 40));
    if (widget.opacity < 1) fallback = Opacity(opacity: widget.opacity, child: fallback);
    final url = widget.url;
    if (url == null || url.isEmpty) return fallback;
    final sep = url.contains('?') ? '&' : '?';
    final src = _attempt == 0 ? url : '$url${sep}retry=$_attempt';
    return LayoutBuilder(
      builder: (context, c) {
        final box = math.max(c.hasBoundedWidth ? c.maxWidth : 0.0, c.hasBoundedHeight ? c.maxHeight : 0.0);
        final size = widget.decodeSize ?? (box > 0 ? (box * MediaQuery.devicePixelRatioOf(context)).ceil() : null);
        return Image(
          image: Cover._provider(src, size),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: widget.filterQuality,
          opacity: widget.opacity < 1 ? AlwaysStoppedAnimation(widget.opacity) : null,
          errorBuilder: (_, _, _) {
            // errorBuilder runs on every rebuild while in error: schedule one retry at a time
            if (_attempt < 2 && !_retryScheduled) {
              _retryScheduled = true;
              Future.delayed(const Duration(seconds: 4), () { if (mounted) setState(() { _attempt += 1; _retryScheduled = false; }); });
            }
            return fallback;
          },
        );
      },
    );
  }
}

String fmtTime(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// A 112 px setting row with a horizontal slider: label and live value on top, 8 px track with a 36 px thumb.
/// onChanged fires while dragging (throttle it if the target is expensive), onChangeEnd once on release.
class SliderRow extends StatelessWidget {
  const SliderRow({super.key, required this.label, required this.value, required this.min, required this.max, required this.display, required this.onChanged, this.onChangeEnd, this.accent = T.fg, this.center});
  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final void Function(double) onChanged;
  final void Function(double)? onChangeEnd;
  final Color accent;
  final double? center; // draw the fill from this value (e.g. 0 dB) instead of from the left edge

  @override
  Widget build(BuildContext context) {
    final f = ((value - min) / (max - min)).clamp(0.0, 1.0);
    final c = center == null ? 0.0 : ((center! - min) / (max - min)).clamp(0.0, 1.0);
    return Container(
      height: T.rowH,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(color: T.card, borderRadius: BorderRadius.circular(24), border: Border.all(color: T.line, width: 2)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(children: [Expanded(child: Text(label, style: T.rowTitle.copyWith(fontSize: 26))), Text(display, style: T.mono.copyWith(color: T.fg))]),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (_, cons) {
              double frac(double dx) => (dx / cons.maxWidth).clamp(0.0, 1.0);
              double val(double dx) => min + frac(dx) * (max - min);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (d) => onChanged(val(d.localPosition.dx)),
                onHorizontalDragUpdate: (d) => onChanged(val(d.localPosition.dx)),
                onHorizontalDragEnd: (_) => onChangeEnd?.call(value),
                onTapUp: (d) { onChanged(val(d.localPosition.dx)); onChangeEnd?.call(val(d.localPosition.dx)); },
                child: SizedBox(
                  height: 36,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      Container(height: 8, decoration: BoxDecoration(color: const Color(0x2EFFFFFF), borderRadius: BorderRadius.circular(4))),
                      Positioned(
                        left: (f < c ? f : c) * cons.maxWidth, width: ((f - c).abs()) * cons.maxWidth,
                        child: Container(height: 8, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(4))),
                      ),
                      Positioned(left: f * cons.maxWidth - 18, child: Container(width: 36, height: 36, decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 8)]))),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
