"""Transport-independent RPC dispatcher + the HTTP transport (POST /api/v1/rpc)."""

import inspect
import json
import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .service import CommandError

log = logging.getLogger(__name__)

MAX_BODY = 64 * 1024


class Dispatcher:
    def __init__(self, service):
        s = service
        self.commands = {
            "system.ping": s.ping,
            "system.status": s.status,
            "light.power": s.power,
            "light.brightness": s.brightness,
            "light.mode": s.mode,
            "light.effects": s.effects,
            "install.suggest": s.install_suggest,
            "calibrate.start": s.calibrate_start,
            "calibrate.cursor": s.calibrate_cursor,
            "calibrate.sides": s.calibrate_sides,
            "calibrate.stop": s.calibrate_stop,
            "layout.compute": s.layout_compute,
            "layout.apply": s.layout_apply,
            "layout.get": s.layout_get,
        }

    def handle(self, message):
        """Takes a decoded request envelope, returns a response envelope (never raises)."""
        req_id = message.get("id") if isinstance(message, dict) else None
        try:
            if not isinstance(message, dict):
                raise CommandError("bad_request", "request must be a JSON object")
            cmd = message.get("cmd")
            args = message.get("args") or {}
            if not isinstance(args, dict):
                raise CommandError("bad_request", "args must be an object")
            fn = self.commands.get(cmd)
            if fn is None:
                raise CommandError("unknown_command", f"unknown command: {cmd}")
            params = inspect.signature(fn).parameters
            takes_any = any(p.kind is inspect.Parameter.VAR_KEYWORD for p in params.values())
            if not takes_any:
                unknown = set(args) - set(params)
                if unknown:
                    raise CommandError("bad_request", f"unexpected argument(s): {', '.join(sorted(unknown))}")
            try:
                data = fn(**args)
            except TypeError as exc:
                raise CommandError("bad_request", str(exc)) from exc
            return {"id": req_id, "ok": True, "data": data}
        except CommandError as exc:
            return {"id": req_id, "ok": False, "error": {"code": exc.code, "message": exc.message}}
        except Exception as exc:  # noqa: BLE001 - never let one command kill the server
            log.exception("Command failed")
            return {"id": req_id, "ok": False, "error": {"code": "internal", "message": str(exc)}}


def make_http_server(dispatcher, host, port):
    class Handler(BaseHTTPRequestHandler):
        server_version = "SyncLight"

        def log_message(self, fmt, *args):
            log.debug("http %s - %s", self.address_string(), fmt % args)

        def _send(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.end_headers()
            self.wfile.write(body)

        def do_OPTIONS(self):  # noqa: N802
            self._send(204, {})

        def do_GET(self):  # noqa: N802
            if self.path in ("/api/v1/status", "/api/v1/ping"):
                cmd = "system.status" if self.path.endswith("status") else "system.ping"
                self._send(200, dispatcher.handle({"id": 0, "cmd": cmd}))
            else:
                self._send(404, {"ok": False, "error": {"code": "not_found", "message": "use POST /api/v1/rpc"}})

        def do_POST(self):  # noqa: N802
            if self.path != "/api/v1/rpc":
                self._send(404, {"ok": False, "error": {"code": "not_found", "message": "use POST /api/v1/rpc"}})
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BODY:
                self._send(400, {"ok": False, "error": {"code": "bad_request", "message": "missing or too large body"}})
                return
            try:
                message = json.loads(self.rfile.read(length))
            except ValueError:
                self._send(400, {"ok": False, "error": {"code": "bad_request", "message": "body is not valid JSON"}})
                return
            self._send(200, dispatcher.handle(message))

    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    return server
