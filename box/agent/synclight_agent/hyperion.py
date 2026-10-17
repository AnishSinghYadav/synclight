"""Minimal client for Hyperion.ng's JSON-RPC over the TCP "JSON server" (default port 19444).

Uses one persistent session so we can log in once with the Hyperion password; admin
commands such as `config setconfig` always require that login in Hyperion 2.1+.
Messages are newline-delimited JSON. Replies are matched by `tan`.
"""

import itertools
import json
import logging
import socket
import threading
import time

log = logging.getLogger(__name__)


class HyperionError(Exception):
    """Hyperion replied with an error."""


class HyperionUnavailable(HyperionError):
    """Hyperion could not be reached."""


class HyperionAuthError(HyperionError):
    """Login failed or an admin command was refused."""


class HyperionClient:
    def __init__(self, host="127.0.0.1", port=19444, password=None, timeout=5.0):
        self.host = host
        self.port = port
        self.password = password
        self.timeout = timeout
        self.admin = False
        self._sock = None
        self._buf = b""
        self._lock = threading.Lock()
        self._tan = itertools.count(1000)

    # ---- connection -------------------------------------------------------------------
    def close(self):
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
        self._sock = None
        self._buf = b""
        self.admin = False

    def _connect(self):
        self._sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self._buf = b""
        self.admin = False
        if self.password:
            reply = self._send_raw(
                {"command": "authorize", "subcommand": "login", "password": self.password}
            )
            self.admin = bool(reply.get("success"))
            if not self.admin:
                log.warning("Hyperion login failed: %s", reply.get("error"))

    def _readline(self, deadline):
        while b"\n" not in self._buf:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("no reply from Hyperion")
            self._sock.settimeout(remaining)
            chunk = self._sock.recv(65536)
            if not chunk:
                raise ConnectionError("Hyperion closed the connection")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\n", 1)
        return line

    def _send_raw(self, msg):
        tan = next(self._tan)
        msg = dict(msg, tan=tan)
        self._sock.sendall((json.dumps(msg) + "\n").encode())
        deadline = time.monotonic() + self.timeout
        while True:
            line = self._readline(deadline).strip()
            if not line:
                continue
            try:
                reply = json.loads(line)
            except ValueError:
                continue
            if reply.get("tan") == tan:
                return reply
            # Anything else (e.g. subscription updates) is ignored.

    def call(self, msg):
        """Send one message, reconnecting once if the session dropped. Returns the raw reply."""
        with self._lock:
            for attempt in (1, 2):
                try:
                    if self._sock is None:
                        self._connect()
                    return self._send_raw(msg)
                except (OSError, ConnectionError, TimeoutError) as exc:
                    self.close()
                    if attempt == 2:
                        raise HyperionUnavailable(f"Hyperion unreachable: {exc}") from exc

    def request(self, msg):
        """Send a message and return its `info`, raising on failure."""
        reply = self.call(msg)
        if not reply.get("success"):
            error = reply.get("error") or "unknown error"
            details = [d.get("description", "") for d in reply.get("errorData", []) if isinstance(d, dict)]
            text = error + (": " + "; ".join(details) if details else "")
            if "authoriz" in error.lower():
                raise HyperionAuthError(text)
            raise HyperionError(text)
        return reply.get("info")

    # ---- commands ---------------------------------------------------------------------
    def serverinfo(self):
        return self.request({"command": "serverinfo"}) or {}

    def set_color(self, rgb, priority, origin="SyncLight"):
        self.request({"command": "color", "color": list(rgb), "priority": priority, "origin": origin})

    def set_effect(self, name, priority, origin="SyncLight"):
        self.request({"command": "effect", "effect": {"name": name}, "priority": priority, "origin": origin})

    def clear(self, priority):
        self.request({"command": "clear", "priority": priority})

    def set_component(self, component, state):
        self.request({"command": "componentstate", "componentstate": {"component": component, "state": bool(state)}})

    def set_brightness(self, value):
        self.request({"command": "adjustment", "adjustment": {"brightness": int(value)}})

    def set_instance_settings(self, settings, instance=0):
        """Persist settings (e.g. {"leds": [...]}) for one instance. Needs admin login."""
        if not self.admin:
            # Retry the login once in case Hyperion restarted since we connected.
            self.close()
            self.call({"command": "serverinfo"})
            if not self.admin:
                raise HyperionAuthError(
                    "Not logged in to Hyperion. Check the password in /etc/synclight/config.json"
                )
        self.request(
            {
                "command": "config",
                "subcommand": "setconfig",
                "config": {"instances": [{"id": instance, "settings": settings}]},
            }
        )
