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

    def _resolve(self, refresh=False):
        if self._ip is None or refresh:
            try:
                self._ip = socket.getaddrinfo(self._name, self._port, socket.AF_INET)[0][4][0]
            except OSError as exc:
                raise WledUnavailable(f"cannot resolve {self.host}: {exc}") from exc
        return self._ip

    def _request(self, path, body=None):
        for attempt in (1, 2):
            ip = self._resolve(refresh=attempt == 2)
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(
                f"http://{ip}:{self._port}{path}",
                data=data,
                method="POST" if body is not None else "GET",
                headers={"Content-Type": "application/json"},
            )
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    raw = resp.read()
                return json.loads(raw) if raw else {}
            except (urllib.error.URLError, OSError, ValueError) as exc:
                if attempt == 2:
                    raise WledUnavailable(f"WLED at {self.host} not reachable: {exc}") from exc

    def info(self):
        return self._request("/json/info")

    def state(self):
        return self._request("/json/state")

    def set_state(self, state):
        return self._request("/json/state", state)

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
