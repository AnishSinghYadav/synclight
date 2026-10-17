#!/usr/bin/env bash
# Installs or updates the SyncLight agent on the Raspberry Pi.
# Usage:  bash install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
echo "==> Installing SyncLight agent from $SRC"

# Bluetooth support (app control without Wi-Fi)
NEED=""
for pkg in bluez python3-dbus python3-gi; do
  dpkg -s "$pkg" >/dev/null 2>&1 || NEED="$NEED $pkg"
done
if [ -n "$NEED" ]; then
  echo "==> Installing:$NEED"
  apt-get update -qq && apt-get install -y -qq $NEED
fi
rfkill unblock bluetooth 2>/dev/null || true
systemctl enable --now bluetooth >/dev/null 2>&1 || true

install -d -m 755 /opt/synclight /etc/synclight /var/lib/synclight
rm -rf /opt/synclight/synclight_agent
cp -r "$SRC/agent/synclight_agent" /opt/synclight/
find /opt/synclight -name '__pycache__' -prune -exec rm -rf {} +

if [ ! -f /etc/synclight/config.json ]; then
  echo
  echo "The agent logs in to Hyperion to save the LED layout."
  read -rsp "Hyperion web UI password (press Enter if you never changed it from 'hyperion'): " HPW < /dev/tty
  echo
  HPW="${HPW:-hyperion}"
  read -rp "ESP / WLED address [synclight-led.local]: " WHOST < /dev/tty
  WHOST="${WHOST:-synclight-led.local}"
  python3 - "$HPW" "$WHOST" <<'PY'
import json, sys
cfg = {
    "name": "synclight",
    "hyperion": {"host": "127.0.0.1", "port": 19444, "password": sys.argv[1]},
    "wled": {"host": sys.argv[2]},
    "http": {"host": "0.0.0.0", "port": 8484},
    "state_file": "/var/lib/synclight/state.json",
}
with open("/etc/synclight/config.json", "w") as fh:
    json.dump(cfg, fh, indent=2)
PY
  chmod 600 /etc/synclight/config.json
  echo "==> Wrote /etc/synclight/config.json"
else
  echo "==> Keeping existing /etc/synclight/config.json"
fi

install -m 644 "$SRC/deploy/synclight-agent.service" /etc/systemd/system/synclight-agent.service
if [ -d /etc/avahi/services ]; then
  install -m 644 "$SRC/deploy/synclight.avahi.service" /etc/avahi/services/synclight.service
fi

systemctl daemon-reload
systemctl enable synclight-agent >/dev/null
systemctl restart synclight-agent

echo "==> Waiting for the agent to start"
for _ in $(seq 1 15); do
  if curl -fsS http://127.0.0.1:8484/api/v1/ping >/dev/null 2>&1; then
    echo
    curl -fsS http://127.0.0.1:8484/api/v1/status | python3 -m json.tool
    echo
    echo "==> SyncLight agent is running on port 8484"
    exit 0
  fi
  sleep 1
done

echo "!! The agent did not answer. Recent log:"
journalctl -u synclight-agent -n 30 --no-pager
exit 1
