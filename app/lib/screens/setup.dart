import 'package:flutter/material.dart';

import '../api.dart';
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
  @override
  Widget build(BuildContext context) {
    final titles = ['Your TV', 'Install the strip', 'Find the corners', 'Check the colors', 'All set'];
    return Scaffold(
      appBar: AppBar(title: Text(titles[_step])),
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(value: (_step + 1) / titles.length),
            if (_busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: switch (_step) {
                  0 => _sizeStep(context),
                  1 => _installStep(context),
                  2 => _cornerStep(context),
                  3 => _verifyStep(context),
                  _ => _doneStep(context),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _sizeStep(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return [
      Text('How big is your TV?', style: t.titleLarge),
      const SizedBox(height: 4),
      Text('Measured corner to corner, as on the box.', style: t.bodyMedium),
      const SizedBox(height: 16),
      Center(child: Text('${_inches.round()}"', style: t.displayMedium)),
      Slider(
        value: _inches,
        min: 32,
        max: 85,
        divisions: 53,
        label: '${_inches.round()}"',
        onChanged: (v) => setState(() => _inches = v),
      ),
      const SizedBox(height: 16),
      Text('LEDs per meter on your strip', style: t.titleMedium),
      const SizedBox(height: 4),
      Text('Printed on the strip or its box. SyncLight kits use 60.', style: t.bodySmall),
      const SizedBox(height: 8),
      Wrap(spacing: 8, children: [
        for (final d in [30, 60, 144])
          ChoiceChip(label: Text('$d / m'), selected: _density == d, onSelected: (_) => setState(() => _density = d)),
      ]),
      const SizedBox(height: 32),
      FilledButton(onPressed: _busy ? null : _toInstall, child: const Text('Next')),
    ];
  }

  List<Widget> _installStep(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = _suggest ?? const {};
    final need = ((s['total'] ?? 0) as num).toInt();
    final lengths = (s['side_length_cm'] as Map?) ?? const {};
    final spare = _ledCount - need;
    return [
      TvBackDiagram(counts: _counts),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Your TV needs about $need LEDs (${s['strip_length_m'] ?? '?'} m of strip).', style: t.titleSmall),
            const SizedBox(height: 6),
            if (_ledCount > 0 && spare > 0)
              Text('Your strip has $_ledCount LEDs, so about $spare will be left over at the end. '
                  'Cut them off at a cut mark, or tuck them behind the TV — they stay off.'),
            if (_ledCount > 0 && spare < 0)
              Text('Your strip has $_ledCount LEDs, a little short. Stick it as far as it goes — '
                  'the next step adjusts to what you have.'),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      _instruction(1, 'Wipe the back edges of the TV with a dry cloth.'),
      _instruction(2, 'Stand BEHIND the TV. Start at the corner marked START — the bottom-right corner from behind '
          '(bottom-left when you face the screen) — about ${s['inset_cm'] ?? 3} cm in from the edge, with the wire end there.'),
      _instruction(3, 'Go up that side (about ${lengths['left_right'] ?? '?'} cm), across the top '
          '(about ${lengths['top_bottom'] ?? '?'} cm), down the other side and along the bottom, following the arrows.'),
      _instruction(4, 'At corners, curve the strip gently. Never fold it flat — that breaks it.'),
      _instruction(5, 'Plug the strip into the SyncLight box and make sure it has power.'),
      const SizedBox(height: 24),
      FilledButton(onPressed: _busy ? null : _toCorners, child: const Text('The strip is on the TV')),
      TextButton(onPressed: () => setState(() => _step = 0), child: const Text('Back')),
    ];
  }

  Widget _instruction(int n, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(radius: 13, child: Text('$n', style: const TextStyle(fontSize: 13))),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ]),
      );

  List<Widget> _cornerStep(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final k = _marks.length.clamp(0, _cornerPrompts.length - 1);
    final (title, help) = _cornerPrompts[k];
    final min = _marks.isEmpty ? 0 : _marks.last;
    final max = (_ledCount > 0 ? _ledCount : 1000) - 1;
    final cursor = _cursor.clamp(min, max);
    return [
      Row(children: [
        for (var i = 0; i < _cornerPrompts.length; i++)
          Expanded(
            child: Container(
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: i < _marks.length
                    ? Theme.of(context).colorScheme.primary
                    : i == _marks.length
                        ? Theme.of(context).colorScheme.primary.withAlpha(110)
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
      ]),
      const SizedBox(height: 20),
      Text('Step ${k + 1} of ${_cornerPrompts.length}: $title', style: t.titleLarge),
      const SizedBox(height: 8),
      Text(help),
      const SizedBox(height: 6),
      Text('Corners you already marked glow red.', style: t.bodySmall),
      const SizedBox(height: 24),
      Center(child: Text('LED ${cursor + 1}', style: t.displaySmall)),
      if (max > min)
        Slider(
          value: cursor.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          onChanged: (v) => _moveCursor(v.round()),
        ),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        _nudge('-10', cursor - 10, min, max),
        _nudge('-1', cursor - 1, min, max),
        const SizedBox(width: 12),
        _nudge('+1', cursor + 1, min, max),
        _nudge('+10', cursor + 10, min, max),
      ]),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: _busy ? null : _markCorner,
        icon: const Icon(Icons.check),
        label: const Text('This is the one'),
      ),
      if (_marks.isNotEmpty)
        TextButton.icon(onPressed: _undoCorner, icon: const Icon(Icons.undo), label: const Text('Undo last corner')),
      const Divider(height: 40),
      TextButton(
        onPressed: _busy ? null : _useMeasured,
        child: const Text('Skip — use the measured numbers instead'),
      ),
    ];
  }

  Widget _nudge(String label, int target, int min, int max) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: OutlinedButton(
          onPressed: target < min || target > max ? null : () => _moveCursor(target),
          child: Text(label),
        ),
      );

  List<Widget> _verifyStep(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget row(String side, String label) => ListTile(
          leading: CircleAvatar(backgroundColor: sideColors[side]),
          title: Text(label),
        );
    return [
      Text('Look at the strip from the front of the TV.', style: t.titleLarge),
      const SizedBox(height: 8),
      const Text('Each edge should glow its own color:'),
      const SizedBox(height: 8),
      row('left', 'Left edge — red'),
      row('top', 'Top edge — green'),
      row('right', 'Right edge — blue'),
      row('bottom', 'Bottom edge — yellow'),
      const SizedBox(height: 8),
      const Text('A color spilling around a corner means a corner is off by a few LEDs.'),
      const SizedBox(height: 24),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Looks right — save')),
      TextButton(onPressed: _busy ? null : _redoCorners, child: const Text('Something is off — redo the corners')),
    ];
  }

  List<Widget> _doneStep(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return [
      const SizedBox(height: 24),
      Icon(Icons.check_circle, size: 96, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 16),
      Text('Your TV is set up!', textAlign: TextAlign.center, style: t.headlineSmall),
      const SizedBox(height: 8),
      const Text('Play something on the TV and the light will follow the picture.', textAlign: TextAlign.center),
      const SizedBox(height: 32),
      FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
    ];
  }
}
