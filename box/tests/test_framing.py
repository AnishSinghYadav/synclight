import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "agent"))

from synclight_agent.ble_framing import FramingError, Reassembler, chunk_payload_for_mtu, split  # noqa: E402


class FramingTests(unittest.TestCase):
    def test_roundtrip_sizes(self):
        for size in (0, 1, 19, 20, 21, 500, 5000):
            data = bytes(i % 251 for i in range(size))
            for payload in (19, 180, 508):
                chunks = split(data, payload)
                self.assertTrue(all(len(c) <= payload + 1 for c in chunks))
                r = Reassembler()
                out = [r.feed(c) for c in chunks]
                self.assertTrue(all(o is None for o in out[:-1]))
                self.assertEqual(out[-1], data)

    def test_headers(self):
        chunks = split(b"abcdef", 2)
        self.assertEqual([c[0] for c in chunks], [0x80, 0x81, 0x02])

    def test_restart_and_out_of_order(self):
        r = Reassembler()
        a = split(b"first message", 4)
        b = split(b"second", 4)
        r.feed(a[0])
        self.assertEqual([r.feed(c) for c in b][-1], b"second")  # seq 0 restarts
        with self.assertRaises(FramingError):
            r.feed(a[2])

    def test_mtu(self):
        self.assertEqual(chunk_payload_for_mtu(23), 19)
        self.assertEqual(chunk_payload_for_mtu(247), 243)
        self.assertEqual(chunk_payload_for_mtu(517), 511)


if __name__ == "__main__":
    unittest.main()
