import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Side colors, matching the box's verification colors (as seen from the FRONT of the TV).
const sideColors = <String, Color>{
  'left': Color(0xFFFF2D55),
  'top': Color(0xFF2EE59D),
  'right': Color(0xFF2F7BFF),
  'bottom': Color(0xFFFFB13B),
};

const _captions = [
  ('Start at the corner marked START', 'Behind the TV: bottom-right corner. (From the front it\'s bottom-left.)'),
  ('Go up the side', 'Stick the strip about 3 cm in from the edge.'),
  ('Across the top', 'Curve it gently at the corner — never fold it flat.'),
  ('Down the other side', 'Keep the LEDs facing outward, toward the wall.'),
  ('Along the bottom', 'Finish next to where you started. Spare LEDs can stay at the end.'),
];

/// Animated install tutorial: the back of the TV, with the strip laying itself LED by LED.
class TvInstallAnimation extends StatefulWidget {
  const TvInstallAnimation({super.key, required this.counts});

  final Map<String, int> counts;

  @override
  State<TvInstallAnimation> createState() => _TvInstallAnimationState();
}

class _TvInstallAnimationState extends State<TvInstallAnimation> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 9))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// 0 = start marker, 1-4 = sides, holding on 4 at the end.
  int _stage(double t) {
    if (t < 0.10) return 0;
    final p = ((t - 0.10) / 0.78).clamp(0.0, 0.9999);
    return 1 + (p * 4).floor();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      AspectRatio(
        aspectRatio: 16 / 10.5,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) => CustomPaint(painter: _InstallPainter(_c.value, widget.counts)),
        ),
      ),
      const SizedBox(height: 14),
      AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final stage = _stage(_c.value);
          final (title, body) = _captions[stage];
          return Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < _captions.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == stage ? 22 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: i == stage ? Colors.white : SL.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(a),
                  child: child,
                ),
              ),
              child: Column(
                key: ValueKey(stage),
                children: [
                  Text('${stage + 1}. $title',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: SL.text, fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(body, textAlign: TextAlign.center, style: const TextStyle(color: SL.muted)),
                ],
              ),
            ),
          ]);
        },
      ),
    ]);
  }
}

class _InstallPainter extends CustomPainter {
  _InstallPainter(this.t, this.counts);

  final double t;
  final Map<String, int> counts;

  @override
  void paint(Canvas canvas, Size size) {
    final pad = size.width * 0.06;
    final tv = Rect.fromLTWH(pad, pad * 0.6, size.width - 2 * pad, size.height - pad * 1.6);

    // TV back panel with a subtle stand mount in the middle.
    canvas.drawRRect(RRect.fromRectAndRadius(tv, const Radius.circular(14)), Paint()..color = SL.cardHigh);
    canvas.drawRRect(
      RRect.fromRectAndRadius(tv, const Radius.circular(14)),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = SL.border
        ..strokeWidth = 1.5,
    );
    final mount = Rect.fromCenter(center: tv.center, width: tv.width * 0.28, height: tv.height * 0.32);
    canvas.drawRRect(RRect.fromRectAndRadius(mount, const Radius.circular(8)), Paint()..color = SL.card);
    _text(canvas, 'BACK OF THE TV', mount.center, SL.faint, 11, bold: true);

    // Strip route (back view): bottom-right -> top-right -> top-left -> bottom-left -> bottom-right.
    final r = tv.deflate(tv.shortestSide * 0.09);
    final corners = [r.bottomRight, r.topRight, r.topLeft, r.bottomLeft, r.bottomRight];
    const sides = ['left', 'top', 'right', 'bottom']; // as named from the FRONT
    final lengths = [for (var i = 0; i < 4; i++) (corners[i + 1] - corners[i]).distance];
    final total = lengths.reduce((a, b) => a + b);

    // Progress along the route.
    final drawP = t < 0.10 ? 0.0 : ((t - 0.10) / 0.78).clamp(0.0, 1.0);
    final done = drawP * total;
    final spacing = math.max(7.0, size.width / 70);

    Offset? head;
    var walked = 0.0;
    for (var i = 0; i < 4; i++) {
      final a = corners[i], b = corners[i + 1];
      final len = lengths[i];
      final dir = (b - a) / len;
      final color = sideColors[sides[i]]!;
      for (var d = spacing / 2; d < len; d += spacing) {
        final pos = a + dir * d;
        final lit = walked + d <= done;
        canvas.drawCircle(pos, spacing * 0.28, Paint()..color = lit ? color : const Color(0xFF3A3A3A));
        if (lit) {
          canvas.drawCircle(
            pos,
            spacing * 0.55,
            Paint()
              ..color = color.withAlpha(70)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
          );
        }
      }
      if (done >= walked && done <= walked + len) head = a + dir * (done - walked);
      // LED count label once the side is finished.
      if (done >= walked + len) {
        final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
        final label = switch (i) {
          0 => mid + const Offset(-34, 0),
          1 => mid + const Offset(0, 18),
          2 => mid + const Offset(34, 0),
          _ => mid + const Offset(0, -18),
        };
        _text(canvas, '${counts[sides[i]] ?? 0}', label, color, 13, bold: true);
      }
      walked += len;
    }

    // The light running ahead of the strip.
    if (head != null && drawP < 1) {
      canvas.drawCircle(
        head,
        spacing * 1.6,
        Paint()
          ..color = Colors.white.withAlpha(120)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
      canvas.drawCircle(head, spacing * 0.45, Paint()..color = Colors.white);
    }

    // START marker, pulsing.
    final pulse = (math.sin(t * 2 * math.pi * 4) + 1) / 2;
    final start = corners.first;
    canvas.drawCircle(start, 10 + 6 * pulse, Paint()..color = Colors.white.withAlpha((90 * (1 - pulse)).round() + 20));
    canvas.drawCircle(start, 7, Paint()..color = Colors.white);
    _text(canvas, 'START', Offset(start.dx - 6, tv.bottom + pad * 0.5), Colors.white, 11, bold: true);
  }

  void _text(Canvas canvas, String s, Offset center, Color color, double size, {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(color: color, fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, letterSpacing: 0.6),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _InstallPainter old) => old.t != t || old.counts != counts;
}

/// A TV outline that grows with the chosen size.
class TvSizePreview extends StatelessWidget {
  const TvSizePreview({super.key, required this.inches});

  final double inches;

  @override
  Widget build(BuildContext context) {
    final f = ((inches - 32) / (85 - 32)).clamp(0.0, 1.0);
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth * (0.5 + 0.45 * f);
      return SizedBox(
        height: c.maxWidth * 0.58,
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: w),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (context, width, _) => Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: width,
                height: width * 9 / 16,
                decoration: BoxDecoration(
                  color: SL.bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: SL.text, width: 3),
                  boxShadow: [
                    BoxShadow(color: SL.rgb[3].withAlpha(70), blurRadius: 30, offset: const Offset(-12, 0)),
                    BoxShadow(color: SL.rgb[0].withAlpha(70), blurRadius: 30, offset: const Offset(12, 0)),
                  ],
                ),
                alignment: Alignment.center,
                child: Text('${inches.round()}"',
                    style: TextStyle(color: SL.text, fontSize: 18 + 16 * f, fontWeight: FontWeight.w700)),
              ),
              Container(width: width * 0.18, height: 6, color: SL.text),
              Container(width: width * 0.32, height: 4, decoration: BoxDecoration(color: SL.text, borderRadius: BorderRadius.circular(2))),
            ]),
          ),
        ),
      );
    });
  }
}

