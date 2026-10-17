import os
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "agent"))
sys.path.insert(0, os.path.dirname(__file__))

from fakes import FakeHyperion, FakeWled  # noqa: E402
from synclight_agent.config import StateStore, load_config  # noqa: E402
from synclight_agent.netmgr import HOTSPOT_CON, NetManager, _split_terse  # noqa: E402
from synclight_agent.service import CommandError, SyncLightService  # noqa: E402


class FakeNmcli:
    """Just enough of nmcli for NetManager."""

    def __init__(self, hotspot_works=True):
        self.profiles = {"netplan-wlan0-Home\\:Net": {"802-11-wireless.ssid": "Home:Net",
                                                      "802-11-wireless-security.psk": "homepass123"}}
        self.active = "netplan-wlan0-Home\\:Net"
        self.hotspot_works = hotspot_works
        self.calls = []

    def __call__(self, args, timeout):
        self.calls.append(args)
        a = args[1:]
        secrets_ok = False
        if a[0] == "-s":
            secrets_ok, a = True, a[1:]
        if a[:3] == ["-t", "-f", "NAME,TYPE"]:
            return 0, "".join(f"{n}:802-11-wireless\n" for n in self.profiles) + "Wired:802-3-ethernet\n", ""
        if a[:3] == ["-t", "-f", "NAME,TYPE,DEVICE"]:
            return 0, (f"{self.active}:802-11-wireless:wlan0\n" if self.active else ""), ""
        if a[0] == "-g":
            name = a[4].replace(":", "\\:")
            field = a[1]
            if "psk" in field and not secrets_ok:
                return 0, "\n", ""
            return 0, self.profiles[name].get(field, "") + "\n", ""
        if a[:2] == ["connection", "add"]:
            name = a[a.index("con-name") + 1]
            self.profiles[name] = dict(zip(a[8::2], a[9::2]))
            return 0, "", ""
        if a[:2] == ["connection", "modify"]:
            name = a[2].replace(":", "\\:")
            if name not in self.profiles:
                return 10, "", "Error: unknown connection"
            self.profiles[name].update(dict(zip(a[3::2], a[4::2])))
            return 0, "", ""
        if a[:4] == ["--wait", "30", "connection", "up"]:
            name = a[4].replace(":", "\\:")
            if name == HOTSPOT_CON and not self.hotspot_works:
                return 4, "", "Error: Connection activation failed"
            self.active = name
            return 0, "", ""
        return 2, "", "unexpected " + " ".join(args)


