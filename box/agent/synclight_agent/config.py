"""Config (/etc/synclight/config.json) and persisted state (/var/lib/synclight/state.json)."""

import copy
import json
import logging
import os
import tempfile
import threading

log = logging.getLogger(__name__)

DEFAULT_CONFIG = {
    "name": "synclight",
    "hyperion": {"host": "127.0.0.1", "port": 19444, "password": "hyperion"},
    "wled": {"host": "synclight-led.local"},
    "http": {"host": "0.0.0.0", "port": 8484},
    "bluetooth": {"enabled": True},
    "network": {"hotspot_channel": 1},
    "signal_guard": {"enabled": True, "grace_seconds": 10, "fade_seconds": 3},
    "state_file": "/var/lib/synclight/state.json",
}

DEFAULT_STATE = {
    "light": {"power": True, "brightness": 80, "mode": "sync", "color": [255, 120, 0], "effect": None},
    "layout": None,
    "network": {"mode": None},
}


def _merge(base, override):
    out = copy.deepcopy(base)
    for key, value in (override or {}).items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], value)
        else:
            out[key] = value
    return out


def load_config(path):
    data = {}
    if path and os.path.exists(path):
        with open(path) as fh:
            data = json.load(fh)
    else:
        log.warning("Config %s not found, using defaults", path)
    return _merge(DEFAULT_CONFIG, data)


class StateStore:
    """Small JSON file written atomically, so a power cut never leaves it half-written."""

    def __init__(self, path):
        self.path = path
        self._lock = threading.Lock()
        self.data = self._load()

    def _load(self):
        try:
            with open(self.path) as fh:
                return _merge(DEFAULT_STATE, json.load(fh))
        except FileNotFoundError:
            return copy.deepcopy(DEFAULT_STATE)
        except (OSError, ValueError) as exc:
            log.error("State file unreadable (%s), starting fresh", exc)
            return copy.deepcopy(DEFAULT_STATE)

    def save(self):
        with self._lock:
            directory = os.path.dirname(self.path) or "."
            os.makedirs(directory, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=directory, prefix=".state-")
            with os.fdopen(fd, "w") as fh:
                json.dump(self.data, fh, indent=2)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, self.path)
