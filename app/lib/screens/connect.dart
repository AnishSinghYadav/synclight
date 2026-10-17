import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../discovery.dart';
import 'home.dart';

const _hostKey = 'box_host';

/// Finds the box on the Wi-Fi (or reconnects to the last one) and opens the dashboard.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.autoConnect = true});

  final bool autoConnect;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _discovery = BoxDiscovery();
  final _manual = TextEditingController();
  List<FoundBox> _found = [];
  String? _connecting;
  String? _error;
  bool _searching = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_hostKey);
    if (saved != null) _manual.text = saved;
    if (widget.autoConnect && saved != null) {
      final ok = await _connect(saved, quiet: true);
      if (ok) return;
    }
    try {
      await _discovery.start((boxes) {
        if (mounted) setState(() => _found = boxes);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Automatic search is not available on this phone. Enter the address below.');
    }
    Future.delayed(const Duration(seconds: 12), () {
      if (mounted) setState(() => _searching = false);
    });
  }

  Future<bool> _connect(String host, {bool quiet = false}) async {
    host = host.trim();
    if (host.isEmpty) return false;
    setState(() {
      _connecting = host;
      _error = null;
    });
    final api = BoxApi(host);
    try {
      await api.call('system.ping', const {}, const Duration(seconds: 4));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_hostKey, host);
      await _discovery.stop();
      if (!mounted) return true;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => HomeScreen(api: api)),
      );
      return true;
    } catch (e) {
      api.close();
      if (mounted) {
        setState(() {
          _connecting = null;
          if (!quiet) _error = explainError(e);
        });
      }
      return false;
    }
  }

  @override
  void dispose() {
    _discovery.stop();
    _manual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('SyncLight')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Icon(Icons.tv_rounded, size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text('Connect to your SyncLight box',
              textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text('Make sure the box is powered on and your phone is on the same Wi-Fi.',
              textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 24),
          if (_connecting != null)
            Card(
              child: ListTile(
                leading: const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
                title: Text('Connecting to $_connecting…'),
              ),
            ),
          if (_error != null)
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ),
          const SizedBox(height: 8),
          Text('Boxes found on your Wi-Fi', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (_found.isEmpty)
            ListTile(
              leading: _searching
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3))
                  : const Icon(Icons.search_off),
              title: Text(_searching ? 'Searching…' : 'No box found yet'),
              subtitle: _searching ? null : const Text('You can type its address below.'),
            ),
          for (final box in _found)
            Card(
              child: ListTile(
                leading: const Icon(Icons.lightbulb_outline),
                title: Text(box.name),
                subtitle: Text(box.host),
                trailing: const Icon(Icons.chevron_right),
                onTap: _connecting == null ? () => _connect(box.host) : null,
              ),
            ),
          const SizedBox(height: 24),
          Text('Or enter the address', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _manual,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'e.g. 192.168.1.70',
                  ),
                  onSubmitted: (v) => _connect(v),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _connecting == null ? () => _connect(_manual.text) : null,
                child: const Text('Connect'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
