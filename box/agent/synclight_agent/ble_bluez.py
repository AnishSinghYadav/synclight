"""Bluetooth LE GATT server on BlueZ (D-Bus). Carries the same JSON messages as HTTP.

Needs: bluez, python3-dbus, python3-gi (the installer adds them). Runs as root.
"""

import json
import logging
import queue
import threading

import dbus
import dbus.exceptions
import dbus.mainloop.glib
import dbus.service
from gi.repository import GLib

from .ble_framing import FramingError, Reassembler, chunk_payload_for_mtu, split

log = logging.getLogger(__name__)

SERVICE_UUID = "5f1e0001-8a3c-4b6e-9d2a-53796e634c74"
REQUEST_UUID = "5f1e0002-8a3c-4b6e-9d2a-53796e634c74"
RESPONSE_UUID = "5f1e0003-8a3c-4b6e-9d2a-53796e634c74"

BLUEZ = "org.bluez"
ADAPTER_IFACE = "org.bluez.Adapter1"
GATT_MANAGER_IFACE = "org.bluez.GattManager1"
LE_ADV_MANAGER_IFACE = "org.bluez.LEAdvertisingManager1"
GATT_SERVICE_IFACE = "org.bluez.GattService1"
GATT_CHRC_IFACE = "org.bluez.GattCharacteristic1"
LE_ADV_IFACE = "org.bluez.LEAdvertisement1"
OM_IFACE = "org.freedesktop.DBus.ObjectManager"
PROP_IFACE = "org.freedesktop.DBus.Properties"

APP_PATH = "/app/synclight"
ADV_PATH = "/app/synclight/advertisement0"


class InvalidArgs(dbus.exceptions.DBusException):
    _dbus_error_name = "org.freedesktop.DBus.Error.InvalidArgs"


class NotSupported(dbus.exceptions.DBusException):
    _dbus_error_name = "org.bluez.Error.NotSupported"


def _bytes_array(data):
    return dbus.Array([dbus.Byte(b) for b in data], signature="y")


class Application(dbus.service.Object):
    def __init__(self, bus):
        self.services = []
        super().__init__(bus, APP_PATH)

    @dbus.service.method(OM_IFACE, out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):  # noqa: N802
        objects = {}
        for svc in self.services:
            objects[dbus.ObjectPath(svc.path)] = svc.properties()
            for chrc in svc.characteristics:
                objects[dbus.ObjectPath(chrc.path)] = chrc.properties()
        return objects


class Service(dbus.service.Object):
    def __init__(self, bus, index, uuid):
        self.path = f"{APP_PATH}/service{index}"
        self.uuid = uuid
        self.characteristics = []
        super().__init__(bus, self.path)

    def properties(self):
        return {GATT_SERVICE_IFACE: {
            "UUID": self.uuid,
            "Primary": True,
            "Characteristics": dbus.Array([dbus.ObjectPath(c.path) for c in self.characteristics], signature="o"),
        }}

    @dbus.service.method(PROP_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):  # noqa: N802
        if interface != GATT_SERVICE_IFACE:
            raise InvalidArgs()
        return self.properties()[GATT_SERVICE_IFACE]


class Characteristic(dbus.service.Object):
    def __init__(self, bus, index, uuid, flags, service):
        self.path = f"{service.path}/char{index}"
        self.uuid = uuid
        self.flags = flags
        self.service = service
        super().__init__(bus, self.path)

    def properties(self):
        return {GATT_CHRC_IFACE: {
            "Service": dbus.ObjectPath(self.service.path),
            "UUID": self.uuid,
            "Flags": dbus.Array(self.flags, signature="s"),
        }}

    @dbus.service.method(PROP_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):  # noqa: N802
        if interface != GATT_CHRC_IFACE:
            raise InvalidArgs()
        return self.properties()[GATT_CHRC_IFACE]

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, options):  # noqa: N802
        raise NotSupported()

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="aya{sv}")
    def WriteValue(self, value, options):  # noqa: N802
        raise NotSupported()

    @dbus.service.method(GATT_CHRC_IFACE)
    def StartNotify(self):  # noqa: N802
        raise NotSupported()

    @dbus.service.method(GATT_CHRC_IFACE)
    def StopNotify(self):  # noqa: N802
        raise NotSupported()

    @dbus.service.signal(PROP_IFACE, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):  # noqa: N802
        pass


