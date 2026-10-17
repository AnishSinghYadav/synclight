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
