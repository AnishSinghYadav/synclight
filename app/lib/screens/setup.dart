import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/fx.dart';
import '../widgets/tv_diagram.dart';

/// TV setup wizard: size -> install guide -> find corners -> check colors -> done.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.api});

  final BoxApi api;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

const _cornerPrompts = [
  ('First LED on the TV', 'Move the green light to the first LED at the bottom-left corner (as seen from the front of the TV). Usually this is LED 1.'),
  ('Start of the top edge', 'Move the green light to the first LED after the top-left corner.'),
  ('Start of the right edge', 'Move the green light to the first LED after the top-right corner.'),
  ('Start of the bottom edge', 'Move the green light to the first LED after the bottom-right corner.'),
  ('Last LED on the TV', 'Move the green light to the last LED of the bottom edge, just before the start corner.'),
];

class _SetupScreenState extends State<SetupScreen> {
  BoxApi get api => widget.api;

  int _step = 0;
  bool _busy = false;

  // Step 0
  double _inches = 55;
  int _density = 60;

  // Step 1
  Map<String, dynamic>? _suggest;
  int _ledCount = 0;

  // Step 2
  bool _calibrating = false;
  final List<int> _marks = [];
  int _cursor = 0;
  bool _sending = false;
  int? _queued;

  // Step 3
  Map<String, dynamic>? _layoutArgs;

  Map<String, int> get _counts {
    final c = (_suggest?['counts'] as Map?) ?? const {};
    return {for (final k in ['left', 'top', 'right', 'bottom']) k: ((c[k] ?? 0) as num).toInt()};
  }

  @override
  void dispose() {
    if (_calibrating) {
      api.call('calibrate.stop').catchError((_) => <String, dynamic>{});
    }
    super.dispose();
  }

