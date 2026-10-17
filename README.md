# SyncLight

Plug-and-play HDMI ambient light for TVs.

```
HDMI source → splitter ─┬→ TV
                        └→ USB capture → Pi Zero 2 W (Hyperion + synclight-agent) → ESP8266 (WLED) → LED strip
                                                   ↑
                                            Android app
```

| Folder | What |
|---|---|
| `PROTOCOL.md` | Messages between the app and the box |
| `box/` | The Pi service (`synclight-agent`), installer, tests |
| `app/` | The Android app (Flutter) |
| `.github/workflows/` | Cloud build: every push to `main` builds the APK and the box package |

## Get the latest build

Every push to `main` publishes a release with:
- `synclight.apk` – install on the phone
- `synclight-box.tar.gz` – the Pi software

**Phone:** open https://github.com/AnishSinghYadav/synclight/releases/latest on the phone, tap
`synclight.apk`, and allow "install unknown apps" for your browser when asked.

**Pi** (install or update):
```bash
curl -L -o synclight-box.tar.gz https://github.com/AnishSinghYadav/synclight/releases/latest/download/synclight-box.tar.gz
tar xzf synclight-box.tar.gz
bash synclight-box/install.sh
```
Settings in `/etc/synclight/config.json` are kept on update. Logs: `journalctl -u synclight-agent -f`

## Develop

Box tests (any computer with Python 3.9+):
```bash
python3 -m unittest discover -s box/tests -v
```

The app's `android/` folder is generated in CI with `flutter create`, then patched by
`tools/patch_android.py` (network permissions, cleartext HTTP to the box, app name).

## Reliability update (0.3.3)

Hotspot setup now defaults to channel **1**, following packet-loss testing on the Pi/ESP
setup. Set `network.hotspot_channel` to override it. Existing Wi-Fi credentials and TV
layout survive installation. See [the reliability settings](PROTOCOL.md#reliability-and-health-agent-033)
for recovery, health checks, and capture-loss fading.

After installing, verify the saved channel and device status:

```bash
nmcli -g 802-11-wireless.channel connection show synclight-ap
curl -fsS http://127.0.0.1:8484/api/v1/status | python3 -m json.tool
curl -fsS http://127.0.0.1:8484/api/v1/rpc \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"cmd":"system.health","args":{}}' | python3 -m json.tool
```

Hardware acceptance checks: power-cycle Pi and ESP together; change colors in the app;
verify TV sync; unplug/reconnect HDMI and check fading/resume; check static color is
unaffected by HDMI loss. Native Hyperion signal detection may be needed for capture
cards that keep generating frames without HDMI. Keep a backup of `/etc/synclight`,
`/var/lib/synclight/state.json`, and `/opt/synclight` before deployment. The old app remains
compatible with agent 0.3.3; the health button requires rebuilding the Android app.
