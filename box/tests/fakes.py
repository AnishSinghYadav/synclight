"""Fake Hyperion (TCP JSON server) and fake WLED (HTTP) for tests."""

import json
import socketserver
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeHyperion:
    PASSWORD = "hyperion"

    def __init__(self):
        self.components = {"ALL": True, "LEDDEVICE": True, "V4L": True, "SMOOTHING": True}
        self.priorities = {240: {"componentId": "V4L", "priority": 240}}
        self.brightness = 100
        self.settings = {}
        self.effects = ["Rainbow swirl", "Knight rider", "Candle"]
        self.log = []
        fake = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                admin = False
                for raw in self.rfile:
                    msg = json.loads(raw)
                    fake.log.append(msg)
                    reply, admin = fake.process(msg, admin)
                    # Send an unrelated message first, like a subscription update, to test tan matching.
                    self.wfile.write(b'{"command":"priorities-update","data":{}}\n')
                    self.wfile.write((json.dumps(reply) + "\n").encode())

        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def process(self, msg, admin):
        cmd, tan = msg.get("command"), msg.get("tan")
        ok = lambda info=None: {"command": cmd, "success": True, "tan": tan, **({"info": info} if info is not None else {})}  # noqa: E731
        err = lambda e: {"command": cmd, "success": False, "tan": tan, "error": e}  # noqa: E731
        if cmd == "authorize" and msg.get("subcommand") == "login":
            if msg.get("password") == self.PASSWORD:
                return ok({"token": "x"}), True
            return err("No Authorization"), admin
        if cmd == "serverinfo":
            prios = [dict(p, active=True) for p in self.priorities.values()]
            return ok({"components": [{"name": k, "enabled": v} for k, v in self.components.items()],
                       "priorities": prios, "effects": [{"name": e} for e in self.effects]}), admin
        if cmd == "color":
            self.priorities[msg["priority"]] = {"componentId": "COLOR", "priority": msg["priority"], "value": msg["color"]}
            return ok(), admin
        if cmd == "effect":
            if msg["effect"]["name"] not in self.effects:
                return err("Effect '%s' not found" % msg["effect"]["name"]), admin
            self.priorities[msg["priority"]] = {"componentId": "EFFECT", "priority": msg["priority"], "owner": msg["effect"]["name"]}
            return ok(), admin
        if cmd == "clear":
            self.priorities.pop(msg["priority"], None)
            return ok(), admin
        if cmd == "componentstate":
            cs = msg["componentstate"]
            self.components[cs["component"]] = cs["state"]
            return ok(), admin
        if cmd == "adjustment":
            self.brightness = msg["adjustment"]["brightness"]
            return ok(), admin
        if cmd == "config" and msg.get("subcommand") == "setconfig":
            if not admin:
                return err("No Authorization"), admin
            for inst in msg["config"]["instances"]:
                self.settings.setdefault(inst["id"], {}).update(inst["settings"])
            return ok(), admin
        return err("Invalid command"), admin

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class FakeWled:
    def __init__(self, count=236):
        self.count = count
        self.pixels = ["000000"] * count
        self.state = {"on": True, "bri": 128, "seg": [{"id": 0, "fx": 9, "col": [[255, 160, 0]]}]}
        self.posts = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _json(self, payload):
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):  # noqa: N802
                if self.path == "/json/info":
                    self._json({"ver": "0.15.0", "name": "SyncLight LED", "leds": {"count": fake.count}})
                else:
                    self._json(fake.state)

            def do_POST(self):  # noqa: N802
                data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                fake.posts.append(data)
                fake.apply(data)
                self._json({"success": True})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def apply(self, data):
        for key in ("on", "bri"):
            if key in data:
                self.state[key] = data[key]
        seg = data.get("seg")
        if isinstance(seg, dict):
            if "col" in seg:
                hexcol = "%02X%02X%02X" % tuple(seg["col"][0])
                self.pixels = [hexcol] * self.count
            items = seg.get("i")
            if items:
                for j in range(0, len(items), 3):
                    start, stop, color = items[j:j + 3]
                    for p in range(start, min(stop, self.count)):
                        self.pixels[p] = color
            self.state["seg"][0].update({k: v for k, v in seg.items() if k != "i"})
        elif isinstance(seg, list):
            self.state["seg"] = seg

    def lit(self):
        return {i: c for i, c in enumerate(self.pixels) if c != "000000"}

    def close(self):
        self.server.shutdown()
        self.server.server_close()
