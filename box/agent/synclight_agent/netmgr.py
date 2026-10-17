"""Wi-Fi mode switching with NetworkManager (nmcli): private hotspot or home Wi-Fi.

Hotspot mode: the Pi runs "SyncLight-XXXX" (192.168.4.1/24, DHCP via NetworkManager's
shared mode) at the highest autoconnect priority. The home Wi-Fi profile stays configured
with a lower priority, so if the hotspot cannot start, NetworkManager falls back to it.
"""

import logging
import subprocess

log = logging.getLogger(__name__)

HOTSPOT_CON = "synclight-ap"
HOTSPOT_IP = "192.168.4.1"
WIFI_IFACE = "wlan0"
LEASES_FILE = "/var/lib/NetworkManager/dnsmasq-wlan0.leases"


def lookup_lease(mac, path=LEASES_FILE):
    """IP handed out by the hotspot's DHCP server to this MAC (any format), or None."""
    if not mac:
        return None
    want = mac.replace(":", "").replace("-", "").lower()
    try:
        with open(path) as fh:
            for line in fh:
                parts = line.split()  # expiry mac ip hostname client-id
                if len(parts) >= 3 and parts[1].replace(":", "").lower() == want:
                    return parts[2]
    except OSError:
        return None
    return None


class NetError(Exception):
    pass


def _split_terse(line):
    """nmcli -t escapes ':' inside values as '\\:'."""
    parts, cur, esc = [], [], False
    for ch in line:
        if esc:
            cur.append(ch)
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == ":":
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return parts


class NetManager:
    def __init__(self, run=None):
        self._run_impl = run or self._subprocess_run

    @staticmethod
    def _subprocess_run(args, timeout):
        proc = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return proc.returncode, proc.stdout, proc.stderr

    def _nmcli(self, *args, timeout=40, check=True):
        try:
            code, out, err = self._run_impl(["nmcli", *args], timeout)
        except FileNotFoundError as exc:
            raise NetError("NetworkManager (nmcli) is not installed") from exc
        except subprocess.TimeoutExpired as exc:
            raise NetError(f"nmcli {' '.join(args[:3])} timed out") from exc
        if check and code != 0:
            raise NetError((err or out or f"nmcli exited {code}").strip())
        return out

    # ---- queries ----------------------------------------------------------------------
    def wifi_profiles(self):
        """All saved Wi-Fi profiles: [(name, autoconnect_priority)]."""
        out = self._nmcli("-t", "-f", "NAME,TYPE", "connection", "show")
        names = []
        for line in out.splitlines():
            parts = _split_terse(line)
            if len(parts) >= 2 and parts[1] == "802-11-wireless":
                names.append(parts[0])
        return names

    def active_wifi(self):
        """Name of the Wi-Fi profile active on wlan0, or None."""
        out = self._nmcli("-t", "-f", "NAME,TYPE,DEVICE", "connection", "show", "--active")
        for line in out.splitlines():
            parts = _split_terse(line)
            if len(parts) >= 3 and parts[1] == "802-11-wireless" and parts[2] == WIFI_IFACE:
                return parts[0]
        return None

    def get_field(self, con, field, secrets=False):
        args = ["-g", field, "connection", "show", con]
        if secrets:
            args.insert(0, "-s")
        return self._nmcli(*args).strip()

    def home_profile(self, preferred=None):
        """The home Wi-Fi profile: the preferred one if it still exists, else any non-hotspot profile."""
        profiles = [p for p in self.wifi_profiles() if p != HOTSPOT_CON]
        if preferred in profiles:
            return preferred
        return profiles[0] if profiles else None

    def status(self, home_hint=None):
        active = self.active_wifi()
        home = self.home_profile(home_hint)
        out = {
            "mode": "hotspot" if active == HOTSPOT_CON else ("home" if active else "offline"),
            "active_connection": active,
            "home_connection": home,
            "home_ssid": None,
            "hotspot_configured": HOTSPOT_CON in self.wifi_profiles(),
        }
        if home:
            try:
                out["home_ssid"] = self.get_field(home, "802-11-wireless.ssid")
            except NetError:
                pass
        return out

    # ---- changes ----------------------------------------------------------------------
    def ensure_hotspot(self, ssid, psk, channel=6):
        settings = [
            "802-11-wireless.ssid", ssid,
            "802-11-wireless.mode", "ap",
            "802-11-wireless.band", "bg",
            "802-11-wireless.channel", str(channel),
            "ipv4.method", "shared",
            "ipv4.addresses", f"{HOTSPOT_IP}/24",
            "ipv6.method", "disabled",
            "wifi-sec.key-mgmt", "wpa-psk",
            "wifi-sec.proto", "rsn",
            "wifi-sec.pairwise", "ccmp",
            "wifi-sec.group", "ccmp",
            "wifi-sec.pmf", "disable",   # ESP8266 does not support protected management frames
            "wifi-sec.psk", psk,
            "connection.autoconnect", "no",
        ]
        if HOTSPOT_CON in self.wifi_profiles():
            self._nmcli("connection", "modify", HOTSPOT_CON, *settings)
        else:
            self._nmcli("connection", "add", "type", "wifi", "ifname", WIFI_IFACE,
                        "con-name", HOTSPOT_CON, "ssid", ssid, *settings)

    def activate_hotspot(self, home=None):
        """Bring the hotspot up and make it the boot default. Falls back to home Wi-Fi on failure."""
        self._nmcli("connection", "modify", HOTSPOT_CON,
                    "connection.autoconnect", "yes", "connection.autoconnect-priority", "100")
        if home:
            self._nmcli("connection", "modify", home, "connection.autoconnect-priority", "0", check=False)
        try:
            self._nmcli("--wait", "30", "connection", "up", HOTSPOT_CON, timeout=45)
            return True
        except NetError as exc:
            log.error("Hotspot failed to start: %s", exc)
            self._nmcli("connection", "modify", HOTSPOT_CON, "connection.autoconnect", "no", check=False)
            if home:
                self._nmcli("--wait", "30", "connection", "up", home, timeout=45, check=False)
            return False

    def activate_home(self, home):
        if not home:
            raise NetError("no home Wi-Fi profile is saved on the box")
        self._nmcli("connection", "modify", HOTSPOT_CON, "connection.autoconnect", "no", check=False)
        self._nmcli("connection", "modify", home,
                    "connection.autoconnect", "yes", "connection.autoconnect-priority", "0", check=False)
        self._nmcli("--wait", "30", "connection", "up", home, timeout=45)