  void _snack(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(explainError(e))));
  }

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      _snack(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- step transitions -----------------------------------------------------------
  Future<void> _toInstall() => _run(() async {
        final s = await api.call('install.suggest', {'tv_inches': _inches.round(), 'leds_per_m': _density});
        int count = 0;
        try {
          final st = await api.call('system.status');
          count = (((st['wled'] as Map?)?['led_count'] ?? 0) as num).toInt();
        } catch (_) {}
        setState(() {
          _suggest = s;
          _ledCount = count;
          _step = 1;
        });
      });

  int _guessFor(int markIndex) {
    final c = _counts;
    final guesses = [
      0,
      c['left']!,
      c['left']! + c['top']!,
      c['left']! + c['top']! + c['right']!,
      c['left']! + c['top']! + c['right']! + c['bottom']! - 1,
    ];
    final maxIndex = (_ledCount > 0 ? _ledCount : 1000) - 1;
    final min = _marks.isEmpty ? 0 : _marks.last;
    return guesses[markIndex].clamp(min, maxIndex);
  }

  Future<void> _toCorners() => _run(() async {
        final r = await api.call('calibrate.start');
        _calibrating = true;
        final count = ((r['led_count'] ?? _ledCount) as num).toInt();
        setState(() {
          _ledCount = count;
          _marks.clear();
          _step = 2;
        });
        await _moveCursor(_guessFor(0));
      });

  Future<void> _moveCursor(int index) async {
    setState(() => _cursor = index);
    if (_sending) {
      _queued = index;
      return;
    }
    _sending = true;
    int? next = index;
    while (next != null) {
      final i = next;
      _queued = null;
      try {
        await api.call('calibrate.cursor', {'index': i, 'marks': List<int>.from(_marks)});
      } catch (e) {
        _snack(e);
      }
      next = _queued;
    }
    _sending = false;
  }

  void _markCorner() {
    setState(() => _marks.add(_cursor));
    if (_marks.length == _cornerPrompts.length) {
      _toVerify({
        'marks': {'starts': _marks.sublist(0, 4), 'end': _marks[4]},
        'start_corner': 'bottom_left',
        'direction': 'cw',
      });
    } else {
      _moveCursor(_guessFor(_marks.length));
    }
  }

  void _undoCorner() {
    if (_marks.isEmpty) return;
    final last = _marks.removeLast();
    _moveCursor(last);
  }

  void _useMeasured() {
    _toVerify({'counts': _counts, 'start_corner': 'bottom_left', 'direction': 'cw', 'offset': 0});
  }

  Future<void> _toVerify(Map<String, dynamic> args) => _run(() async {
        await api.call('calibrate.sides', args);
        setState(() {
          _layoutArgs = args;
          _step = 3;
        });
      });

  Future<void> _save() => _run(() async {
        await api.call('layout.apply', _layoutArgs!);
        await api.call('calibrate.stop');
        _calibrating = false;
        setState(() => _step = 4);
      });

  Future<void> _redoCorners() => _run(() async {
        setState(() {
          _marks.clear();
          _step = 2;
        });
        await _moveCursor(_guessFor(0));
      });

  // ---- UI -----------------------------------------------------------------------------
  static const _titles = ['Your TV', 'Install the strip', 'Find the corners', 'Check the colors', 'All set'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_titles[_step])),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                for (var i = 0; i < _titles.length; i++)
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutCubic,
                      height: 4,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        color: i <= _step ? Colors.white : SL.border,
                      ),
                    ),
                  ),
              ]),
            ),
            AnimatedOpacity(
              opacity: _busy ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Padding(
                padding: EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 380),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, a) => FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(begin: const Offset(0.08, 0), end: Offset.zero).animate(a),
                    child: child,
                  ),
                ),
                child: ListView(
                  key: ValueKey(_step),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  children: switch (_step) {
                    0 => _sizeStep(),
                    1 => _installStep(),
                    2 => _cornerStep(),
                    3 => _verifyStep(),
                    _ => _doneStep(),
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _h(String text) => Text(text,
      style: const TextStyle(color: SL.text, fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.4));

  Widget _p(String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text, style: const TextStyle(color: SL.muted, fontSize: 15, height: 1.35)),
      );

  List<Widget> _sizeStep() {
    return [
      FadeSlideIn(child: _h('How big is your TV?')),
      FadeSlideIn(delay: const Duration(milliseconds: 60), child: _p('Measured corner to corner, as written on its box.')),
      const SizedBox(height: 12),
      FadeSlideIn(delay: const Duration(milliseconds: 120), child: TvSizePreview(inches: _inches)),
      Slider(
        value: _inches,
        min: 32,
        max: 85,
        divisions: 53,
        label: '${_inches.round()}"',
        onChanged: (v) => setState(() => _inches = v),
      ),
      const SectionLabel('LEDs per meter on your strip'),
      Wrap(spacing: 8, children: [
        for (final d in [30, 60, 144])
          ChoiceChip(
            label: Text('$d / m', style: TextStyle(color: _density == d ? Colors.black : SL.text)),
            selected: _density == d,
            showCheckmark: false,
            onSelected: (_) => setState(() => _density = d),
          ),
      ]),
      _p('Printed on the strip or its box. SyncLight kits use 60.'),
      const SizedBox(height: 28),
      FilledButton(onPressed: _busy ? null : _toInstall, child: const Text('Next')),
    ];
  }

  List<Widget> _installStep() {
    final s = _suggest ?? const {};
    final need = ((s['total'] ?? 0) as num).toInt();
    final spare = _ledCount - need;
    return [
      FadeSlideIn(child: TvInstallAnimation(counts: _counts)),
      const SizedBox(height: 18),
      FadeSlideIn(
        delay: const Duration(milliseconds: 100),
        child: SLCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.straighten, color: SL.muted, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text('About $need LEDs  ·  ${s['strip_length_m'] ?? '?'} m of strip',
                    style: const TextStyle(color: SL.text, fontWeight: FontWeight.w600)),
              ),
            ]),
            if (_ledCount > 0 && spare > 0)
              _p('Your strip has $_ledCount LEDs, so about $spare will be left at the end. '
                  'Cut them off at a cut mark, or tuck them behind the TV — they stay off.'),
            if (_ledCount > 0 && spare < 0)
              _p('Your strip has $_ledCount LEDs, a little short. Stick it as far as it goes — '
                  'the next step adjusts to what you have.'),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      FadeSlideIn(
        delay: const Duration(milliseconds: 160),
        child: SLCard(
          child: Column(children: [
            _tip(Icons.cleaning_services_outlined, 'Wipe the back edges of the TV with a dry cloth first.'),
            _tip(Icons.power_outlined, 'When it\'s on, plug the strip into the SyncLight box.'),
          ]),
        ),
      ),
      const SizedBox(height: 24),
      FilledButton(onPressed: _busy ? null : _toCorners, child: const Text('The strip is on the TV')),
      const SizedBox(height: 4),
      TextButton(onPressed: () => setState(() => _step = 0), child: const Text('Back')),
    ];
  }

  Widget _tip(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: SL.muted, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(color: SL.text))),
        ]),
      );

  List<Widget> _cornerStep() {
    final k = _marks.length.clamp(0, _cornerPrompts.length - 1);
    final (title, help) = _cornerPrompts[k];
    final min = _marks.isEmpty ? 0 : _marks.last;
    final max = (_ledCount > 0 ? _ledCount : 1000) - 1;
    final cursor = _cursor.clamp(min, max);
    final nudgeStyle = OutlinedButton.styleFrom(minimumSize: const Size(56, 46), padding: EdgeInsets.zero);
    Widget nudge(String label, int target) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: OutlinedButton(
            style: nudgeStyle,
            onPressed: target < min || target > max ? null : () => _moveCursor(target),
            child: Text(label),
          ),
        );
    return [
      Row(children: [
        for (var i = 0; i < _cornerPrompts.length; i++)
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              height: 28,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: i < _marks.length ? Colors.white : (i == _marks.length ? SL.cardHigh : SL.card),
                border: Border.all(color: i == _marks.length ? Colors.white : SL.border),
              ),
              child: i < _marks.length
                  ? const Icon(Icons.check, size: 16, color: Colors.black)
                  : Text('${i + 1}', style: TextStyle(color: i == _marks.length ? SL.text : SL.faint, fontSize: 12)),
            ),
          ),
      ]),
      const SizedBox(height: 22),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: Column(
          key: ValueKey(k),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [_h(title), _p(help)],
        ),
      ),
      _p('Corners you already marked glow red on the strip.'),
      const SizedBox(height: 22),
      SLCard(
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 10),
        child: Column(children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
            child: Text('LED ${cursor + 1}',
                key: ValueKey(cursor),
                style: const TextStyle(color: SL.text, fontSize: 34, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 8),
          StripCursor(ledCount: _ledCount, cursor: cursor, marks: List<int>.from(_marks)),
          if (max > min)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Slider(
                value: cursor.toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                divisions: max - min,
                onChanged: (v) => _moveCursor(v.round()),
              ),
            ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            nudge('-10', cursor - 10),
            nudge('-1', cursor - 1),
            const SizedBox(width: 10),
            nudge('+1', cursor + 1),
            nudge('+10', cursor + 10),
          ]),
        ]),
      ),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _busy ? null : _markCorner,
        icon: const Icon(Icons.check),
        label: const Text('This is the one'),
      ),
      if (_marks.isNotEmpty)
        TextButton.icon(onPressed: _undoCorner, icon: const Icon(Icons.undo), label: const Text('Undo last corner')),
      const Divider(height: 36),
      TextButton(
        onPressed: _busy ? null : _useMeasured,
        child: const Text('Skip — use the measured numbers instead'),
      ),
    ];
  }

  List<Widget> _verifyStep() {
    Widget row(String side, String label) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: sideColors[side],
                boxShadow: [BoxShadow(color: sideColors[side]!.withAlpha(140), blurRadius: 10)],
              ),
            ),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(color: SL.text, fontSize: 15)),
          ]),
        );
    return [
      FadeSlideIn(child: _h('Look at the TV from the front')),
      FadeSlideIn(delay: const Duration(milliseconds: 60), child: _p('Each edge should glow its own color, like this:')),
      const SizedBox(height: 14),
      const FadeSlideIn(delay: Duration(milliseconds: 120), child: TvSidesPreview()),
      const SizedBox(height: 14),
      FadeSlideIn(
        delay: const Duration(milliseconds: 180),
        child: SLCard(
          child: Column(children: [
            row('left', 'Left edge — red'),
            row('top', 'Top edge — green'),
            row('right', 'Right edge — blue'),
            row('bottom', 'Bottom edge — yellow'),
          ]),
        ),
      ),
      _p('A color spilling around a corner means a corner is off by a few LEDs.'),
      const SizedBox(height: 24),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Looks right — save')),
      const SizedBox(height: 4),
      TextButton(onPressed: _busy ? null : _redoCorners, child: const Text('Something is off — redo the corners')),
    ];
  }

  List<Widget> _doneStep() {
    return [
      const SizedBox(height: 30),
      const FadeSlideIn(
        child: Center(child: RgbRing(size: 170, thickness: 7, seconds: 3, child: Icon(Icons.check_rounded, size: 70, color: SL.text))),
      ),
      const SizedBox(height: 20),
      FadeSlideIn(
        delay: const Duration(milliseconds: 150),
        child: Text('Your TV is set up!', textAlign: TextAlign.center,
            style: const TextStyle(color: SL.text, fontSize: 26, fontWeight: FontWeight.w700)),
      ),
      FadeSlideIn(
        delay: const Duration(milliseconds: 250),
        child: Text('Play something on the TV and the light will follow the picture.',
            textAlign: TextAlign.center, style: const TextStyle(color: SL.muted, fontSize: 15)),
      ),
      const SizedBox(height: 36),
      FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      const MadeBy(),
    ];
  }
}
