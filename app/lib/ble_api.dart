import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'api.dart';
import 'framing.dart';

const bleServiceUuid = '5f1e0001-8a3c-4b6e-9d2a-53796e634c74';
const bleRequestUuid = '5f1e0002-8a3c-4b6e-9d2a-53796e634c74';
const bleResponseUuid = '5f1e0003-8a3c-4b6e-9d2a-53796e634c74';

/// "SL-AB12" (advertised) or "SyncLight-AB12" (device name) -> "SyncLight AB12".
String prettyBoxName(String? raw) {
  if (raw == null || raw.isEmpty) return 'SyncLight';
  final m = RegExp(r'^(?:SL|SyncLight)-([0-9A-Fa-f]{4})$').firstMatch(raw);
  return m == null ? raw : 'SyncLight ${m.group(1)!.toUpperCase()}';
}

/// Talks to the box over Bluetooth LE with the same JSON messages as HTTP.
class BleBoxApi implements BoxApi {
  BleBoxApi(this.deviceId, this.name);

  final String deviceId;
  final String name;

  int _mtu = 23;
  int _id = 0;
  bool _connected = false;
  final _reassembler = Reassembler();
  final Map<int, Completer<dynamic>> _pending = {};
  StreamSubscription<Uint8List>? _valueSub;
  StreamSubscription<bool>? _connectionSub;
  Future<void> _queue = Future.value();

  @override
  String get label => name;

  Future<void> connect() async {
    await UniversalBle.connect(deviceId, timeout: const Duration(seconds: 15));
    _connected = true;
    _connectionSub ??= UniversalBle.connectionStream(deviceId).listen((connected) {
      _connected = connected;
      if (!connected) {
        _reassembler.reset();
        _failAll(BoxError('offline', 'Bluetooth connection lost.'));
      }
    });
    await UniversalBle.discoverServices(deviceId);
    try {
      _mtu = await UniversalBle.requestMtu(deviceId, 247);
    } catch (_) {
      _mtu = 23;
    }
    _valueSub ??= UniversalBle.characteristicValueStream(deviceId, bleResponseUuid).listen(_onChunk);
    await UniversalBle.subscribeNotifications(deviceId, bleServiceUuid, bleResponseUuid);
  }

  void _onChunk(Uint8List chunk) {
    final message = _reassembler.feed(chunk);
    if (message == null) return;
    try {
      final body = jsonDecode(utf8.decode(message));
      final id = body is Map ? body['id'] : null;
      final completer = id is int ? _pending.remove(id) : null;
      if (completer != null && !completer.isCompleted) completer.complete(body);
    } catch (_) {
      // Ignore garbled messages; the caller will time out.
    }
  }

  void _failAll(BoxError error) {
    final waiting = _pending.values.toList();
    _pending.clear();
    for (final c in waiting) {
      if (!c.isCompleted) c.completeError(error);
    }
  }

  /// Requests go out one at a time, so chunks of different messages never interleave.
  @override
  Future<Map<String, dynamic>> call(
    String cmd, [
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 8),
  ]) {
    final result = _queue.then((_) => _send(cmd, args, timeout));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, dynamic>> _send(String cmd, Map<String, dynamic> args, Duration timeout) async {
    if (!_connected) {
      try {
        await connect();
      } catch (_) {
        throw BoxError('offline', 'Cannot reach the box over Bluetooth.');
      }
    }
    final id = ++_id;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    final payload = Uint8List.fromList(utf8.encode(jsonEncode({'id': id, 'cmd': cmd, 'args': args})));
    try {
      for (final chunk in splitFrames(payload, chunkPayloadForMtu(_mtu))) {
        await UniversalBle.write(deviceId, bleServiceUuid, bleRequestUuid, chunk);
      }
    } catch (_) {
      _pending.remove(id);
      _connected = false;
      throw BoxError('offline', 'Sending to the box over Bluetooth failed.');
    }

    final dynamic body;
    try {
      body = await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      throw BoxError('timeout', 'The box did not answer in time.');
    }
    if (body is Map && body['ok'] == true) {
      final data = body['data'];
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    }
    throw errorFromReply(body);
  }

  @override
  void close() {
    _valueSub?.cancel();
    _connectionSub?.cancel();
    _failAll(BoxError('offline', 'Disconnected.'));
    UniversalBle.disconnect(deviceId).catchError((_) {});
  }
}

/// Ask for Bluetooth permissions and switch Bluetooth on if needed.
/// Returns null when ready, or a message to show the user.
Future<String?> prepareBluetooth() async {
  try {
    await UniversalBle.requestPermissions();
  } catch (_) {
    return 'SyncLight needs the "Nearby devices" permission to find your box.';
  }
  var state = await UniversalBle.getBluetoothAvailabilityState();
  if (state == AvailabilityState.poweredOff) {
    try {
      await UniversalBle.enableBluetooth();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 800));
    state = await UniversalBle.getBluetoothAvailabilityState();
  }
  switch (state) {
    case AvailabilityState.poweredOn:
      return null;
    case AvailabilityState.poweredOff:
      return 'Turn on Bluetooth to find your SyncLight box.';
    case AvailabilityState.unauthorized:
      return 'Allow the "Nearby devices" permission for SyncLight in Settings.';
    case AvailabilityState.unsupported:
      return 'This phone does not support Bluetooth LE.';
    default:
      return null;
  }
}

/// Scans for boxes advertising the SyncLight service.
class BleScanner {
  StreamSubscription<BleDevice>? _sub;
  final Map<String, BleDevice> _found = {};

  Future<void> start(void Function(List<BleDevice>) onChange) async {
    _found.clear();
    _sub = UniversalBle.scanStream.listen((device) {
      _found[device.deviceId] = device;
      onChange(_found.values.toList());
    });
    await UniversalBle.startScan(
      scanFilter: ScanFilter(withServices: [bleServiceUuid]),
      platformConfig: PlatformConfig(
        android: AndroidOptions(legacy: true, requestLocationPermission: false),
      ),
    );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
  }
}
