"""Entry point: python3 -m synclight_agent --config /etc/synclight/config.json"""

import argparse
import logging
import signal
import sys
import threading
import time

from . import __version__
from .config import StateStore, load_config
from .hyperion import HyperionError
from .server import Dispatcher, make_http_server
from .service import SyncLightService

log = logging.getLogger("synclight")


def restore_on_boot(service, stop_event):
    """Wait for Hyperion to come up, then re-apply the saved light state."""
    delay = 2
    while not stop_event.is_set():
        try:
            service.apply_saved_state()
            log.info("Saved light state applied (admin login: %s)", service.hyperion.admin)
            return
        except HyperionError as exc:
            log.info("Waiting for Hyperion (%s)", exc)
            stop_event.wait(delay)
            delay = min(delay * 2, 15)


def keep_led_host_in_sync(service, stop_event):
    """Every 20 s, make sure Hyperion sends to the ESP's current address."""
    while not stop_event.wait(20):
        try:
            service.sync_led_host()
        except Exception:  # noqa: BLE001
            log.exception("LED host sync failed")


def main(argv=None):
    parser = argparse.ArgumentParser(description="SyncLight agent")
    parser.add_argument("--config", default="/etc/synclight/config.json")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s")
    config = load_config(args.config)
    state = StateStore(config["state_file"])
    service = SyncLightService(config, state)
    dispatcher = Dispatcher(service)

    if config.get("bluetooth", {}).get("enabled", True):
        try:
            from . import ble_bluez
        except ImportError as exc:
            log.warning("Bluetooth disabled, missing package: %s (sudo apt install python3-dbus python3-gi)", exc)
            service.ble_info.update(error=f"missing package: {exc}")
        else:
            ble_bluez.start(dispatcher, service.ble_info)

    stop_event = threading.Event()
    threading.Thread(target=restore_on_boot, args=(service, stop_event), daemon=True).start()
    threading.Thread(target=keep_led_host_in_sync, args=(service, stop_event), daemon=True).start()

    http = make_http_server(dispatcher, config["http"]["host"], config["http"]["port"])
    log.info("SyncLight agent %s listening on %s:%s", __version__, config["http"]["host"], config["http"]["port"])

    def shutdown(*_):
        stop_event.set()
        threading.Thread(target=http.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    try:
        http.serve_forever()
    finally:
        try:
            service.calibrate_stop()
        except Exception:  # noqa: BLE001
            pass
        service.hyperion.close()
        time.sleep(0.1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
