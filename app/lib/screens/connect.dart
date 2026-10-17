import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import '../api.dart';
import '../ble_api.dart';
import '../discovery.dart';
import 'home.dart';

const _kindKey = 'box_kind'; // 'ble' or 'http'
const _idKey = 'box_id'; // Bluetooth device id or host
const _nameKey = 'box_name';

/// Finds the box (Bluetooth first, Wi-Fi for development) and opens the dashboard.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.autoConnect = true});

  final bool autoConnect;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _scanner = BleScanner();
  final _wifi = BoxDiscovery();
  final _manual = TextEditingController();

  List<BleDevice> _bleFound = [];
  List<FoundBox> _wifiFound = [];
  String? _connecting;
  String? _error;
  String? _bleProblem;
  bool _scanning = false;
  bool _showWifi = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    String? kind, id, name;
    try {
      final prefs = await SharedPreferences.getInstance();
      kind = prefs.getString(_kindKey);
      id = prefs.getString(_idKey);
      name = prefs.getString(_nameKey);
    } catch (_) {
      // Remembering the box is a convenience; never block connecting on it.
    }
    if (kind == 'http' && id != null) _manual.text = id;
    if (widget.autoConnect && kind != null && id != null) {
      final ok = kind == 'ble'
          ? await _connectBle(id, name ?? 'SyncLight', quiet: true)
          : await _connectHttp(id, quiet: true);
      if (ok) return;
    }
    await _startBleScan();
  }

  Future<void> _startBleScan() async {
    final problem = await prepareBluetooth();
    if (!mounted) return;
    setState(() => _bleProblem = problem);
    if (problem != null) return;
    setState(() {
      _scanning = true;
      _bleFound = [];
    });
    try {
      await _scanner.start((devices) {
        if (mounted) setState(() => _bleFound = devices);
      });
    } catch (e) {
      if (mounted) setState(() => _bleProblem = 'Could not start the Bluetooth search.');
    }
    Future.delayed(const Duration(seconds: 20), () async {
      await _scanner.stop();
      if (mounted) setState(() => _scanning = false);
    });
  }

  Future<void> _startWifiSearch() async {
    setState(() => _showWifi = true);
    try {
      await _wifi.start((boxes) {
        if (mounted) setState(() => _wifiFound = boxes);
      });
    } catch (_) {}
  }

  Future<void> _remember(String kind, String id, String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kindKey, kind);
      await prefs.setString(_idKey, id);
      await prefs.setString(_nameKey, name);
    } catch (_) {
      // Not fatal: the app just won't reconnect automatically next time.
    }
  }

  void _openHome(BoxApi api) {
    _scanner.stop();
    _wifi.stop();
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => HomeScreen(api: api)));
  }

  Future<bool> _connectBle(String id, String name, {bool quiet = false}) async {
    setState(() {
      _connecting = name;
      _error = null;
    });
    await _scanner.stop();
    final api = BleBoxApi(id, name);
    try {
      await api.connect();
      try {
        await api.call('system.ping', const {}, const Duration(seconds: 6));
      } on BoxError catch (e) {
        throw BoxError(e.code, 'Connected, but the first message got no reply (${e.message})');
      }
      await _remember('ble', id, name);
      if (mounted) _openHome(api);
      return true;
    } catch (e) {
      api.close();
      if (mounted) {
        setState(() {
          _connecting = null;
          if (!quiet) _error = 'Could not connect to $name. Move closer to the box and try again.\n\nDetails: $e';
        });
      }
      return false;
    }
  }

  Future<bool> _connectHttp(String host, {bool quiet = false}) async {
    host = host.trim();
    if (host.isEmpty) return false;
    setState(() {
      _connecting = host;
      _error = null;
    });
    final api = HttpBoxApi(host);
    try {
      await api.call('system.ping', const {}, const Duration(seconds: 4));
      await _remember('http', host, host);
      if (mounted) _openHome(api);
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
    _scanner.stop();
    _wifi.stop();
    _manual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _connecting != null;
    return Scaffold(
      appBar: AppBar(title: const Text('SyncLight')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Icon(Icons.tv_rounded, size: 72, color: theme.colorScheme.primary),
          const SizedBox(height: 12),
          Text('Connect to your SyncLight box', textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text('Plug in the box and keep your phone near the TV.',
              textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 24),
          if (busy)
            Card(
              child: ListTile(
                leading: const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
                title: Text('Connecting to $_connecting…'),
              ),
            ),
          if (_error != null) _errorCard(theme, _error!),
          Row(children: [
            Expanded(child: Text('Nearby boxes', style: theme.textTheme.titleSmall)),
            if (!_scanning && _bleProblem == null)
              TextButton.icon(onPressed: busy ? null : _startBleScan, icon: const Icon(Icons.refresh), label: const Text('Search again')),
          ]),
          const SizedBox(height: 4),
          if (_bleProblem != null) ...[
            _errorCard(theme, _bleProblem!),
            TextButton(onPressed: _startBleScan, child: const Text('Try again')),
          ] else if (_bleFound.isEmpty)
            ListTile(
              leading: _scanning
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3))
                  : const Icon(Icons.bluetooth_disabled),
              title: Text(_scanning ? 'Looking for SyncLight boxes…' : 'No box found'),
              subtitle: _scanning ? null : const Text('Is the box plugged in? Give it a minute after powering on.'),
            ),
          for (final d in _bleFound)
            Card(
              child: ListTile(
                leading: const Icon(Icons.bluetooth),
                title: Text(prettyBoxName(d.name)),
                subtitle: Text(d.rssi == null ? 'Nearby' : _signal(d.rssi!)),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy ? null : () => _connectBle(d.deviceId, prettyBoxName(d.name)),
              ),
            ),
          const SizedBox(height: 24),
          ExpansionTile(
            title: const Text('Connect over Wi-Fi (developer)'),
            tilePadding: EdgeInsets.zero,
            onExpansionChanged: (open) {
              if (open && !_showWifi) _startWifiSearch();
            },
            children: [
              for (final box in _wifiFound)
                ListTile(
                  leading: const Icon(Icons.wifi),
                  title: Text(box.name),
                  subtitle: Text(box.host),
                  onTap: busy ? null : () => _connectHttp(box.host),
                ),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _manual,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'e.g. 192.168.1.70'),
                    onSubmitted: (v) => _connectHttp(v),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: busy ? null : () => _connectHttp(_manual.text), child: const Text('Connect')),
              ]),
              const SizedBox(height: 8),
            ],
          ),
        ],
      ),
    );
  }

  String _signal(int rssi) => rssi > -60 ? 'Very close' : rssi > -75 ? 'Nearby' : 'Far — move closer';

  Widget _errorCard(ThemeData theme, String text) => Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(text, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
        ),
      );
}
