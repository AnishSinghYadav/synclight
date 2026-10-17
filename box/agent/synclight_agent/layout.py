"""LED layout math: install suggestions, calibration marks -> counts, counts -> Hyperion LED map.

Screen coordinates follow Hyperion: h (horizontal) 0 = left .. 1 = right,
v (vertical) 0 = top .. 1 = bottom. Positions are as seen from the FRONT of the TV.
"""

import math

SIDES = ("top", "right", "bottom", "left")          # clockwise order
CORNERS = ("bottom_left", "bottom_right", "top_left", "top_right")
DIRECTIONS = ("cw", "ccw")

# First side travelled from each corner.
_FIRST_SIDE = {
    "cw": {"top_left": "top", "top_right": "right", "bottom_right": "bottom", "bottom_left": "left"},
    "ccw": {"bottom_left": "bottom", "bottom_right": "right", "top_right": "top", "top_left": "left"},
}

# Colors used to verify each side during calibration.
SIDE_COLORS = {"left": "FF0000", "top": "00FF00", "right": "0000FF", "bottom": "FFC000"}

DEPTH_TOP_BOTTOM = 0.08   # share of picture height sampled by top/bottom LEDs
DEPTH_LEFT_RIGHT = 0.05   # share of picture width sampled by left/right LEDs


class LayoutError(ValueError):
    pass


def side_order(start_corner, direction):
    if start_corner not in CORNERS:
        raise LayoutError(f"start_corner must be one of {', '.join(CORNERS)}")
    if direction not in DIRECTIONS:
        raise LayoutError("direction must be 'cw' or 'ccw'")
    seq = list(SIDES) if direction == "cw" else list(reversed(SIDES))
    first = _FIRST_SIDE[direction][start_corner]
    i = seq.index(first)
    return seq[i:] + seq[:i]


def _rect(side, t0, t1, d_tb, d_lr):
    """Area for an LED covering [t0, t1] of a side, t measured clockwise."""
    if side == "top":
        return t0, t1, 0.0, d_tb
    if side == "right":
        return 1.0 - d_lr, 1.0, t0, t1
    if side == "bottom":
        return 1.0 - t1, 1.0 - t0, 1.0 - d_tb, 1.0
    return 0.0, d_lr, 1.0 - t1, 1.0 - t0  # left


def build_hyperion_leds(counts, start_corner="bottom_left", direction="cw", offset=0,
                        depth_tb=DEPTH_TOP_BOTTOM, depth_lr=DEPTH_LEFT_RIGHT):
    """Return Hyperion's `leds` list, one entry per hardware LED index.

    LEDs before `offset` (wire run) get an empty area so they stay dark.
    LEDs after the last side are simply not listed; Hyperion leaves them dark.
    """
    order = side_order(start_corner, direction)
    leds = [{"hmin": 0.0, "hmax": 0.0, "vmin": 0.0, "vmax": 0.0} for _ in range(offset)]
    for side in order:
        n = int(counts.get(side, 0))
        for k in range(n):
            if direction == "cw":
                t0, t1 = k / n, (k + 1) / n
            else:
                t0, t1 = 1 - (k + 1) / n, 1 - k / n
            hmin, hmax, vmin, vmax = _rect(side, t0, t1, depth_tb, depth_lr)
            leds.append({"hmin": round(hmin, 4), "hmax": round(hmax, 4),
                         "vmin": round(vmin, 4), "vmax": round(vmax, 4)})
    return leds


def normalize(args, hardware_count=None):
    """Turn layout args (counts or marks) into {counts, order, offset, total, start_corner, direction}."""
    start_corner = args.get("start_corner", "bottom_left")
    direction = args.get("direction", "cw")
    order = side_order(start_corner, direction)

    if "marks" in args:
        marks = args["marks"] or {}
        starts = marks.get("starts")
        end = marks.get("end")
        if not isinstance(starts, list) or len(starts) != 4 or not isinstance(end, int):
            raise LayoutError("marks needs 'starts' (4 indexes, one per side in travel order) and 'end' (last LED index)")
        try:
            starts = [int(s) for s in starts]
        except (TypeError, ValueError) as exc:
            raise LayoutError("marks.starts must be integers") from exc
        bounds = starts + [end + 1]
        if starts[0] < 0 or any(b < a for a, b in zip(bounds, bounds[1:])):
            raise LayoutError("marks must increase along the strip (starts[0] <= starts[1] <= ... <= end)")
        counts = {order[i]: bounds[i + 1] - bounds[i] for i in range(4)}
        offset = starts[0]
    elif "counts" in args:
        raw = args["counts"] or {}
        counts = {}
        for side in SIDES:
            value = raw.get(side, 0)
            if not isinstance(value, int) or value < 0:
                raise LayoutError(f"counts.{side} must be a whole number >= 0")
            counts[side] = value
        offset = args.get("offset", 0)
        if not isinstance(offset, int) or offset < 0:
            raise LayoutError("offset must be a whole number >= 0")
    else:
        raise LayoutError("give either 'counts' or 'marks'")

    total = sum(counts.values())
    if total == 0:
        raise LayoutError("layout has no LEDs")
    if hardware_count and offset + total > hardware_count:
        raise LayoutError(f"layout uses {offset + total} LEDs but the strip has {hardware_count}")
    return {"counts": counts, "order": order, "offset": offset, "total": total,
            "start_corner": start_corner, "direction": direction}


def side_ranges(layout):
    """Hardware index ranges per side: list of (side, start, stop_exclusive)."""
    pos = layout["offset"]
    out = []
    for side in layout["order"]:
        n = layout["counts"][side]
        out.append((side, pos, pos + n))
        pos += n
    return out


def suggest(tv_inches, leds_per_m=60, inset_cm=3.0, aspect="16:9"):
    """Install-guide numbers for a TV size."""
    try:
        aw, ah = (float(x) for x in str(aspect).split(":"))
    except ValueError as exc:
        raise LayoutError("aspect must look like '16:9'") from exc
    if not (10 <= float(tv_inches) <= 120):
        raise LayoutError("tv_inches must be between 10 and 120")
    if not (10 <= float(leds_per_m) <= 300):
        raise LayoutError("leds_per_m must be between 10 and 300")
    diag_cm = float(tv_inches) * 2.54
    scale = diag_cm / math.hypot(aw, ah)
    width_cm, height_cm = aw * scale, ah * scale
    run_w = max(width_cm - 2 * inset_cm, 0)
    run_h = max(height_cm - 2 * inset_cm, 0)
    per_cm = leds_per_m / 100.0
    top = bottom = int(run_w * per_cm)
    left = right = int(run_h * per_cm)
    total = top + bottom + left + right
    return {
        "tv": {"inches": tv_inches, "width_cm": round(width_cm, 1), "height_cm": round(height_cm, 1)},
        "inset_cm": inset_cm,
        "leds_per_m": leds_per_m,
        "counts": {"left": left, "top": top, "right": right, "bottom": bottom},
        "total": total,
        "strip_length_m": round(total / leds_per_m, 2),
        "side_length_cm": {"top_bottom": round(run_w, 1), "left_right": round(run_h, 1)},
        # ~60 mA per LED at full white; ~25% is a comfortable real-world cap for ambient light.
        "power": {"max_amps_full_white": round(total * 0.06, 1),
                  "recommended_supply_amps": max(3, math.ceil(total * 0.06 * 0.35)),
                  "recommended_limit_ma": int(total * 0.06 * 0.3 * 1000)},
        "start_corner": "bottom_left",
        "direction": "cw",
    }
