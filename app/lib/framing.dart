import 'dart:math';
import 'dart:typed_data';

/// Chunk framing for messages over Bluetooth (PROTOCOL.md section 3).
/// Header byte: bit 7 = more chunks follow, bits 0-6 = sequence number from 0.
const int _more = 0x80;

List<Uint8List> splitFrames(Uint8List data, int chunkPayload) {
  final size = max(1, chunkPayload);
  final out = <Uint8List>[];
  final count = max(1, (data.length + size - 1) ~/ size);
  for (var i = 0; i < count; i++) {
    final start = i * size;
    final end = min(start + size, data.length);
    final chunk = Uint8List(1 + max(0, end - start));
    chunk[0] = (i & 0x7F) | (i < count - 1 ? _more : 0);
    if (end > start) chunk.setRange(1, chunk.length, data, start);
    out.add(chunk);
  }
  return out;
}

int chunkPayloadForMtu(int mtu) => max(1, min(mtu - 3, 512) - 1);

class Reassembler {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  int _expect = 0;

  void reset() {
    _buf.clear();
    _expect = 0;
  }

  /// Returns the complete message, or null while more chunks are expected.
  Uint8List? feed(Uint8List chunk) {
    if (chunk.isEmpty) return null;
    final header = chunk[0];
    final seq = header & 0x7F;
    if (seq != _expect) {
      reset();
      if (seq != 0) return null; // out of order: drop this message
    }
    _buf.add(chunk.sublist(1));
    _expect = (_expect + 1) & 0x7F;
    if ((header & _more) != 0) return null;
    final message = _buf.takeBytes();
    _expect = 0;
    return message;
  }
}
