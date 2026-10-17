import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../theme.dart';
import '../widgets/color_picker.dart';
import '../widgets/fx.dart';
import 'connect.dart';
import 'network.dart';
import 'setup.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api});

  final BoxApi api;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic>? _status;
  String? _error;
  Timer? _poll;
  List<String> _effects = [];

  // Local copy of the light state so the UI reacts instantly.
  bool _power = true;
  double _brightness = 80;
  bool _dragging = false;
  String _mode = 'sync';
  List<int> _color = [255, 170, 90];
  String? _effect;

  BoxApi get api => widget.api;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadEffects();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) return; // never pile up requests
    _refreshing = true;
    try {
      final s = await api.call('system.status', const {}, const Duration(seconds: 15));
      if (!mounted) return;
      final light = (s['light'] as Map?) ?? {};
      setState(() {
        _status = s;
        _error = null;
        _power = light['power'] != false;
        if (!_dragging) _brightness = ((light['brightness'] ?? 80) as num).toDouble();
        _mode = (light['mode'] ?? 'sync') as String;
        final c = light['color'];
        if (c is List && c.length == 3) _color = c.map((e) => (e as num).toInt()).toList();
        _effect = light['effect'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => _error = explainError(e));
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _loadEffects() async {
    try {
      final r = await api.call('light.effects');
      if (mounted) setState(() => _effects = List<String>.from(r['effects'] ?? const []));
    } catch (_) {}
  }

  Future<void> _send(String cmd, Map<String, dynamic> args) async {
    try {
      await api.call(cmd, args);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(explainError(e))));
      _refresh();
    }
  }

  void _setMode(String mode) {
    setState(() => _mode = mode);
    if (mode == 'sync') _send('light.mode', {'mode': 'sync'});
    if (mode == 'color') _send('light.mode', {'mode': 'color', 'color': _color});
    if (mode == 'effect') {
      final e = _effect ?? (_effects.contains('Rainbow swirl') ? 'Rainbow swirl' : (_effects.isNotEmpty ? _effects.first : null));
      if (e != null) {
        setState(() => _effect = e);
        _send('light.mode', {'mode': 'effect', 'effect': e});
      }
    }
  }

  void _switchBox() {
    _poll?.cancel();
    api.close();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ConnectScreen(autoConnect: false)),
    );
  }

  Future<void> _openSetup() async {
    _poll?.cancel();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SetupScreen(api: api)));
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  bool _checkingHealth = false;

  Future<void> _checkHealth() async {
    if (_checkingHealth) return;
    setState(() => _checkingHealth = true);
    try {
      final result = await api.call('system.health', const {}, const Duration(seconds: 30));
      if (!mounted) return;
      final checks = (result['checks'] as List?) ?? [];
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Connection health'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: checks.map((check) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(check['ok'] == true ? Icons.check_circle_outline : Icons.warning_amber,
                    color: check['ok'] == true ? SL.good : SL.warn),
                title: Text(check['message'] as String),
              )).toList(),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(explainError(e))));
    } finally {
      if (mounted) setState(() => _checkingHealth = false);
    }
  }

  void _openNetwork() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => NetworkScreen(api: api)));
  }

  Color get _previewColor => rgbColor(_color);

  String get _modeLabel => switch (_mode) {
        'color' => 'Solid color',
        'effect' => _effect ?? 'Effect',
        _ => 'TV sync',
      };

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final hyp = (s?['hyperion'] as Map?) ?? {};
    final wled = (s?['wled'] as Map?) ?? {};
    final layout = s?['layout'];
    final net = (s?['network'] as Map?) ?? {};

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(children: [
          const RgbRing(size: 30, thickness: 2.5, glow: false, seconds: 5),
          const SizedBox(width: 10),
          Flexible(child: Text(api.label, overflow: TextOverflow.ellipsis)),
        ]),
        actions: [
          IconButton(onPressed: _openNetwork, icon: const Icon(Icons.router_outlined), tooltip: 'Box network'),
          IconButton(onPressed: _switchBox, icon: const Icon(Icons.swap_horiz), tooltip: 'Other box'),
        ],
      ),
      body: RefreshIndicator(
        color: Colors.black,
        backgroundColor: Colors.white,
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              child: _error == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SLCard(
                        color: const Color(0xFF2A1215),
                        child: Row(children: [
                          const Icon(Icons.cloud_off, color: SL.bad),
                          const SizedBox(width: 12),
                          Expanded(child: Text(_error!, style: const TextStyle(color: Color(0xFFFFC9CB)))),
                        ]),
                      ),
                    ),
            ),
            if (s != null && layout == null)
              FadeSlideIn(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SLCard(
                    onTap: _openSetup,
                    child: Row(children: [
                      const RgbRing(size: 44, thickness: 2.5, child: Icon(Icons.tv, size: 20, color: SL.text)),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Set up your TV', style: TextStyle(color: SL.text, fontSize: 16, fontWeight: FontWeight.w600)),
                          SizedBox(height: 2),
                          Text('A 2-minute guided setup so colors match the screen.',
                              style: TextStyle(color: SL.muted, fontSize: 13)),
                        ]),
                      ),
                      const Icon(Icons.chevron_right, color: SL.faint),
                    ]),
                  ),
                ),
              ),

            // Hero: light preview + power.
            FadeSlideIn(
              child: SLCard(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
                child: Column(children: [
                  GlowOrb(
                    color: _previewColor,
                    rainbow: _mode != 'color',
                    on: _power,
                    brightness: _brightness / 100,
                    size: 130,
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      _power ? _modeLabel : 'Lights off',
                      key: ValueKey('${_power}_$_modeLabel'),
                      style: const TextStyle(color: SL.text, fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: -0.3),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _power ? 'Brightness ${_brightness.round()}%' : 'Tap the power button to turn on',
                    style: const TextStyle(color: SL.muted),
                  ),
                  const SizedBox(height: 18),
                  Row(children: [
                    _PowerButton(
                      on: _power,
                      onTap: () {
                        setState(() => _power = !_power);
                        _send('light.power', {'on': _power});
                      },
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Row(children: [
                        const Icon(Icons.brightness_low, color: SL.muted, size: 20),
                        Expanded(
                          child: Slider(
                            value: _brightness.clamp(0, 100),
                            min: 0,
                            max: 100,
                            divisions: 20,
                            label: '${_brightness.round()}%',
                            onChangeStart: (_) => _dragging = true,
                            onChanged: (v) => setState(() => _brightness = v),
                            onChangeEnd: (v) {
                              _dragging = false;
                              _send('light.brightness', {'value': v.round()});
                            },
                          ),
                        ),
                        const Icon(Icons.brightness_high, color: SL.muted, size: 20),
                      ]),
                    ),
                  ]),
                ]),
              ),
            ),

            // Mode.
            const FadeSlideIn(delay: Duration(milliseconds: 80), child: SectionLabel('Mode')),
            FadeSlideIn(
              delay: const Duration(milliseconds: 120),
              child: SLCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _ModeSwitch(value: _mode, onChanged: _setMode),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(
                          position: Tween(begin: const Offset(0, 0.05), end: Offset.zero).animate(a),
                          child: child,
                        ),
                      ),
                      child: Padding(
                        key: ValueKey(_mode),
                        padding: const EdgeInsets.only(top: 16),
                        child: _modeBody(hyp),
                      ),
                    ),
                  ),
                ]),
              ),
            ),

            // Status.
            const FadeSlideIn(delay: Duration(milliseconds: 160), child: SectionLabel('Status')),
            FadeSlideIn(
              delay: const Duration(milliseconds: 200),
              child: LayoutBuilder(builder: (context, c) {
                final w = (c.maxWidth - 10) / 2;
                return Wrap(spacing: 10, runSpacing: 10, children: [
                  _StatusTile(width: w, icon: Icons.memory, title: 'Light engine', ok: hyp['reachable'] == true,
                      detail: hyp['reachable'] == true ? 'Running' : 'Not responding'),
                  _StatusTile(width: w, icon: Icons.lightbulb_outline, title: 'LED controller', ok: wled['reachable'] == true,
                      detail: wled['reachable'] == true ? '${wled['led_count'] ?? '?'} LEDs' : 'Not reachable'),
                  _StatusTile(width: w, icon: Icons.settings_input_hdmi, title: 'HDMI', ok: hyp['capture_active'] == true,
                      detail: hyp['capture_active'] == true ? 'Receiving picture' : 'No signal'),
                  _StatusTile(
                    width: w,
                    icon: Icons.router_outlined,
                    title: 'Network',
                    ok: net['error'] == null,
                    detail: net['switching'] == true
                        ? 'Switching…'
                        : net['mode'] == 'hotspot'
                            ? 'Private Wi-Fi'
                            : 'Home Wi-Fi',
                    onTap: _openNetwork,
                  ),
                ]);
              }),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _checkingHealth ? null : _checkHealth,
              icon: const Icon(Icons.health_and_safety_outlined),
              label: Text(_checkingHealth ? 'Checking connection…' : 'Check connection'),
            ),
            const SizedBox(height: 18),
            FadeSlideIn(
              delay: const Duration(milliseconds: 240),
              child: FilledButton.icon(
                onPressed: _openSetup,
                icon: const Icon(Icons.straighten),
                label: Text(layout == null ? 'Set up TV' : 'Redo TV setup'),
              ),
            ),
            const MadeBy(),
          ],
        ),
      ),
    );
  }

  Widget _modeBody(Map hyp) {
    switch (_mode) {
      case 'color':
        return ColorPicker(
          color: _color,
          onChanged: (c) {
            setState(() => _color = c);
            _send('light.mode', {'mode': 'color', 'color': c});
          },
        );
      case 'effect':
        if (_effects.isEmpty) {
          return const Text('Loading effects…', style: TextStyle(color: SL.muted));
        }
        return Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in _effects)
            ChoiceChip(
              label: Text(e, style: TextStyle(color: e == _effect ? Colors.black : SL.text)),
              selected: e == _effect,
              showCheckmark: false,
              onSelected: (_) {
                setState(() => _effect = e);
                _send('light.mode', {'mode': 'effect', 'effect': e});
              },
            ),
        ]);
      default:
        final live = hyp['capture_active'] == true;
        return Row(children: [
          PulseDot(color: live ? SL.good : SL.warn, size: 8),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              live ? 'Following the picture on your TV.' : 'Waiting for a picture from the HDMI input.',
              style: const TextStyle(color: SL.muted),
            ),
          ),
        ]);
    }
  }
}

