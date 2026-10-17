import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';

/// Which Wi-Fi the box uses: its own private network (normal) or home Wi-Fi (developer).
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key, required this.api});

  final BoxApi api;

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  Map<String, dynamic>? _st;
  String? _error;
  bool _busy = false;
  bool _showPassword = false;
  Timer? _poll;

  BoxApi get api => widget.api;
  bool get _overWifi => api is HttpBoxApi;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final st = await api.call('net.status');
      if (mounted) setState(() {
        _st = st;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = explainError(e));
    }
  }

  Future<bool> _confirm(String title, String body) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Switch')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _switch(String cmd, String title, String body) async {
    if (!await _confirm(title, body)) return;
    setState(() => _busy = true);
    try {
      final r = await api.call(cmd, const {}, const Duration(seconds: 20));
      if (!mounted) return;
      final moved = r['led_controller_moved'];
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(moved == false
            ? 'Switching. The LED controller could not be reached, so it was not moved.'
            : 'Switching… this takes about 30 seconds.'),
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(explainError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final st = _st;
    final mode = st?['mode'] as String?;
    final switching = st?['switching'] == true;
    final wifiWarning = _overWifi
        ? '\n\nYou are connected over Wi-Fi, so the app will lose the box. Reconnect over Bluetooth afterwards.'
        : '';

    return Scaffold(
      appBar: AppBar(title: const Text('Box network')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: ListTile(title: Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer))),
              ),
            if (st == null && _error == null) const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())),
            if (st != null) ...[
              Card(
                child: ListTile(
                  leading: Icon(
                    switching ? Icons.sync : mode == 'hotspot' ? Icons.lock : Icons.wifi,
                    size: 32,
                  ),
                  title: Text(switching
                      ? 'Switching networks…'
                      : mode == 'hotspot'
                          ? 'Private Wi-Fi'
                          : mode == 'home'
                              ? 'Home Wi-Fi'
                              : 'Not connected to Wi-Fi'),
                  subtitle: Text(switching
                      ? 'This takes about 30 seconds.'
                      : mode == 'hotspot'
                          ? 'The box and LED controller talk on their own network "${st['hotspot_ssid']}". Your home Wi-Fi is not used.'
                          : 'Box is on "${st['home_ssid'] ?? st['home_connection'] ?? '?'}". Normal for development.'),
                ),
              ),
              if (st['error'] != null)
                Card(
                  color: theme.colorScheme.errorContainer,
                  child: ListTile(
                    leading: const Icon(Icons.warning_amber),
                    title: Text('${st['error']}', style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                  ),
                ),
              const SizedBox(height: 12),
              if (mode != 'hotspot')
                FilledButton.icon(
                  onPressed: _busy || switching
                      ? null
                      : () => _switch(
                            'net.use_hotspot',
                            'Use private Wi-Fi?',
                            'The box will stop using your home Wi-Fi and start its own private network. '
                                'The LED controller moves to it too. You keep controlling the box over Bluetooth.$wifiWarning',
                          ),
                  icon: const Icon(Icons.lock),
                  label: const Text('Switch to private Wi-Fi'),
                ),
              if (mode == 'hotspot')
                OutlinedButton.icon(
                  onPressed: _busy || switching
                      ? null
                      : () => _switch(
                            'net.use_home',
                            'Back to home Wi-Fi?',
                            'For development and updates: the box and LED controller rejoin your home Wi-Fi.$wifiWarning',
                          ),
                  icon: const Icon(Icons.wifi),
                  label: const Text('Back to home Wi-Fi (developer)'),
                ),
              const SizedBox(height: 24),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Developer details'),
                children: [
                  _row('LED controller', '${st['led_controller_host'] ?? '?'}'),
                  _row('Active connection', '${st['active_connection'] ?? '-'}'),
                  if (st['hotspot_ssid'] != null) ...[
                    _row('Private Wi-Fi name', '${st['hotspot_ssid']}'),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Private Wi-Fi password'),
                      subtitle: Text(_showPassword ? '${st['hotspot_password']}' : '••••••••••••••••'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _showPassword = !_showPassword),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy),
                          onPressed: () => Clipboard.setData(ClipboardData(text: '${st['hotspot_password']}')),
                        ),
                      ]),
                    ),
                    _row('SSH while on private Wi-Fi', 'Join "${st['hotspot_ssid']}", then ssh to ${st['hotspot_ip']}'),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(String title, String value) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: SelectableText(value),
      );
}