/// A close-up of the strip around the cursor: green = cursor, red = corners already marked.
class StripCursor extends StatelessWidget {
  const StripCursor({super.key, required this.ledCount, required this.cursor, required this.marks});

  final int ledCount;
  final int cursor;
  final List<int> marks;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: cursor.toDouble()),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, pos, _) => SizedBox(
        height: 64,
        child: CustomPaint(painter: _StripPainter(ledCount, pos, cursor, marks), size: Size.infinite),
      ),
    );
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.count, this.pos, this.cursor, this.marks);

  final int count;
  final double pos;
  final int cursor;
  final List<int> marks;

  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 22.0;
    final cy = size.height / 2;
    final cx = size.width / 2;
    final tape = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, cy - 11, size.width, 22),
      const Radius.circular(6),
    );
    canvas.drawRRect(tape, Paint()..color = SL.cardHigh);
    final first = (pos - cx / spacing).floor() - 1;
    final last = (pos + cx / spacing).ceil() + 1;
    for (var i = first; i <= last; i++) {
      if (i < 0 || (count > 0 && i >= count)) continue;
      final x = cx + (i - pos) * spacing;
      Color c = const Color(0xFF3A3A3A);
      if (marks.contains(i)) c = sideColors['left']!;
      if (i == cursor) c = SL.good;
      if (c != const Color(0xFF3A3A3A)) {
        canvas.drawCircle(
          Offset(x, cy),
          16,
          Paint()
            ..color = c.withAlpha(90)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
        );
      }
      canvas.drawCircle(Offset(x, cy), 6, Paint()..color = c);
    }
    // Fade the ends.
    final fade = Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(size.width, 0),
        [SL.card, SL.card.withAlpha(0), SL.card.withAlpha(0), SL.card],
        [0, 0.18, 0.82, 1],
      );
    canvas.drawRect(Offset.zero & size, fade);
  }

  @override
  bool shouldRepaint(covariant _StripPainter old) => old.pos != pos || old.cursor != cursor || old.marks != marks;
}

/// Front view of the TV with each edge glowing in its verification color.
class TvSidesPreview extends StatefulWidget {
  const TvSidesPreview({super.key});

  @override
  State<TvSidesPreview> createState() => _TvSidesPreviewState();
}

class _TvSidesPreviewState extends State<TvSidesPreview> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 10,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(painter: _SidesPainter(Curves.easeInOut.transform(_c.value))),
      ),
    );
  }
}

class _SidesPainter extends CustomPainter {
  _SidesPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final tv = Rect.fromLTWH(size.width * 0.12, size.height * 0.12, size.width * 0.76, size.height * 0.7);
    final glow = 10 + 10 * t;
    void edge(Offset a, Offset b, Color c) {
      canvas.drawLine(a, b, Paint()
        ..color = c.withAlpha((120 + 100 * t).round())
        ..strokeWidth = 16
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, glow));
      canvas.drawLine(a, b, Paint()
        ..color = c
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round);
    }

    final g = tv.inflate(10);
    edge(g.bottomLeft, g.topLeft, sideColors['left']!);
    edge(g.topLeft, g.topRight, sideColors['top']!);
    edge(g.topRight, g.bottomRight, sideColors['right']!);
    edge(g.bottomRight, g.bottomLeft, sideColors['bottom']!);
    canvas.drawRRect(RRect.fromRectAndRadius(tv, const Radius.circular(8)), Paint()..color = Colors.black);
    canvas.drawRRect(
      RRect.fromRectAndRadius(tv, const Radius.circular(8)),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = SL.border
        ..strokeWidth = 2,
    );
    final tp = TextPainter(
      text: const TextSpan(text: 'FRONT OF THE TV', style: TextStyle(color: SL.faint, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.6)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, tv.center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _SidesPainter old) => old.t != t;
}
