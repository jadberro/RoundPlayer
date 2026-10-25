// On-screen keyboard sized for a finger on a 5" panel: keys 72x84 px, 10 px gaps. Widest row (10 keys) is 810 px,
// which fits inside the r=430 band when placed at y 560-850 on the disc.
import 'package:flutter/material.dart';
import 'tokens.dart';

class BigKeyboard extends StatefulWidget {
  const BigKeyboard({super.key, required this.onKey, required this.onBackspace, required this.onSubmit, this.submitLabel = 'Go', this.submitColor = T.cyan, this.onSpace});
  final void Function(String) onKey;
  final VoidCallback onBackspace;
  final VoidCallback onSubmit;
  final VoidCallback? onSpace;
  final String submitLabel;
  final Color submitColor;

  @override
  State<BigKeyboard> createState() => _BigKeyboardState();
}

class _BigKeyboardState extends State<BigKeyboard> {
  bool _shift = false;
  bool _symbols = false;

  static const _rows = [
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    ['z', 'x', 'c', 'v', 'b', 'n', 'm'],
  ];
  static const _sym = [
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    ['-', '_', '@', '#', '&', '*', '(', ')', '!'],
    ['.', ',', '?', ':', ';', '/', '+'],
    ['\'', '"', '%', '=', '~', '^', '\$'],
  ];

  Widget _key(String label, {double w = 72, VoidCallback? onTap, Color? fill, Color? fg, double fs = 34, IconData? icon}) {
    return _Key(label: label, w: w, onTap: onTap, fill: fill, fg: fg, fs: fs, icon: icon);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _symbols ? _sym : _rows;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int r = 0; r < rows.length; r++) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_symbols && r == 2)
                _key('', icon: Icons.keyboard_capslock_rounded, fill: _shift ? const Color(0x33FFFFFF) : null, onTap: () => setState(() => _shift = !_shift)),
              if (!_symbols && r == 2) const SizedBox(width: 10),
              for (int i = 0; i < rows[r].length; i++) ...[
                _key(_shift && !_symbols ? rows[r][i].toUpperCase() : rows[r][i], onTap: () {
                  widget.onKey(_shift && !_symbols ? rows[r][i].toUpperCase() : rows[r][i]);
                  if (_shift) setState(() => _shift = false);
                }),
                if (i < rows[r].length - 1) const SizedBox(width: 10),
              ],
              if (r == 2) const SizedBox(width: 10),
              if (r == 2) _key('', icon: Icons.backspace_outlined, onTap: widget.onBackspace),
            ],
          ),
          const SizedBox(height: 10),
        ],
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _key(_symbols ? 'abc' : '?123', w: 170, fs: 24, fg: T.mute, onTap: () => setState(() => _symbols = !_symbols)),
            const SizedBox(width: 10),
            _key('space', w: 260, fs: 24, fg: T.mute, onTap: widget.onSpace ?? () => widget.onKey(' ')),
            const SizedBox(width: 10),
            _key(widget.submitLabel, w: 170, fs: 26, fill: widget.submitColor, fg: T.inkOnAccent, onTap: widget.onSubmit),
          ],
        ),
      ],
    );
  }
}

class _Key extends StatefulWidget {
  const _Key({required this.label, required this.w, this.onTap, this.fill, this.fg, this.fs = 34, this.icon});
  final String label;
  final double w;
  final VoidCallback? onTap;
  final Color? fill;
  final Color? fg;
  final double fs;
  final IconData? icon;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: Container(
        width: widget.w,
        height: 84,
        decoration: BoxDecoration(
          color: _down ? const Color(0x55FFFFFF) : (widget.fill ?? T.cardRaised),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0x1FFFFFFF), width: 2),
        ),
        child: Center(
          child: widget.icon != null
              ? Icon(widget.icon, size: 38, color: widget.fg ?? T.fg)
              : Text(widget.label, style: TextStyle(fontSize: widget.fs, fontWeight: widget.fill != null ? FontWeight.w800 : FontWeight.w600, color: widget.fg ?? T.fg)),
        ),
      ),
    );
  }
}

/// Text field look-alike (no IME on the Pi): 104 px tall, 34 px glyphs, blinking caret.
class BigField extends StatelessWidget {
  const BigField({super.key, required this.text, this.obscure = false, this.placeholder = '', this.trailing, this.accent = T.cyan});
  final String text;
  final bool obscure;
  final String placeholder;
  final Widget? trailing;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final shown = obscure ? '•' * text.length : text;
    return Container(
      height: 104,
      padding: const EdgeInsets.symmetric(horizontal: 30),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E18),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: accent, width: 3),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              shown.isEmpty ? placeholder : shown,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 34, letterSpacing: obscure ? 4 : 0.5, color: shown.isEmpty ? T.mute : T.fg, fontWeight: FontWeight.w600),
            ),
          ),
          Container(width: 3, height: 44, color: accent),
          if (trailing != null) ...[const SizedBox(width: 20), trailing!],
        ],
      ),
    );
  }
}