class NetworkTests(unittest.TestCase):
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

    def tearDown(self):
        self.service.hyperion.close()
        self.hyp.close()
        self.wled.close()
        self.tmp.cleanup()

    def use(self, nm):
        self.service.net = NetManager(run=nm)
        return nm

    def wait_switch(self):
        deadline = time.time() + 10
        while self.service._switching and time.time() < deadline:
            time.sleep(0.1)
        self.assertFalse(self.service._switching)

    def test_split_terse(self):
        self.assertEqual(_split_terse("Home\\:Net:802-11-wireless:wlan0"), ["Home:Net", "802-11-wireless", "wlan0"])

    def test_status_home(self):
        self.use(FakeNmcli())
        st = self.service.net_status()
        self.assertEqual(st["mode"], "home")
        self.assertEqual(st["home_connection"], "netplan-wlan0-Home:Net")
        self.assertEqual(st["home_ssid"], "Home:Net")

    def test_switch_to_hotspot_and_back(self):
        nm = self.use(FakeNmcli())
        r = self.service.net_use_hotspot()
        self.assertTrue(r["led_controller_moved"])
        self.assertTrue(r["hotspot_ssid"].startswith("SyncLight-"))
        self.assertEqual(len(r["hotspot_password"]), 16)
        # The ESP was told to join the hotspot (DHCP), then rebooted.
        cfg_post = self.wled.posts[self.wled.paths.index("/json/cfg")]
        entry = cfg_post["nw"]["ins"][0]
        self.assertEqual((entry["ssid"], entry["psk"]), (r["hotspot_ssid"], r["hotspot_password"]))
        self.assertEqual(entry["ip"], [0, 0, 0, 0])
        self.assertEqual(cfg_post["id"]["mdns"], "synclight-led")
        self.assertEqual(self.service.state.data["network"]["led_mac"], "c82b96230272")
        self.assertEqual(self.wled.posts[-1], {"rb": True})
        self.wait_switch()
        self.assertEqual(nm.active, HOTSPOT_CON)
        self.assertEqual(nm.profiles[HOTSPOT_CON]["connection.autoconnect-priority"], "100")
        self.assertEqual(nm.profiles[HOTSPOT_CON]["wifi-sec.pmf"], "disable")
        self.assertEqual(self.service.wled.host, self.cfg["wled"]["host"])  # found by name, not a fixed IP
        self.assertEqual(self.service.status()["network"]["mode"], "hotspot")
        # Same password next time.
        self.assertEqual(self.service._hotspot_credentials()[1], r["hotspot_password"])

        # Back to home Wi-Fi: the ESP gets the home network (password read from NetworkManager).
        n_posts = len(self.wled.posts)
        r = self.service.net_use_home()
        self.assertTrue(r["led_controller_moved"])
        entry = self.wled.posts[n_posts]["nw"]["ins"][0]
        self.assertEqual((entry["ssid"], entry["psk"], entry["ip"]), ("Home:Net", "homepass123", [0, 0, 0, 0]))
        self.wait_switch()
        self.assertEqual(nm.active, "netplan-wlan0-Home\\:Net")
        self.assertEqual(nm.profiles[HOTSPOT_CON]["connection.autoconnect"], "no")
        self.assertEqual(self.service.wled.host, self.cfg["wled"]["host"])

    def test_hotspot_failure_falls_back_home(self):
        nm = self.use(FakeNmcli(hotspot_works=False))
        self.service.net_use_hotspot()
        self.wait_switch()
        self.assertEqual(nm.active, "netplan-wlan0-Home\\:Net")
        st = self.service.status()["network"]
        self.assertEqual(st["mode"], "home")
        self.assertIn("did not start", st["error"])

    def test_no_switch_while_calibrating(self):
        self.use(FakeNmcli())
        self.service.calibrate_start()
        with self.assertRaises(CommandError) as ctx:
            self.service.net_use_hotspot()
        self.assertEqual(ctx.exception.code, "busy")
        self.service.calibrate_stop()

    def test_lease_lookup(self):
        from synclight_agent.netmgr import lookup_lease
        path = os.path.join(self.tmp.name, "leases")
        with open(path, "w") as fh:
            fh.write("1792260000 f2:25:cd:b6:fb:3a 192.168.4.57 MacBook 01:f2:25:cd:b6:fb:3a\n")
            fh.write("1792260000 c8:2b:96:23:02:72 192.168.4.83 synclight-led *\n")
        self.assertEqual(lookup_lease("c82b96230272", path), "192.168.4.83")
        self.assertEqual(lookup_lease("C8:2B:96:23:02:72", path), "192.168.4.83")
        self.assertIsNone(lookup_lease("aabbccddeeff", path))
        self.assertIsNone(lookup_lease(None, path))

    def test_name_falls_back_to_lease(self):
        self.service.wled.use_host("no-such-host.invalid")
        self.service.wled.fallback_lookup = lambda: "127.0.0.1"
        self.assertEqual(self.service.wled.resolve(), "127.0.0.1")

    def test_sync_led_host(self):
        self.service.sync_led_host()
        self.assertEqual(self.hyp.settings[0]["device"]["host"], "127.0.0.1")
        self.assertEqual(self.hyp.settings[0]["device"]["hardwareLedCount"], 236)


if __name__ == "__main__":
    unittest.main()
