# SyncLight App ↔ Box Protocol (v1)

The Android app talks to the box (Pi Zero 2 W running `synclight-agent`) with small JSON
messages. The **same messages** are used over every transport, so the app's logic does not
care how it is connected:

| Transport | When | Status |
|---|---|---|
| HTTP `POST http://<box>:8484/api/v1/rpc` | Development, and when box + phone share a network | **v0 (now)** |
| Bluetooth LE (GATT) | Normal app connection; no Wi-Fi needed on the phone side | v0.2 |

## 1. Envelope

Request:
```json
{ "id": 7, "cmd": "light.brightness", "args": { "value": 70 } }
```

Success:
```json
{ "id": 7, "ok": true, "data": { "brightness": 70 } }
```

Error:
```json
{ "id": 7, "ok": false, "error": { "code": "bad_request", "message": "value must be 0-100" } }
```

- `id` — any integer chosen by the app; echoed back so replies can be matched.
- `args` — optional; omit or send `{}` when a command takes none.

### Error codes
| Code | Meaning |
|---|---|
| `bad_request` | Missing or invalid argument |
| `unknown_command` | `cmd` not recognised |
| `hyperion_unavailable` | The light engine (Hyperion) is not reachable |
| `hyperion_auth` | Agent could not log in to Hyperion (wrong password in config) |
| `wled_unavailable` | The LED controller (ESP) is not reachable |
| `busy` | Command not allowed right now (e.g. normal control during calibration) |
| `network` | Wi-Fi change failed (NetworkManager error) |
| `internal` | Unexpected error — see agent log |

## 2. Commands

### System
| cmd | args | data |
|---|---|---|
| `system.ping` | – | `{pong, version, name}` |
| `system.status` | – | see below |

`system.status` data:
```json
{
  "version": "0.1.0",
  "name": "synclight",
  "hyperion": { "reachable": true, "admin": true, "capture_active": true, "led_output": true },
  "wled":     { "reachable": true, "host": "synclight-led.local", "led_count": 236, "version": "0.15.0" },
  "light":    { "power": true, "brightness": 80, "mode": "sync", "color": [255,120,0], "effect": null },
  "layout":   { "configured": true, "counts": {"left":43,"top":75,"right":43,"bottom":75}, "start_corner": "bottom_left", "direction": "cw", "offset": 0 },
  "bluetooth": { "enabled": true, "advertising": true, "name": "SyncLight-AB12" },
  "network":   { "mode": "hotspot", "switching": false, "error": null },
  "calibrating": false
}
```

### Everyday light control
| cmd | args | notes |
|---|---|---|
| `light.power` | `{on: bool}` | Turns all output on/off |
| `light.brightness` | `{value: 0-100}` | |
| `light.mode` | `{mode: "sync"}` | Follow the HDMI picture |
| | `{mode: "color", color: [r,g,b]}` | Static color |
| | `{mode: "effect", effect: "Rainbow swirl"}` | Name from `light.effects` |
| `light.effects` | – | `{effects: ["Rainbow swirl", ...]}` |

All of these are remembered by the box and re-applied after a power cut.

### Install guide (the app's setup wizard)
| cmd | args | data |
|---|---|---|
| `install.suggest` | `{tv_inches, leds_per_m=60, inset_cm=3, aspect="16:9"}` | Suggested LEDs per side, strip length needed, power estimate |

### Calibration (find the real corners on the installed strip)
While calibrating, the agent pauses Hyperion and drives the strip directly.

| cmd | args | what the user sees |
|---|---|---|
| `calibrate.start` | – | Strip goes dark |
| `calibrate.cursor` | `{index, marks: [int...]}` | LED `index` lit bright green; already-confirmed corners (`marks`) lit red |
| `calibrate.sides` | layout args (below) | Each side lit in its own color to verify: left = red, top = green, right = blue, bottom = yellow, unused = off |
| `calibrate.stop` | – | Strip returns to normal (Hyperion resumes) |

App flow: start → user drags a slider / taps ± to move the green dot → taps **"This is the corner"**
→ app remembers the index → repeat for each corner → `calibrate.sides` to confirm → `layout.apply` → `calibrate.stop`.

### Layout
Layout args can be given in either of two forms:

**By counts** (from `install.suggest` or typed in):
```json
{ "counts": {"left": 43, "top": 75, "right": 43, "bottom": 75},
  "start_corner": "bottom_left", "direction": "cw", "offset": 0 }
```

**By marks** (from calibration) — the index of the **first LED of each side**, in the order the strip travels, plus the **last LED used**:
```json
{ "marks": {"starts": [0, 43, 118, 161], "end": 235},
  "start_corner": "bottom_left", "direction": "cw" }
```

- `start_corner`: `bottom_left` | `bottom_right` | `top_left` | `top_right` (looking at the TV from the front)
- `direction`: `cw` (clockwise) | `ccw`
- `offset`: LEDs before the first corner that are not on the TV (wire run). With marks, it is `starts[0]`.
- Product default: **bottom_left, cw**.

| cmd | args | data |
|---|---|---|
| `layout.compute` | layout args | `{counts, order, offset, total}` — no changes made |
| `layout.apply` | layout args | Saves the layout into Hyperion and the box |
| `layout.get` | – | Current layout |

### Network (private Wi-Fi)
The box normally runs its own Wi-Fi ("SyncLight-XXXX", 192.168.4.1/24) that only the LED
controller joins (DHCP; the box finds it as `synclight-led.local`, or by MAC in the DHCP leases).
Home Wi-Fi is kept as a fallback and for development.

| cmd | args | data |
|---|---|---|
| `net.status` | – | `{mode: "hotspot"\|"home"\|"offline", switching, error, active_connection, home_connection, home_ssid, hotspot_ssid, hotspot_password, hotspot_ip, led_controller_host}` |
| `net.use_hotspot` | – | Moves the LED controller to the private Wi-Fi, then switches the box (in the background, ~30 s). If the hotspot cannot start, the box returns to home Wi-Fi and `net.status.error` says so. |
| `net.use_home` | – | Moves the LED controller and the box back to home Wi-Fi (developer mode, updates). |

Both switch commands reply first and switch about 2 s later, so a client on Wi-Fi gets its answer
before the network changes. Bluetooth clients stay connected throughout.

## 3. Bluetooth LE transport
- One custom GATT service, UUID `5f1e0001-8a3c-4b6e-9d2a-53796e634c74`
  - `5f1e0002-…` **request** characteristic (write with response)
  - `5f1e0003-…` **response** characteristic (notify)
- The app negotiates a larger MTU (asks for 247) after connecting.
- Messages are the same JSON envelope, UTF-8, split into chunks:
  1 header byte + up to `min(MTU-3, 512) - 1` bytes of payload.
  Header bit 7 = "more chunks follow", bits 0-6 = sequence number, starting at 0 for each message
  and wrapping from 127 back to 0 inside long messages.
- The app sends one request at a time and waits for its reply; the box answers requests in order.

## 4. Discovery
- HTTP: the box advertises `_synclight._tcp` on port 8484 via mDNS (hostname `synclight.local`).
- BLE: advertises the service UUID above with the short name `SL-XXXX` (fits in one advertising
  packet); the device name after connecting is `SyncLight-XXXX`. XXXX = end of the Pi's Bluetooth address.

## 5. Versioning
Breaking changes bump the path (`/api/v2/rpc`) and the BLE service UUID. New commands and new
fields in `data` are not breaking; the app must ignore unknown fields.