class RequestCharacteristic(Characteristic):
    def __init__(self, bus, index, service, on_chunk):
        super().__init__(bus, index, REQUEST_UUID, ["write", "write-without-response"], service)
        self._on_chunk = on_chunk

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="aya{sv}")
    def WriteValue(self, value, options):  # noqa: N802
        device = str(options.get("device", "unknown"))
        mtu = int(options.get("mtu", 23))
        self._on_chunk(device, bytes(bytearray(value)), mtu)


class ResponseCharacteristic(Characteristic):
    def __init__(self, bus, index, service):
        super().__init__(bus, index, RESPONSE_UUID, ["read", "notify"], service)
        self.notifying = False
        self.value = b""

    @dbus.service.method(GATT_CHRC_IFACE, in_signature="a{sv}", out_signature="ay")
    def ReadValue(self, options):  # noqa: N802
        return _bytes_array(self.value)

    @dbus.service.method(GATT_CHRC_IFACE)
    def StartNotify(self):  # noqa: N802
        self.notifying = True
        log.info("Bluetooth client subscribed")

    @dbus.service.method(GATT_CHRC_IFACE)
    def StopNotify(self):  # noqa: N802
        self.notifying = False
        log.info("Bluetooth client unsubscribed")

    def notify(self, data):
        self.value = data
        if self.notifying:
            self.PropertiesChanged(GATT_CHRC_IFACE, {"Value": _bytes_array(data)}, [])


class Advertisement(dbus.service.Object):
    def __init__(self, bus, local_name):
        self.local_name = local_name
        super().__init__(bus, ADV_PATH)

    def properties(self):
        return {
            "Type": "peripheral",
            "ServiceUUIDs": dbus.Array([SERVICE_UUID], signature="s"),
            "LocalName": dbus.String(self.local_name),
        }

    @dbus.service.method(PROP_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):  # noqa: N802
        if interface != LE_ADV_IFACE:
            raise InvalidArgs()
        return self.properties()

    @dbus.service.method(LE_ADV_IFACE)
    def Release(self):  # noqa: N802
        log.info("Bluetooth advertisement released by BlueZ")


