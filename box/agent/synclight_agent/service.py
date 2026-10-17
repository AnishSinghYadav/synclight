"""Business logic behind every protocol command (see PROTOCOL.md)."""

import logging
import secrets
import threading
import time

from . import __version__, layout
from .hyperion import HyperionAuthError, HyperionClient, HyperionError, HyperionUnavailable
from .netmgr import HOTSPOT_IP, NetError, NetManager, lookup_lease
from .wled import WledClient, WledUnavailable

log = logging.getLogger(__name__)

PRIORITY = 50  # our colors/effects; USB capture runs at 240, lower number wins
MANUAL_PRIORITY = 1  # what Hyperion's own web page uses


class CommandError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def _bad(message):
    return CommandError("bad_request", message)


def _rgb(value):
    if (not isinstance(value, (list, tuple)) or len(value) != 3
            or not all(isinstance(c, int) and 0 <= c <= 255 for c in value)):
        raise _bad("color must be [r, g, b] with values 0-255")
    return [int(c) for c in value]


class SyncLightService:
    def __init__(self, config, state):
        self.config = config
        self.state = state
        hcfg = config["hyperion"]
        self.hyperion = HyperionClient(hcfg["host"], hcfg["port"], hcfg.get("password"))
        self.wled = WledClient(config["wled"]["host"])
        self._lock = threading.RLock()
        self._calibrating = False
        self._saved_wled_state = None
        self.ble_info = {"enabled": False, "advertising": False}
        self.net = NetManager()
        self._default_wled_host = config["wled"]["host"]
        self._switching = False
        self._net_error = None
        self._hyperion_led_host = None
        self._signal_missing_since = None
        self._signal_brightness = None
        self._boot_restored = False
        # If the ESP's name doesn't resolve, look it up by MAC address in the hotspot's DHCP leases.
        self.wled.fallback_lookup = lambda: lookup_lease((self.state.data.get("network") or {}).get("led_mac"))

    # ---- helpers ----------------------------------------------------------------------
    def _call(self, fn, *args):
        try:
            return fn(*args)
        except HyperionAuthError as exc:
            raise CommandError("hyperion_auth", str(exc)) from exc
        except HyperionUnavailable as exc:
            raise CommandError("hyperion_unavailable", str(exc)) from exc
        except HyperionError as exc:
            raise CommandError("internal", f"Hyperion: {exc}") from exc
        except WledUnavailable as exc:
            raise CommandError("wled_unavailable", str(exc)) from exc
        except NetError as exc:
            raise CommandError("network", str(exc)) from exc

    def _not_calibrating(self):
        if self._calibrating:
            raise CommandError("busy", "Calibration is running. Send calibrate.stop first.")

    def _wled_led_count(self):
        info = self._call(self.wled.info)
        return int((info.get("leds") or {}).get("count") or 0)

    # ---- system -----------------------------------------------------------------------
    def ping(self):
        return {"pong": True, "version": __version__, "name": self.config["name"]}

    def status(self):
        out = {"version": __version__, "name": self.config["name"], "calibrating": self._calibrating,
               "light": dict(self.state.data["light"]), "layout": self.state.data.get("layout"),
               "bluetooth": dict(self.ble_info),
               "network": {"mode": (self.state.data.get("network") or {}).get("mode") or "home",
                           "switching": self._switching, "error": self._net_error}}
        hyp = {"reachable": False, "admin": False, "capture_active": False, "led_output": None}
        try:
            info = self.hyperion.serverinfo()
            hyp["reachable"] = True
            hyp["admin"] = self.hyperion.admin
            comps = {c.get("name"): c.get("enabled") for c in info.get("components", [])}
            hyp["led_output"] = comps.get("LEDDEVICE")
            hyp["capture_active"] = any(
                p.get("componentId") == "V4L" and p.get("active") for p in info.get("priorities", [])
            )
        except HyperionError as exc:
            hyp["error"] = str(exc)
        out["hyperion"] = hyp

        wl = {"reachable": False, "host": self.config["wled"]["host"]}
        try:
            started = time.monotonic()
            info = self.wled.info(quick=True)
            wl["response_ms"] = round((time.monotonic() - started) * 1000)
            wl["signal_dbm"] = (info.get("wifi") or {}).get("rssi")
            self._remember_led(info)
            wl.update(reachable=True, led_count=(info.get("leds") or {}).get("count"),
                      version=info.get("ver"), name=info.get("name"))
        except WledUnavailable as exc:
            wl["error"] = str(exc)
        out["signal_guard"] = {"enabled": self.config.get("signal_guard", {}).get("enabled", True),
                               "dimmed": self._signal_brightness is not None}
        out["wled"] = wl
        return out

    # ---- light control ----------------------------------------------------------------
    def power(self, on):
        if not isinstance(on, bool):
            raise _bad("on must be true or false")
        with self._lock:
            self._not_calibrating()
            self.reset_signal_guard()
            self._call(self.hyperion.set_component, "ALL", on)
            self.state.data["light"]["power"] = on
            self.state.save()
        return {"power": on}

    def brightness(self, value):
        if not isinstance(value, int) or not 0 <= value <= 100:
            raise _bad("value must be a whole number 0-100")
        with self._lock:
            self._call(self.hyperion.set_brightness, value)
            self.state.data["light"]["brightness"] = value
            self.state.save()
        return {"brightness": value}

    def mode(self, mode, color=None, effect=None):
        with self._lock:
            self._not_calibrating()
            self.reset_signal_guard()
            light = self.state.data["light"]
            # Remove leftovers from Hyperion's web page (priority 1) so the app stays in control.
            try:
                self.hyperion.clear(MANUAL_PRIORITY)
            except HyperionError:
                pass
            if mode == "sync":
                self._call(self.hyperion.clear, PRIORITY)
            elif mode == "color":
                rgb = _rgb(color if color is not None else light.get("color"))
                self._call(self.hyperion.set_color, rgb, PRIORITY)
                light["color"] = rgb
            elif mode == "effect":
                if not isinstance(effect, str) or not effect:
                    raise _bad("effect name required")
                self._call(self.hyperion.set_effect, effect, PRIORITY)
                light["effect"] = effect
            else:
                raise _bad("mode must be 'sync', 'color' or 'effect'")
            light["mode"] = mode
            self.state.save()
            return dict(light)

    def effects(self):
        info = self._call(self.hyperion.serverinfo)
        names = sorted(e.get("name") for e in info.get("effects", []) if e.get("name"))
        return {"effects": names}

    def apply_saved_state(self):
        """Re-apply power/brightness/mode after boot."""
        light = self.state.data["light"]
        self.hyperion.set_brightness(light.get("brightness", 80))
        self.hyperion.set_component("ALL", bool(light.get("power", True)))
        mode = light.get("mode", "sync")
        if mode == "color":
            self.hyperion.set_color(light.get("color") or [255, 120, 0], PRIORITY)
        elif mode == "effect" and light.get("effect"):
            self.hyperion.set_effect(light["effect"], PRIORITY)
        else:
            self.hyperion.clear(PRIORITY)

    # ---- install guide ----------------------------------------------------------------
    def install_suggest(self, tv_inches=None, leds_per_m=60, inset_cm=3.0, aspect="16:9"):
        if not isinstance(tv_inches, (int, float)):
            raise _bad("tv_inches is required (e.g. 55)")
        try:
            return layout.suggest(tv_inches, leds_per_m, inset_cm, aspect)
        except layout.LayoutError as exc:
            raise _bad(str(exc)) from exc

    # ---- calibration ------------------------------------------------------------------
    def calibrate_start(self):
        with self._lock:
            self.reset_signal_guard()
            if not self._calibrating:
                self._saved_wled_state = self._call(self.wled.state)
                # Stop Hyperion from streaming so WLED accepts direct control.
                self._call(self.hyperion.set_component, "LEDDEVICE", False)
                time.sleep(0.5)
                self._calibrating = True
            self._call(self.wled.show_ranges, [])
            count = self._wled_led_count()
        return {"calibrating": True, "led_count": count}

    def _require_calibrating(self):
        if not self._calibrating:
            raise CommandError("busy", "Send calibrate.start first.")

    def calibrate_cursor(self, index=None, marks=None):
        if not isinstance(index, int) or index < 0:
            raise _bad("index must be a whole number >= 0")
        marks = marks or []
        if not isinstance(marks, list) or not all(isinstance(m, int) and m >= 0 for m in marks):
            raise _bad("marks must be a list of LED indexes")
        with self._lock:
            self._require_calibrating()
            ranges = [(m, m + 1, "FF0000") for m in marks if m != index]
            ranges.append((index, index + 1, "00FF00"))
            self._call(self.wled.show_ranges, ranges)
        return {"index": index}

    def calibrate_sides(self, **layout_args):
        with self._lock:
            self._require_calibrating()
            lay = self._normalize(layout_args)
            ranges = [(start, stop, layout.SIDE_COLORS[side]) for side, start, stop in layout.side_ranges(lay)]
            self._call(self.wled.show_ranges, ranges)
        return {"sides": {side: [start, stop - 1] for side, start, stop in layout.side_ranges(lay)},
                "colors": layout.SIDE_COLORS}

    def calibrate_stop(self):
        with self._lock:
            if self._calibrating:
                try:
                    if self._saved_wled_state:
                        self._call(self.wled.restore, self._saved_wled_state)
                finally:
                    self._calibrating = False
                    self._saved_wled_state = None
                    self._call(self.hyperion.set_component, "LEDDEVICE", True)
        return {"calibrating": False}

    # ---- layout -----------------------------------------------------------------------
    def _normalize(self, layout_args):
        hw = None
        try:
            hw = self._wled_led_count()
        except CommandError:
            pass  # still allow computing without the ESP online
        try:
            return layout.normalize(layout_args, hw)
        except layout.LayoutError as exc:
            raise _bad(str(exc)) from exc

    def layout_compute(self, **layout_args):
        return self._normalize(layout_args)

    def layout_apply(self, **layout_args):
        with self._lock:
            lay = self._normalize(layout_args)
            leds = layout.build_hyperion_leds(lay["counts"], lay["start_corner"], lay["direction"], lay["offset"])
            self._call(self.hyperion.set_instance_settings, {"leds": leds})
            self.state.data["layout"] = lay
            self.state.save()
        return dict(lay, applied=True, leds=len(leds))

    def layout_get(self):
        return {"layout": self.state.data.get("layout")}

    # ---- network (private hotspot / home Wi-Fi) ---------------------------------------
    def _suffix(self):
        try:
            with open("/sys/class/net/wlan0/address") as fh:
                return fh.read().strip().replace(":", "")[-4:].upper()
        except OSError:
            return "0000"

    def _net_state(self):
        return self.state.data.setdefault("network", {})

    def _hotspot_credentials(self):
        net = self._net_state()
        if not net.get("hotspot_ssid") or not net.get("hotspot_psk"):
            net["hotspot_ssid"] = f"SyncLight-{self._suffix()}"
            net["hotspot_psk"] = secrets.token_urlsafe(12)[:16]
            self.state.save()
        return net["hotspot_ssid"], net["hotspot_psk"]

    def net_status(self):
        net = self._net_state()
        st = self._call(self.net.status, net.get("home_connection"))
        st.update(
            switching=self._switching,
            error=self._net_error,
            hotspot_ssid=net.get("hotspot_ssid"),
            hotspot_password=net.get("hotspot_psk"),
            hotspot_ip=HOTSPOT_IP,
            led_controller_host=self.wled.host,
        )
        return st

    def _start_switch(self, mode, home):
        self._switching = True
        self._net_error = None
        threading.Thread(target=self._finish_switch, args=(mode, home), daemon=True).start()

    def _finish_switch(self, mode, home):
        time.sleep(2)  # let the reply reach the app first
        net = self._net_state()
        try:
            if mode == "hotspot":
                if self.net.activate_hotspot(home):
                    log.info("Now running the private hotspot")
                else:
                    net["mode"] = "home"
                    self._net_error = "The private Wi-Fi did not start, so the box went back to home Wi-Fi."
            else:
                self.net.activate_home(home)
                log.info("Now on home Wi-Fi (%s)", home)
            self._hyperion_led_host = None  # re-check where the LED controller is
            self.state.save()
        except NetError as exc:
            log.error("Network switch failed: %s", exc)
            self._net_error = str(exc)
        finally:
            self._switching = False

    def _move_led_controller(self, ssid, psk):
        try:
            mac = (self.wled.info().get("mac") or "").lower()
            if mac:
                self._net_state()["led_mac"] = mac
            self.wled.set_wifi(ssid, psk)  # DHCP; the box finds it by name or MAC
            time.sleep(2)  # give WLED time to save before it reboots
            self.wled.reboot()
            return True
        except WledUnavailable as exc:
            log.warning("Could not reconfigure the LED controller: %s", exc)
            return False

    def net_use_hotspot(self):
        with self._lock:
            self._not_calibrating()
            if self._switching:
                raise CommandError("busy", "The box is already switching networks.")
            st = self._call(self.net.status, self._net_state().get("home_connection"))
            if st["mode"] == "hotspot":
                return dict(st, changed=False)
            home = st["home_connection"]
            ssid, psk = self._hotspot_credentials()
            self._call(self.net.ensure_hotspot, ssid, psk,
                       self.config.get("network", {}).get("hotspot_channel", 1))
            moved = self._move_led_controller(ssid, psk)
            net = self._net_state()
            net.update(mode="hotspot", home_connection=home)
            self.state.save()
            self._start_switch("hotspot", home)
        return {"changed": True, "switching_to": "hotspot", "hotspot_ssid": ssid, "hotspot_password": psk,
                "led_controller_moved": moved, "home_connection": home}

    def net_use_home(self):
        with self._lock:
            self._not_calibrating()
            if self._switching:
                raise CommandError("busy", "The box is already switching networks.")
            st = self._call(self.net.status, self._net_state().get("home_connection"))
            if st["mode"] == "home":
                return dict(st, changed=False)
            home = st["home_connection"]
            if not home:
                raise CommandError("network", "No home Wi-Fi is saved on the box.")
            home_ssid = self._call(self.net.get_field, home, "802-11-wireless.ssid")
            home_psk = self._call(self.net.get_field, home, "802-11-wireless-security.psk", True)
            moved = self._move_led_controller(home_ssid, home_psk)
            self._net_state().update(mode="home", home_connection=home)
            self.state.save()
            self._start_switch("home", home)
        return {"changed": True, "switching_to": "home", "home_connection": home, "led_controller_moved": moved}

    def sync_led_host(self):
        """Keep Hyperion's LED device address equal to where the ESP actually is. Safe to call often."""
        if self._calibrating or self._switching:
            return
        try:
            info = self.wled.info()
            self._remember_led(info)
            ip = self.wled.resolve(refresh=False)
        except WledUnavailable:
            return
        try:
            dev = self.hyperion.get_led_device()
            if dev and dev.get("type") == "wled" and dev.get("host") != ip:
                self.hyperion.set_instance_settings({"device": dict(dev, host=ip)})
                log.info("Hyperion now sends to the LED controller at %s", ip)
            self._hyperion_led_host = ip
        except HyperionError as exc:
            log.debug("LED host sync skipped: %s", exc)


    def _remember_led(self, info):
        mac = info.get("mac")
        with self._lock:
            if mac and self._net_state().get("led_mac") != mac:
                self._net_state()["led_mac"] = mac
                self.state.save()

    def health(self):
        """On-demand checks with actionable messages; does not change settings."""
        status = self.status()
        checks = []
        def add(name, ok, message):
            checks.append({"name": name, "ok": bool(ok), "message": message})
        h, w = status["hyperion"], status["wled"]
        add("engine", h["reachable"], "Light engine is running." if h["reachable"] else
            "Hyperion is unavailable. Check its service and configured password.")
        add("controller", w["reachable"],
            f"WLED replied in {w.get('response_ms')} ms; signal {w.get('signal_dbm', '?')} dBm."
            if w["reachable"] else "WLED did not respond. Check its power, hotspot connection and Wi-Fi packet loss.")
        add("output", h.get("led_output"), "LED output is enabled." if h.get("led_output") else
            "Enable LED Device in Hyperion's dashboard.")
        add("capture", h.get("capture_active"), "HDMI capture is active." if h.get("capture_active") else
            "No active capture input. Check the HDMI source and USB capture device.")
        add("layout", status.get("layout") is not None, "TV layout is saved." if status.get("layout") else
            "Run Set up TV to map the LED strip.")
        try:
            net = self.net_status()
            if net["mode"] == "hotspot":
                channel = self.net.get_field("synclight-ap", "802-11-wireless.channel")
                add("hotspot", channel == str(self.config.get("network", {}).get("hotspot_channel", 1)),
                    f"Hotspot channel {channel}. Configured preferred channel: "
                    f"{self.config.get('network', {}).get('hotspot_channel', 1)}.")
            else:
                add("network", net["mode"] != "offline", f"Network mode: {net['mode']}.")
        except (CommandError, NetError) as exc:
            add("network", False, str(exc))
        return {"checks": checks, "ok": all(c["ok"] for c in checks)}

    def reset_signal_guard(self):
        with self._lock:
            if self._signal_brightness is not None:
                self.hyperion.set_brightness(self.state.data["light"]["brightness"])
            self._signal_brightness = None
            self._signal_missing_since = None

    def signal_tick(self, now=None):
        """Fade only sync mode when Hyperion reports no active V4L input.

        A capture card's generated no-signal image requires native Hyperion signal detection.
        Connection errors are not interpreted as signal loss.
        """
        with self._lock:
            cfg = self.config.get("signal_guard", {})
            light = self.state.data["light"]
            if (not cfg.get("enabled", True) or light["mode"] != "sync" or not light["power"]
                    or self._calibrating or self._switching):
                self.reset_signal_guard()
                return
            info = self.hyperion.serverinfo()
            # Missing fields are unknown, not an instruction to turn the lights off.
            if "priorities" not in info:
                return
            active = any(p.get("componentId") == "V4L" and p.get("active")
                         for p in info["priorities"])
            if active:
                self.reset_signal_guard()
                return
            now = time.monotonic() if now is None else now
            if self._signal_missing_since is None:
                self._signal_missing_since = now
            elapsed = now - self._signal_missing_since - cfg.get("grace_seconds", 10)
            if elapsed < 0:
                return
            fraction = min(1, elapsed / max(0.1, cfg.get("fade_seconds", 3)))
            value = round(light["brightness"] * (1 - fraction))
            if value != self._signal_brightness:
                self.hyperion.set_brightness(value)
                self._signal_brightness = value
