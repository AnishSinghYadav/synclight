import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import '../api.dart';
import '../ble_api.dart';
import '../discovery.dart';
import '../theme.dart';
import '../widgets/fx.dart';
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
    final busy = _connecting != null;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
          children: [
            FadeSlideIn(
              child: Center(
                child: RgbRing(
                  size: 168,
                  thickness: 6,
                  seconds: busy ? 2 : 7,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: busy
                        ? const Icon(Icons.bluetooth_searching, key: ValueKey('b'), size: 52, color: SL.text)
                        : const Icon(Icons.tv_rounded, key: ValueKey('t'), size: 56, color: SL.text),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const FadeSlideIn(
              delay: Duration(milliseconds: 120),
              child: Text('SyncLight',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -0.8, color: SL.text)),
            ),
            const SizedBox(height: 6),
            const FadeSlideIn(
              delay: Duration(milliseconds: 200),
              child: Text('Your TV, in full color around it.',
                  textAlign: TextAlign.center, style: TextStyle(color: SL.muted, fontSize: 15)),
            ),
            const SizedBox(height: 28),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: busy
                  ? SLCard(
                      key: const ValueKey('busy'),
                      child: Row(children: [
                        const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
                        const SizedBox(width: 14),
                        Expanded(child: Text('Connecting to $_connecting…', style: const TextStyle(color: SL.text))),
                      ]),
                    )
                  : const SizedBox.shrink(key: ValueKey('idle')),
            ),
            if (_error != null) _errorCard(_error!),
            FadeSlideIn(
              delay: const Duration(milliseconds: 280),
              child: SectionLabel(
                'Nearby boxes',
                trailing: _scanning
                    ? const PulseDot(size: 8)
                    : (_bleProblem == null
                        ? TextButton.icon(
                            onPressed: busy ? null : _startBleScan,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Search again'),
                          )
                        : null),
              ),
            ),
            if (_bleProblem != null) ...[
              _errorCard(_bleProblem!),
              TextButton(onPressed: _startBleScan, child: const Text('Try again')),
            ] else if (_bleFound.isEmpty)
              FadeSlideIn(
                delay: const Duration(milliseconds: 340),
                child: SLCard(
                  child: Row(children: [
                    Icon(_scanning ? Icons.radar : Icons.bluetooth_disabled, color: SL.muted),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_scanning ? 'Looking for SyncLight boxes…' : 'No box found',
                            style: const TextStyle(color: SL.text, fontWeight: FontWeight.w600)),
                        if (!_scanning)
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text('Is the box plugged in? Give it a minute after powering on.',
                                style: TextStyle(color: SL.muted, fontSize: 13)),
                          ),
                      ]),
                    ),
                  ]),
                ),
              ),
            for (var i = 0; i < _bleFound.length; i++)
              FadeSlideIn(
                key: ValueKey(_bleFound[i].deviceId),
                delay: Duration(milliseconds: 60 * i),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SLCard(
                    onTap: busy ? null : () => _connectBle(_bleFound[i].deviceId, prettyBoxName(_bleFound[i].name)),
                    child: Row(children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: SL.cardHigh, borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.lightbulb_outline, color: SL.text),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(prettyBoxName(_bleFound[i].name),
                              style: const TextStyle(color: SL.text, fontSize: 16, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text(_bleFound[i].rssi == null ? 'Nearby' : _signal(_bleFound[i].rssi!),
                              style: const TextStyle(color: SL.muted, fontSize: 13)),
                        ]),
                      ),
                      _SignalBars(rssi: _bleFound[i].rssi),
                      const SizedBox(width: 6),
                      const Icon(Icons.chevron_right, color: SL.faint),
                    ]),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            ExpansionTile(
              title: const Text('Connect over Wi-Fi (developer)', style: TextStyle(fontSize: 14)),
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              onExpansionChanged: (open) {
                if (open && !_showWifi) _startWifiSearch();
              },
              children: [
                for (final box in _wifiFound)
                  ListTile(
                    leading: const Icon(Icons.wifi, color: SL.muted),
                    title: Text(box.name),
                    subtitle: Text(box.host, style: const TextStyle(color: SL.muted)),
                    onTap: busy ? null : () => _connectHttp(box.host),
                  ),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _manual,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(hintText: 'e.g. 192.168.1.70'),
                      onSubmitted: (v) => _connectHttp(v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size(96, 52)),
                    onPressed: busy ? null : () => _connectHttp(_manual.text),
                    child: const Text('Connect'),
                  ),
                ]),
                const SizedBox(height: 8),
              ],
            ),
            const MadeBy(),
          ],
        ),
      ),
    );
  }

  String _signal(int rssi) => rssi > -60 ? 'Very close' : rssi > -75 ? 'Nearby' : 'Far — move closer';

  Widget _errorCard(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SLCard(
          color: const Color(0xFF2A1215),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.error_outline, color: SL.bad),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: const TextStyle(color: Color(0xFFFFC9CB)))),
          ]),
        ),
      );
}

class _SignalBars extends StatelessWidget {
  const _SignalBars({this.rssi});

  final int? rssi;

  @override
  Widget build(BuildContext context) {
    final r = rssi ?? -80;
    final level = r > -60 ? 3 : r > -75 ? 2 : 1;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 1; i <= 3; i++)
          Container(
            width: 4,
            height: 6.0 + i * 4,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              color: i <= level ? SL.text : SL.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    );
  }
}
