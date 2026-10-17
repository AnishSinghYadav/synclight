"""Business logic behind every protocol command (see PROTOCOL.md)."""

import logging
import threading
import time

from . import __version__, layout
from .hyperion import HyperionAuthError, HyperionClient, HyperionError, HyperionUnavailable
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
               "light": dict(self.state.data["light"]), "layout": self.state.data.get("layout")}
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
            info = self.wled.info()
            wl.update(reachable=True, led_count=(info.get("leds") or {}).get("count"),
                      version=info.get("ver"), name=info.get("name"))
        except WledUnavailable as exc:
            wl["error"] = str(exc)
        out["wled"] = wl
        return out

    # ---- light control ----------------------------------------------------------------
    def power(self, on):
        if not isinstance(on, bool):
            raise _bad("on must be true or false")
        with self._lock:
            self._not_calibrating()
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
