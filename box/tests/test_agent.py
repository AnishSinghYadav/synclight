import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "agent"))
sys.path.insert(0, os.path.dirname(__file__))

from fakes import FakeHyperion, FakeWled  # noqa: E402
from synclight_agent import layout  # noqa: E402
from synclight_agent.config import StateStore, load_config  # noqa: E402
from synclight_agent.server import Dispatcher, make_http_server  # noqa: E402
from synclight_agent.service import SyncLightService  # noqa: E402


class LayoutTests(unittest.TestCase):
    def test_side_order(self):
        self.assertEqual(layout.side_order("bottom_left", "cw"), ["left", "top", "right", "bottom"])
        self.assertEqual(layout.side_order("bottom_left", "ccw"), ["bottom", "right", "top", "left"])
        self.assertEqual(layout.side_order("top_right", "cw"), ["right", "bottom", "left", "top"])
        self.assertEqual(layout.side_order("top_left", "ccw"), ["left", "bottom", "right", "top"])

    def test_bottom_left_clockwise_geometry(self):
        counts = {"left": 2, "top": 4, "right": 2, "bottom": 4}
        leds = layout.build_hyperion_leds(counts, "bottom_left", "cw")
        self.assertEqual(len(leds), 12)
        # First LED: left side, bottom half.
        self.assertEqual((leds[0]["hmin"], leds[0]["vmin"], leds[0]["vmax"]), (0.0, 0.5, 1.0))
        # Second LED: left side, top half.
        self.assertEqual((leds[1]["vmin"], leds[1]["vmax"]), (0.0, 0.5))
        # Third LED: top side, leftmost quarter.
        self.assertEqual((leds[2]["hmin"], leds[2]["hmax"], leds[2]["vmin"]), (0.0, 0.25, 0.0))
        # Seventh LED: right side, top half.
        self.assertEqual((leds[6]["hmax"], leds[6]["vmin"], leds[6]["vmax"]), (1.0, 0.0, 0.5))
        # Last LED: bottom side, leftmost quarter (travelling right -> left).
        self.assertEqual((leds[-1]["hmin"], leds[-1]["hmax"], leds[-1]["vmax"]), (0.0, 0.25, 1.0))

    def test_counterclockwise_geometry(self):
        leds = layout.build_hyperion_leds({"bottom": 4, "right": 2, "top": 4, "left": 2}, "bottom_left", "ccw")
        # bottom travelled left -> right
        self.assertEqual((leds[0]["hmin"], leds[0]["hmax"]), (0.0, 0.25))
        self.assertEqual((leds[3]["hmin"], leds[3]["hmax"]), (0.75, 1.0))
        # right travelled bottom -> top
        self.assertEqual((leds[4]["vmin"], leds[4]["vmax"]), (0.5, 1.0))
        # top travelled right -> left
        self.assertEqual((leds[6]["hmin"], leds[6]["hmax"]), (0.75, 1.0))

    def test_all_areas_valid(self):
        for corner in layout.CORNERS:
            for direction in layout.DIRECTIONS:
                leds = layout.build_hyperion_leds({"left": 37, "top": 69, "right": 37, "bottom": 69}, corner, direction, offset=3)
                self.assertEqual(len(leds), 3 + 212)
                for led in leds[3:]:
                    self.assertTrue(0 <= led["hmin"] < led["hmax"] <= 1)
                    self.assertTrue(0 <= led["vmin"] < led["vmax"] <= 1)

    def test_marks_to_counts(self):
        lay = layout.normalize({"marks": {"starts": [2, 45, 120, 163], "end": 235}}, hardware_count=236)
        self.assertEqual(lay["counts"], {"left": 43, "top": 75, "right": 43, "bottom": 73})
        self.assertEqual(lay["offset"], 2)
        self.assertEqual(lay["total"], 234)

    def test_marks_validation(self):
        with self.assertRaises(layout.LayoutError):
            layout.normalize({"marks": {"starts": [0, 50, 40, 100], "end": 200}})
        with self.assertRaises(layout.LayoutError):
            layout.normalize({"counts": {"left": 100, "top": 100, "right": 100, "bottom": 100}}, hardware_count=236)

    def test_suggest_55(self):
        s = layout.suggest(55, 60, 3)
        self.assertEqual(s["counts"], {"left": 37, "top": 69, "right": 37, "bottom": 69})
        self.assertEqual(s["total"], 212)
        self.assertAlmostEqual(s["tv"]["width_cm"], 121.8, delta=0.1)


