import 'package:flutter/material.dart';

/// RGB helpers that don't rely on Color's channel getters (they change between Flutter versions).
List<int> hsvToRgb(double hue, double sat, double val) {
  final c = val * sat;
  final hp = (hue % 360) / 60.0;
  final x = c * (1 - ((hp % 2) - 1).abs());
  double r = 0, g = 0, b = 0;
  if (hp < 1) {
    r = c; g = x;
  } else if (hp < 2) {
    r = x; g = c;
  } else if (hp < 3) {
    g = c; b = x;
  } else if (hp < 4) {
    g = x; b = c;
  } else if (hp < 5) {
    r = x; b = c;
  } else {
    r = c; b = x;
  }
  final m = val - c;
  return [((r + m) * 255).round(), ((g + m) * 255).round(), ((b + m) * 255).round()];
}

Color rgbColor(List<int> rgb) => Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);

const presetColors = <List<int>>[
  [255, 170, 90], // warm white
  [255, 255, 255],
  [255, 0, 0],
  [255, 110, 0],
  [255, 220, 0],
  [0, 255, 60],
  [0, 220, 255],
  [0, 40, 255],
  [150, 0, 255],
  [255, 0, 140],
];

/// A rainbow bar you drag along, plus a row of preset swatches.
class ColorPicker extends StatefulWidget {
  const ColorPicker({super.key, required this.color, required this.onChanged});

  final List<int> color;
  final ValueChanged<List<int>> onChanged;

  @override
  State<ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<ColorPicker> {
  double? _dragHue;

  void _pick(double dx, double width, {required bool done}) {
    final hue = (dx / width).clamp(0.0, 1.0) * 359.0;
    setState(() => _dragHue = done ? null : hue);
    if (done) widget.onChanged(hsvToRgb(hue, 1, 1));
  }

  @override
  Widget build(BuildContext context) {
    final hues = [for (var h = 0; h <= 360; h += 60) rgbColor(hsvToRgb(h.toDouble(), 1, 1))];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(builder: (context, constraints) {
          final w = constraints.maxWidth;
          return GestureDetector(
            onTapUp: (d) => _pick(d.localPosition.dx, w, done: true),
            onHorizontalDragUpdate: (d) => _pick(d.localPosition.dx, w, done: false),
            onHorizontalDragEnd: (_) {
              final h = _dragHue;
              if (h != null) _pick(h / 359.0 * w, w, done: true);
            },
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(colors: hues),
              ),
              alignment: Alignment((((_dragHue ?? -1) / 359.0) * 2 - 1).clamp(-1.0, 1.0), 0),
              child: _dragHue == null
                  ? null
                  : Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: rgbColor(hsvToRgb(_dragHue!, 1, 1)),
                        border: Border.all(color: Colors.white, width: 3),
                      ),
                    ),
            ),
          );
        }),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in presetColors)
              GestureDetector(
                onTap: () => widget.onChanged(c),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: rgbColor(c),
                    border: Border.all(
                      color: _same(c, widget.color)
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.outlineVariant,
                      width: _same(c, widget.color) ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  bool _same(List<int> a, List<int> b) => a.length == 3 && b.length == 3 && a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}
