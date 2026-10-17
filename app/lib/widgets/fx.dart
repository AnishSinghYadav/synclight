import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A rotating RGB ring with a soft glow — the SyncLight logo, also used as a "busy" indicator.
class RgbRing extends StatefulWidget {
  const RgbRing({super.key, this.size = 120, this.thickness = 6, this.seconds = 6, this.child, this.glow = true});

  final double size;
  final double thickness;
  final int seconds;
  final Widget? child;
  final bool glow;

  @override
  State<RgbRing> createState() => _RgbRingState();
}

class _RgbRingState extends State<RgbRing> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: Duration(seconds: widget.seconds))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) => CustomPaint(
          painter: _RingPainter(_c.value, widget.thickness, widget.glow),
          child: child,
        ),
        child: Center(child: widget.child),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.t, this.thickness, this.glow);

  final double t;
  final double thickness;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = rect.deflate(thickness * 2.2);
    final shader = SweepGradient(
      colors: SL.rgb,
      transform: GradientRotation(t * 2 * math.pi),
    ).createShader(r);
    if (glow) {
      canvas.drawOval(
        r,
        Paint()
          ..shader = shader
          ..style = PaintingStyle.stroke
          ..strokeWidth = thickness * 2.4
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, thickness * 2.2),
      );
    }
    canvas.drawOval(
      r,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.t != t;
}

/// Fades and slides its child in after [delay] — used to stagger screen content.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({super.key, required this.child, this.delay = Duration.zero, this.offset = 18});

  final Widget child;
  final Duration delay;
  final double offset;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(offset: Offset(0, widget.offset * (1 - _t.value)), child: child),
      ),
      child: widget.child,
    );
  }
}

/// Shrinks slightly while pressed.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: widget.onTap == null ? null : (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 120),
        child: widget.child,
      ),
    );
  }
}

/// Rounded dark card with a hairline border.
class SLCard extends StatelessWidget {
  const SLCard({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.onTap, this.color});

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? SL.card,
        borderRadius: BorderRadius.circular(SL.radius),
        border: Border.all(color: SL.border),
      ),
      child: child,
    );
    return onTap == null ? card : Pressable(onTap: onTap, child: card);
  }
}

/// Text painted with the RGB gradient.
class RgbText extends StatelessWidget {
  const RgbText(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (r) => const LinearGradient(colors: SL.rgb).createShader(r),
      blendMode: BlendMode.srcIn,
      child: Text(text, style: style),
    );
  }
}

/// "Made by Anish" footer.
class MadeBy extends StatelessWidget {
  const MadeBy({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Made by ', style: TextStyle(color: SL.faint, fontSize: 13)),
          RgbText('Anish', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const Text('  ·  SyncLight', style: TextStyle(color: SL.faint, fontSize: 13)),
        ],
      ),
    );
  }
}

/// A dot that pulses outward — "searching" / "live".
class PulseDot extends StatefulWidget {
  const PulseDot({super.key, this.color = SL.good, this.size = 10});

  final Color color;
  final double size;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s * 3,
      height: s * 3,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          return Stack(alignment: Alignment.center, children: [
            Container(
              width: s + s * 2 * t,
              height: s + s * 2 * t,
              decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color.withAlpha(((1 - t) * 110).round())),
            ),
            Container(width: s, height: s, decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color)),
          ]);
        },
      ),
    );
  }
}

/// Glowing orb that previews the light: a solid color, or a slowly turning rainbow.
class GlowOrb extends StatefulWidget {
  const GlowOrb({super.key, required this.color, this.rainbow = false, this.on = true, this.size = 150, this.brightness = 1});

  final Color color;
  final bool rainbow;
  final bool on;
  final double size;
  final double brightness;

  @override
  State<GlowOrb> createState() => _GlowOrbState();
}

class _GlowOrbState extends State<GlowOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 8))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    final level = widget.on ? (0.35 + 0.65 * widget.brightness.clamp(0.0, 1.0)) : 0.0;
    return SizedBox(
      width: s * 1.6,
      height: s * 1.6,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final breathe = 0.92 + 0.08 * math.sin(_c.value * 2 * math.pi * 2);
          final Gradient fill = widget.rainbow
              ? SweepGradient(colors: SL.rgb, transform: GradientRotation(_c.value * 2 * math.pi))
              : RadialGradient(colors: [Color.lerp(widget.color, Colors.white, 0.25)!, widget.color]);
          return Center(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 400),
              opacity: widget.on ? 1 : 0.25,
              child: Stack(alignment: Alignment.center, children: [
                // Glow.
                Transform.scale(
                  scale: breathe,
                  child: Container(
                    width: s * 1.35,
                    height: s * 1.35,
                    decoration: BoxDecoration(shape: BoxShape.circle, gradient: fill),
                  ),
                ),
                // Blur the glow by layering a dark veil with a radial cutout.
                Container(
                  width: s * 1.4,
                  height: s * 1.4,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      Colors.transparent,
                      SL.bg.withAlpha((255 * (1 - 0.55 * level)).round()),
                      SL.bg,
                    ], stops: const [0.45, 0.7, 1.0]),
                  ),
                ),
                // Core.
                Container(
                  width: s * 0.72,
                  height: s * 0.72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: fill,
                    border: Border.all(color: Colors.white.withAlpha(40), width: 1.5),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/// Section title in the muted style.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(children: [
        Expanded(
          child: Text(text.toUpperCase(),
              style: const TextStyle(color: SL.muted, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.1)),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}
