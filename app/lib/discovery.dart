import 'package:nsd/nsd.dart' as nsd;

class FoundBox {
  FoundBox(this.name, this.host, this.port);

  final String name;
  final String host;
  final int port;
}

/// Finds SyncLight boxes on the Wi-Fi via mDNS (_synclight._tcp).
class BoxDiscovery {
  nsd.Discovery? _discovery;

  Future<void> start(void Function(List<FoundBox>) onChange) async {
    final discovery = await nsd.startDiscovery(
      '_synclight._tcp',
      ipLookupType: nsd.IpLookupType.v4,
    );
    _discovery = discovery;
    discovery.addListener(() {
      final boxes = <FoundBox>[];
      for (final s in discovery.services) {
        final addresses = s.addresses;
        final host = (addresses != null && addresses.isNotEmpty) ? addresses.first.address : s.host;
        if (host == null) continue;
        boxes.add(FoundBox(s.name ?? 'SyncLight', host, s.port ?? 8484));
      }
      onChange(boxes);
    });
  }

  Future<void> stop() async {
    final d = _discovery;
    _discovery = null;
    if (d != null) {
      try {
        await nsd.stopDiscovery(d);
      } catch (_) {}
    }
  }
}