class AgentEndToEnd(unittest.TestCase):
    def setUp(self):
        self.hyp = FakeHyperion()
        self.wled = FakeWled(236)
        self.tmp = tempfile.TemporaryDirectory()
        cfg = load_config(None)
        cfg["hyperion"].update(port=self.hyp.port, password="hyperion")
        cfg["wled"]["host"] = f"127.0.0.1:{self.wled.port}"
        cfg["state_file"] = os.path.join(self.tmp.name, "state.json")
        self.cfg = cfg
        self.service = SyncLightService(cfg, StateStore(cfg["state_file"]))
        self.http = make_http_server(Dispatcher(self.service), "127.0.0.1", 0)
        threading.Thread(target=self.http.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.http.server_address[1]}/api/v1/rpc"
        self._id = 0

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.service.hyperion.close()
        self.hyp.close()
        self.wled.close()
        self.tmp.cleanup()

    def rpc(self, cmd, **args):
        self._id += 1
        body = json.dumps({"id": self._id, "cmd": cmd, "args": args}).encode()
        req = urllib.request.Request(self.url, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            reply = json.loads(resp.read())
        self.assertEqual(reply["id"], self._id)
        return reply

    def ok(self, cmd, **args):
        reply = self.rpc(cmd, **args)
        self.assertTrue(reply["ok"], reply)
        return reply["data"]

    def test_status(self):
        st = self.ok("system.status")
        self.assertTrue(st["hyperion"]["reachable"])
        self.assertTrue(st["hyperion"]["admin"])
        self.assertTrue(st["hyperion"]["capture_active"])
        self.assertEqual(st["wled"]["led_count"], 236)

    def test_light_controls_and_persistence(self):
        self.ok("light.brightness", value=40)
        self.assertEqual(self.hyp.brightness, 40)
        self.ok("light.mode", mode="color", color=[10, 20, 30])
        self.assertEqual(self.hyp.priorities[50]["value"], [10, 20, 30])
        self.assertIn("Rainbow swirl", self.ok("light.effects")["effects"])
        self.ok("light.mode", mode="effect", effect="Rainbow swirl")
        self.assertEqual(self.hyp.priorities[50]["owner"], "Rainbow swirl")
        self.ok("light.mode", mode="sync")
        self.assertNotIn(50, self.hyp.priorities)
        self.ok("light.power", on=False)
        self.assertFalse(self.hyp.components["ALL"])
        saved = json.load(open(self.cfg["state_file"]))
        self.assertEqual(saved["light"]["brightness"], 40)
        self.assertFalse(saved["light"]["power"])

        # A fresh agent (after reboot) re-applies the saved state.
        self.hyp.brightness = 100
        self.hyp.components["ALL"] = True
        fresh = SyncLightService(self.cfg, StateStore(self.cfg["state_file"]))
        fresh.apply_saved_state()
        fresh.hyperion.close()
        self.assertEqual(self.hyp.brightness, 40)
        self.assertFalse(self.hyp.components["ALL"])

    def test_errors(self):
        self.assertEqual(self.rpc("light.brightness", value=150)["error"]["code"], "bad_request")
        self.assertEqual(self.rpc("light.mode", mode="disco")["error"]["code"], "bad_request")
        self.assertEqual(self.rpc("nope")["error"]["code"], "unknown_command")
        self.assertEqual(self.rpc("light.power", on=True, extra=1)["error"]["code"], "bad_request")
        self.assertEqual(self.rpc("calibrate.cursor", index=3)["error"]["code"], "busy")
        effect = self.rpc("light.mode", mode="effect", effect="Nope")
        self.assertFalse(effect["ok"])

    def test_calibration_and_layout(self):
        self.ok("calibrate.start")
        self.assertFalse(self.hyp.components["LEDDEVICE"])
        self.assertEqual(self.wled.lit(), {})
        self.assertEqual(self.rpc("light.mode", mode="sync")["error"]["code"], "busy")

        self.ok("calibrate.cursor", index=43, marks=[0])
        self.assertEqual(self.wled.lit(), {0: "FF0000", 43: "00FF00"})

        marks = {"starts": [0, 43, 118, 161], "end": 235}
        sides = self.ok("calibrate.sides", marks=marks)
        self.assertEqual(sides["sides"]["left"], [0, 42])
        self.assertEqual(sides["sides"]["bottom"], [161, 235])
        lit = self.wled.lit()
        self.assertEqual(len(lit), 236)
        self.assertEqual(lit[0], "FF0000")
        self.assertEqual(lit[43], "00FF00")
        self.assertEqual(lit[118], "0000FF")
        self.assertEqual(lit[235], "FFC000")

        applied = self.ok("layout.apply", marks=marks)
        self.assertEqual(applied["counts"], {"left": 43, "top": 75, "right": 43, "bottom": 75})
        self.assertEqual(len(self.hyp.settings[0]["leds"]), 236)
        self.assertEqual(self.ok("layout.get")["layout"]["total"], 236)

        self.ok("calibrate.stop")
        self.assertTrue(self.hyp.components["LEDDEVICE"])
        self.assertEqual(self.wled.posts[-1]["seg"][0]["fx"], 9)  # original WLED state restored

    def test_layout_apply_needs_admin(self):
        self.service.hyperion.password = "wrong-password"
        self.service.hyperion.close()
        reply = self.rpc("layout.apply", counts={"left": 10, "top": 20, "right": 10, "bottom": 20})
        self.assertEqual(reply["error"]["code"], "hyperion_auth")

    def test_layout_too_long_for_strip(self):
        reply = self.rpc("layout.apply", counts={"left": 100, "top": 100, "right": 100, "bottom": 100})
        self.assertEqual(reply["error"]["code"], "bad_request")

    def test_install_suggest(self):
        data = self.ok("install.suggest", tv_inches=55)
        self.assertEqual(data["total"], 212)

    def test_get_endpoints(self):
        base = self.url.replace("/rpc", "")
        with urllib.request.urlopen(base + "/ping", timeout=5) as resp:
            self.assertTrue(json.loads(resp.read())["data"]["pong"])


if __name__ == "__main__":
    unittest.main()