class BleServer:
    """Runs the GLib main loop in its own thread; commands run one at a time in a worker."""

    def __init__(self, dispatcher, info):
        self.dispatcher = dispatcher
        self.info = info  # dict shared with the service for system.status
        self._requests = queue.Queue()
        self._reassemblers = {}
        self._mtus = {}
        self.bus = None
        self.response = None
        self._registered = False

    # ---- lifecycle --------------------------------------------------------------------
    def start(self):
        threading.Thread(target=self._run_loop, name="ble-loop", daemon=True).start()
        threading.Thread(target=self._worker, name="ble-worker", daemon=True).start()

    def _run_loop(self):
        try:
            if hasattr(dbus.mainloop.glib, "threads_init"):
                dbus.mainloop.glib.threads_init()
            dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
            self.bus = dbus.SystemBus()
            self.bus.watch_name_owner(BLUEZ, self._bluez_owner_changed)
            GLib.MainLoop().run()
        except Exception as exc:  # noqa: BLE001
            log.exception("Bluetooth stopped")
            self.info.update(enabled=False, error=str(exc))

    def _bluez_owner_changed(self, owner):
        if owner:
            log.info("BlueZ is up, registering SyncLight service")
            self._registered = False
            GLib.timeout_add_seconds(1, self._register)
        else:
            log.warning("BlueZ went away")
            self.info.update(advertising=False)

    def _find_adapter(self):
        manager = dbus.Interface(self.bus.get_object(BLUEZ, "/"), OM_IFACE)
        for path, ifaces in manager.GetManagedObjects().items():
            if GATT_MANAGER_IFACE in ifaces and LE_ADV_MANAGER_IFACE in ifaces:
                return path, ifaces[ADAPTER_IFACE]
        return None, None

    def _register(self):
        """Returns False so GLib doesn't repeat it; schedules its own retry on failure."""
        if self._registered:
            return False
        try:
            path, adapter_props = self._find_adapter()
            if not path:
                raise RuntimeError("no Bluetooth LE adapter found")
            props = dbus.Interface(self.bus.get_object(BLUEZ, path), PROP_IFACE)
            props.Set(ADAPTER_IFACE, "Powered", dbus.Boolean(True))
            address = str(adapter_props.get("Address", "00:00"))
            suffix = address.replace(":", "")[-4:].upper()
            name = f"SyncLight-{suffix}"
            props.Set(ADAPTER_IFACE, "Alias", dbus.String(name))

            if self.response is None:
                app = Application(self.bus)
                svc = Service(self.bus, 0, SERVICE_UUID)
                req = RequestCharacteristic(self.bus, 0, svc, self._on_chunk)
                self.response = ResponseCharacteristic(self.bus, 1, svc)
                svc.characteristics += [req, self.response]
                app.services.append(svc)
                self._app = app
                self._adv = Advertisement(self.bus, f"SL-{suffix}")

            obj = self.bus.get_object(BLUEZ, path)
            dbus.Interface(obj, GATT_MANAGER_IFACE).RegisterApplication(
                dbus.ObjectPath(APP_PATH), {}, reply_handler=lambda: log.info("GATT service registered"),
                error_handler=lambda e: self._failed("GATT registration", e))
            dbus.Interface(obj, LE_ADV_MANAGER_IFACE).RegisterAdvertisement(
                dbus.ObjectPath(ADV_PATH), {}, reply_handler=lambda: self._advertising(name),
                error_handler=lambda e: self._failed("advertising", e))
            self._registered = True
        except Exception as exc:  # noqa: BLE001
            self._failed("setup", exc)
        return False

    def _advertising(self, name):
        log.info("Bluetooth advertising as %s", name)
        self.info.update(enabled=True, advertising=True, name=name, error=None)

    def _failed(self, what, exc):
        if "AlreadyExists" in str(exc):
            return  # registered earlier and still active; nothing to do
        log.warning("Bluetooth %s failed: %s (retrying in 10 s)", what, exc)
        self.info.update(enabled=False, advertising=False, error=f"{what}: {exc}")
        self._registered = False
        GLib.timeout_add_seconds(10, self._register)

    # ---- messages ---------------------------------------------------------------------
    def _on_chunk(self, device, chunk, mtu):
        self._mtus[device] = mtu
        reassembler = self._reassemblers.setdefault(device, Reassembler())
        try:
            message = reassembler.feed(chunk)
        except FramingError as exc:
            log.warning("Bad chunk from %s: %s", device, exc)
            return
        if message is not None:
            self._requests.put((device, message))

    def _worker(self):
        while True:
            device, message = self._requests.get()
            try:
                request = json.loads(message)
            except ValueError:
                reply = {"id": None, "ok": False, "error": {"code": "bad_request", "message": "not valid JSON"}}
            else:
                reply = self.dispatcher.handle(request)
            data = json.dumps(reply, separators=(",", ":")).encode()
            chunks = split(data, chunk_payload_for_mtu(self._mtus.get(device, 23)))
            GLib.idle_add(self._send_chunks, chunks)

    def _send_chunks(self, chunks):
        if self.response is not None:
            for chunk in chunks:
                self.response.notify(chunk)
        return False


def start(dispatcher, info):
    server = BleServer(dispatcher, info)
    server.start()
    return server