class _PowerButton extends StatelessWidget {
  const _PowerButton({required this.on, required this.onTap});

  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        width: 58,
        height: 58,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? Colors.white : SL.cardHigh,
          boxShadow: on ? [BoxShadow(color: Colors.white.withAlpha(60), blurRadius: 18, spreadRadius: 1)] : const [],
        ),
        child: Icon(Icons.power_settings_new, color: on ? Colors.black : SL.muted, size: 28),
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const _modes = [
    ('sync', Icons.tv, 'TV sync'),
    ('color', Icons.palette_outlined, 'Color'),
    ('effect', Icons.auto_awesome, 'Effect'),
  ];

  @override
  Widget build(BuildContext context) {
    final index = _modes.indexWhere((m) => m.$1 == value).clamp(0, 2);
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: SL.bg, borderRadius: BorderRadius.circular(14), border: Border.all(color: SL.border)),
      child: Stack(fit: StackFit.expand, children: [
        AnimatedAlign(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: Alignment(-1 + index * 1.0, 0),
          child: FractionallySizedBox(
            widthFactor: 1 / 3,
            child: Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10))),
          ),
        ),
        Row(children: [
          for (final m in _modes)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(m.$1),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 200),
                  style: TextStyle(
                    color: m.$1 == value ? Colors.black : SL.muted,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(m.$2, size: 18, color: m.$1 == value ? Colors.black : SL.muted),
                    const SizedBox(width: 6),
                    Text(m.$3),
                  ]),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.width,
    required this.icon,
    required this.title,
    required this.ok,
    required this.detail,
    this.onTap,
  });

  final double width;
  final IconData icon;
  final String title;
  final bool ok;
  final String detail;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: SLCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 20, color: SL.muted),
            const Spacer(),
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ok ? SL.good : SL.bad,
                boxShadow: [BoxShadow(color: (ok ? SL.good : SL.bad).withAlpha(120), blurRadius: 8)],
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(color: SL.text, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(detail, key: ValueKey(detail), style: const TextStyle(color: SL.muted, fontSize: 13)),
          ),
        ]),
      ),
    );
  }
}
