"""Minimal client for WLED's JSON API (HTTP)."""

import json
import logging
import socket
import urllib.error
import urllib.request

log = logging.getLogger(__name__)


class WledUnavailable(Exception):
    pass


class WledClient:
    def __init__(self, host, timeout=3.0):
        self.host = host
        name, _, port = host.partition(":")
        self._name = name
        self._port = int(port) if port else 80
        self.timeout = timeout
        self._ip = None
        self.fallback_lookup = None  # optional callable returning an IP when the name doesn't resolve

    def _resolve(self, refresh=False):
        if self._ip is None or refresh:
            try:
                self._ip = socket.getaddrinfo(self._name, self._port, socket.AF_INET)[0][4][0]
            except OSError as exc:
                ip = self.fallback_lookup() if self.fallback_lookup else None
                if not ip:
                    raise WledUnavailable(f"cannot resolve {self.host}: {exc}") from exc
                self._ip = ip
        return self._ip

    def _request(self, path, body=None, timeout=None, retry=True):
        attempts = (1, 2) if retry else (2,)
        for attempt in attempts:
            ip = self._resolve(refresh=attempt == 2)
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(
                f"http://{ip}:{self._port}{path}",
                data=data,
                method="POST" if body is not None else "GET",
                headers={"Content-Type": "application/json"},
            )
            try:
                with urllib.request.urlopen(req, timeout=timeout or self.timeout) as resp:
                    raw = resp.read()
                return json.loads(raw) if raw else {}
            except (urllib.error.URLError, OSError, ValueError) as exc:
                if attempt == 2:
                    raise WledUnavailable(f"WLED at {self.host} not reachable: {exc}") from exc

    def info(self, quick=False):
        """quick: one short attempt, for status screens that must not hang on an offline ESP."""
        if quick:
            return self._request("/json/info", timeout=1.5, retry=False)
        return self._request("/json/info")

    def state(self):
        return self._request("/json/state")

    def set_state(self, state):
        return self._request("/json/state", state)

    def set_config(self, cfg):
        """Write settings (POST /json/cfg). WLED saves them to flash in its next loop."""
        return self._request("/json/cfg", cfg)

    def set_wifi(self, ssid, psk, static_ip=None, gateway=None):
        """Replace the ESP's first Wi-Fi network. static_ip/gateway like "192.168.4.2" or None for DHCP."""
        def quad(text):
            return [int(x) for x in text.split(".")] if text else [0, 0, 0, 0]
        entry = {"ssid": ssid, "psk": psk, "ip": quad(static_ip), "gw": quad(gateway),
                 "sn": [255, 255, 255, 0] if static_ip else [0, 0, 0, 0]}
        self.set_config({"nw": {"ins": [entry]}, "id": {"mdns": "synclight-led"}})

    def reboot(self):
        try:
            self.set_state({"rb": True})
        except WledUnavailable:
            pass  # it may drop the connection while rebooting

    def use_host(self, host):
        """Point this client at a different address (e.g. after the ESP changed networks)."""
        if host != self.host:
            self.host = host
            name, _, port = host.partition(":")
            self._name = name
            self._port = int(port) if port else 80
            self._ip = None

    def resolve(self):
        return self._resolve(refresh=True)

    def show_ranges(self, ranges, bri=160):
        """Light ranges of pixels and turn everything else off.

        ranges: list of (start, stop_exclusive, "RRGGBB").
        """
        # Leave realtime mode, stop effects, paint the segment black.
        self.set_state({"on": True, "bri": bri, "live": False, "transition": 0,
                        "seg": {"id": 0, "fx": 0, "frz": False, "col": [[0, 0, 0]]}})
        if not ranges:
            return
        items = []
        for start, stop, color in ranges:
            if stop > start:
                items += [int(start), int(stop), color]
        # Keep each request small: the ESP8266 has a tight JSON buffer.
        chunk = 3 * 40
        for i in range(0, len(items), chunk):
            self.set_state({"seg": {"id": 0, "i": items[i:i + chunk]}})

    def restore(self, saved_state):
        """Put back a state captured with state()."""
        state = {k: v for k, v in saved_state.items() if k in ("on", "bri", "transition", "ps", "seg")}
        if "seg" in state:
            state["seg"] = [dict(s, frz=False) for s in state["seg"] if isinstance(s, dict)]
        self.set_state(state)
