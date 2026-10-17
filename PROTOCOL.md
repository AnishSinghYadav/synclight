# SyncLight App ↔ Box Protocol (v1)

The Android app talks to the box (Pi Zero 2 W running `synclight-agent`) with small JSON
messages. The **same messages** are used over every transport, so the app's logic does not
care how it is connected:

| Transport | When | Status |
|---|---|---|
| HTTP `POST http://<box>:8484/api/v1/rpc` | Development, and when box + phone share a network | **v0 (now)** |
| Bluetooth LE (GATT) | First-time setup and everyday control once the box runs its private hotspot | Next phase |

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

## 3. Bluetooth LE mapping (next phase)
- One custom GATT service, UUID `5f1e0001-8a3c-4b6e-9d2a-53796e634c74`
  - `...0002` **request** characteristic (write)
  - `...0003` **response** characteristic (notify)
- Messages are the same JSON envelope, UTF-8, split into chunks that fit the negotiated MTU.
  Each chunk starts with a 1-byte header: bit 7 = "more chunks follow", bits 0-6 = sequence number.
- Wi-Fi/hotspot provisioning commands (`net.*`) will be added in the hotspot phase.

## 4. Discovery
- HTTP: the box advertises `_synclight._tcp` on port 8484 via mDNS (hostname `synclight.local`).
- BLE: advertises name `SyncLight-XXXX` with the service UUID above.

## 5. Versioning
Breaking changes bump the path (`/api/v2/rpc`) and the BLE service UUID. New commands and new
fields in `data` are not breaking; the app must ignore unknown fields.
