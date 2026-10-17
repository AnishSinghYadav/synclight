"""Chunk framing for protocol messages over BLE (see PROTOCOL.md section 3).

Each chunk = 1 header byte + payload.
Header bit 7 (0x80): more chunks follow. Bits 0-6: sequence number, starting at 0 per message.
"""

MORE = 0x80
MAX_MESSAGE = 64 * 1024


class FramingError(ValueError):
    pass


def split(data, chunk_payload):
    """Split a message into framed chunks of at most chunk_payload bytes of payload."""
    chunk_payload = max(1, int(chunk_payload))
    parts = [data[i:i + chunk_payload] for i in range(0, len(data), chunk_payload)] or [b""]
    last = len(parts) - 1
    return [bytes([(i & 0x7F) | (MORE if i < last else 0)]) + part for i, part in enumerate(parts)]


class Reassembler:
    def __init__(self):
        self._buf = bytearray()
        self._expect = 0

    def reset(self):
        self._buf = bytearray()
        self._expect = 0

    def feed(self, chunk):
        """Add one chunk. Returns the complete message (bytes) or None if more is expected."""
        if not chunk:
            return None
        header = chunk[0]
        seq = header & 0x7F
        if seq != self._expect:
            if seq == 0:
                self.reset()  # a new message replaces an abandoned one
            else:
                self.reset()
                raise FramingError(f"chunk {seq} out of order (expected {self._expect})")
        # seq == expect here, including the wrap from 127 back to 0 inside a long message.
        self._buf += chunk[1:]
        if len(self._buf) > MAX_MESSAGE:
            self.reset()
            raise FramingError("message too large")
        self._expect = (self._expect + 1) & 0x7F
        if header & MORE:
            return None
        message = bytes(self._buf)
        self.reset()
        return message


def chunk_payload_for_mtu(mtu):
    """Payload bytes per chunk for a negotiated ATT MTU (3 bytes ATT header, 1 byte ours, max value 512)."""
    return max(1, min(int(mtu) - 3, 512) - 1)
