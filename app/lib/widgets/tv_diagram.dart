import 'package:flutter/material.dart';

/// Side colors, matching the box's verification colors (as seen from the FRONT of the TV).
const sideColors = <String, Color>{
  'left': Color(0xFFFF2020),
  'top': Color(0xFF00C853),
  'right': Color(0xFF2962FF),
  'bottom': Color(0xFFFFB300),
};

/// The back of the TV with the strip route drawn on it.
///
/// Seen from the back, the TV's left and right are swapped: the FRONT-left edge is on the
/// right of this drawing. The strip starts at the front's bottom-left corner, which is the
/// bottom-RIGHT corner when you stand behind the TV.
class TvBackDiagram extends StatelessWidget {
  const TvBackDiagram({super.key, required this.counts});

  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 10.5,
      child: CustomPaint(
        painter: _TvBackPainter(counts, Theme.of(context).colorScheme),
      ),
    );
  }
}

class _TvBackPainter extends CustomPainter {
  _TvBackPainter(this.counts, this.scheme);

  final Map<String, int> counts;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final pad = size.width * 0.07;
    final tv = Rect.fromLTWH(pad, pad, size.width - 2 * pad, size.height - 2 * pad - 18);
    final body = Paint()..color = scheme.surfaceContainerHighest;
    canvas.drawRRect(RRect.fromRectAndRadius(tv, const Radius.circular(10)), body);
    _text(canvas, 'BACK OF THE TV', tv.center, scheme.onSurfaceVariant, 13, bold: true);

    final inset = tv.deflate(tv.width * 0.04);
    // Drawing coordinates (back view): front-left side is drawn on the RIGHT.
    final br = inset.bottomRight, tr = inset.topRight, tl = inset.topLeft, bl = inset.bottomLeft;
    final segments = <(String, Offset, Offset)>[
      ('left', br, tr),
      ('top', tr, tl),
      ('right', tl, bl),
      ('bottom', bl, br),
    ];
    for (final (side, a, b) in segments) {
      final p = Paint()
        ..color = sideColors[side]!
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(a, b, p);
      _arrow(canvas, a, b, sideColors[side]!);
      final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
      // Label just inside the strip line.
      final label = switch (side) {
        'left' => Offset(mid.dx - 40, mid.dy),
        'right' => Offset(mid.dx + 40, mid.dy),
        'top' => Offset(mid.dx, mid.dy + 18),
        _ => Offset(mid.dx, mid.dy - 18),
      };
      _text(canvas, '${counts[side] ?? 0} LEDs', label, scheme.onSurface, 12, bold: true);
    }

    // Start marker.
    canvas.drawCircle(br, 11, Paint()..color = scheme.primary);
    canvas.drawCircle(br, 5, Paint()..color = scheme.onPrimary);
    _text(canvas, 'START', Offset(br.dx - 4, tv.bottom + 14), scheme.primary, 12, bold: true);
    _text(canvas, 'wires', Offset(br.dx + pad * 0.55, br.dy), scheme.onSurfaceVariant, 10);
  }

  void _arrow(Canvas canvas, Offset a, Offset b, Color color) {
    final mid = Offset(a.dx + (b.dx - a.dx) * 0.62, a.dy + (b.dy - a.dy) * 0.62);
    final dir = (b - a);
    final len = dir.distance;
    if (len == 0) return;
    final u = dir / len;
    final n = Offset(-u.dy, u.dx);
    final path = Path()
      ..moveTo(mid.dx + u.dx * 9, mid.dy + u.dy * 9)
      ..lineTo(mid.dx - u.dx * 7 + n.dx * 8, mid.dy - u.dy * 7 + n.dy * 8)
      ..lineTo(mid.dx - u.dx * 7 - n.dx * 8, mid.dy - u.dy * 7 - n.dy * 8)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _text(Canvas canvas, String s, Offset center, Color color, double size, {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w400),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _TvBackPainter old) => old.counts != counts || old.scheme != scheme;
}
