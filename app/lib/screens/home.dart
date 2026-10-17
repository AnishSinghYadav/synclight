import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/color_picker.dart';
import 'connect.dart';
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

  Future<void> _refresh() async {
    try {
      final s = await api.call('system.status');
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _status;
    final hyp = (s?['hyperion'] as Map?) ?? {};
    final wled = (s?['wled'] as Map?) ?? {};
    final layout = s?['layout'];

    return Scaffold(
      appBar: AppBar(
        title: Text(s?['name'] == null ? 'SyncLight' : 'SyncLight · ${s!['name']}'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
          IconButton(onPressed: _switchBox, icon: const Icon(Icons.swap_horiz), tooltip: 'Other box'),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: ListTile(
                  leading: Icon(Icons.wifi_off, color: theme.colorScheme.onErrorContainer),
                  title: Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                ),
              ),
            if (s != null && layout == null)
              Card(
                color: theme.colorScheme.primaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.tv),
                  title: const Text('Set up your TV'),
                  subtitle: const Text('Tell SyncLight where the strip is so the colors match the screen.'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openSetup,
                ),
              ),
            // Power + brightness
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Lights', style: theme.textTheme.titleMedium),
                      subtitle: Text(_power ? 'On' : 'Off'),
                      value: _power,
                      onChanged: (v) {
                        setState(() => _power = v);
                        _send('light.power', {'on': v});
                      },
                    ),
                    Row(
                      children: [
                        const Icon(Icons.brightness_low),
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
                        const Icon(Icons.brightness_high),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Mode
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Mode', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'sync', icon: Icon(Icons.tv), label: Text('TV sync')),
                        ButtonSegment(value: 'color', icon: Icon(Icons.palette), label: Text('Color')),
                        ButtonSegment(value: 'effect', icon: Icon(Icons.auto_awesome), label: Text('Effect')),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (v) => _setMode(v.first),
                    ),
                    const SizedBox(height: 16),
                    if (_mode == 'sync')
                      Text(
                        hyp['capture_active'] == true
                            ? 'The strip follows the picture on your TV.'
                            : 'Waiting for a picture from the HDMI capture.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    if (_mode == 'color')
                      ColorPicker(
                        color: _color,
                        onChanged: (c) {
                          setState(() => _color = c);
                          _send('light.mode', {'mode': 'color', 'color': c});
                        },
                      ),
                    if (_mode == 'effect')
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (_effects.isEmpty) const Text('Loading effects…'),
                          for (final e in _effects)
                            ChoiceChip(
                              label: Text(e),
                              selected: e == _effect,
                              onSelected: (_) {
                                setState(() => _effect = e);
                                _send('light.mode', {'mode': 'effect', 'effect': e});
                              },
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Status
            Card(
              child: Column(
                children: [
                  _statusRow(Icons.memory, 'Light engine', hyp['reachable'] == true,
                      hyp['reachable'] == true ? 'Running' : 'Not responding'),
                  _statusRow(Icons.lightbulb, 'LED controller', wled['reachable'] == true,
                      wled['reachable'] == true ? '${wled['led_count'] ?? '?'} LEDs' : 'Not responding'),
                  _statusRow(Icons.settings_input_hdmi, 'HDMI picture', hyp['capture_active'] == true,
                      hyp['capture_active'] == true ? 'Receiving' : 'No signal'),
                  _statusRow(Icons.tv, 'TV setup', layout != null,
                      layout != null ? '${(layout as Map)['total']} LEDs placed' : 'Not done yet'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openSetup,
              icon: const Icon(Icons.straighten),
              label: Text(layout == null ? 'Set up TV' : 'Redo TV setup'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusRow(IconData icon, String title, bool ok, String detail) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(detail),
      trailing: Icon(ok ? Icons.check_circle : Icons.error_outline, color: ok ? Colors.green : scheme.error),
    );
  }
}
