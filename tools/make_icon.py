"""Draws the SyncLight launcher icon (an RGB-glowing sync box) and writes Android resources.

Usage: python3 tools/make_icon.py   (writes tools/android_res/ and tools/icon_preview.png)
"""

import colorsys
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "android_res")
BG = (13, 13, 13, 255)
S = 1024  # master size


def rgb_sweep(size, rotate=0.0):
    """Conic RGB gradient image."""
    img = Image.new("RGBA", (size, size))
    px = img.load()
    c = size / 2
    for y in range(size):
        for x in range(size):
            a = (math.atan2(y - c, x - c) / (2 * math.pi) + 0.5 + rotate) % 1.0
            r, g, b = colorsys.hsv_to_rgb(a, 0.85, 1.0)
            px[x, y] = (int(r * 255), int(g * 255), int(b * 255), 255)
    return img


def rounded_mask(size, box, radius, width=None):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    if width:
        d.rounded_rectangle(box, radius=radius, outline=255, width=width)
    else:
        d.rounded_rectangle(box, radius=radius, fill=255)
    return m


def sync_arrows(size, box, width, color=(255, 255, 255, 255)):
    """Two circular arrows (the 'sync' symbol) inside box."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    x0, y0, x1, y1 = box
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    r = (x1 - x0) / 2
    for start, end in ((200, 340), (20, 160)):
        d.arc([cx - r, cy - r, cx + r, cy + r], start=start, end=end, fill=color, width=width)
        # arrowhead at the end of the arc, pointing along the direction of travel
        a = math.radians(end)
        tip = (cx + r * math.cos(a), cy + r * math.sin(a))
        tangent = a + math.pi / 2
        back = a + math.pi / 2 + math.pi
        h = width * 2.1
        p1 = (tip[0] + h * math.cos(tangent), tip[1] + h * math.sin(tangent))
        base = (tip[0] + h * 0.15 * math.cos(back), tip[1] + h * 0.15 * math.sin(back))
        p2 = (base[0] + h * 0.95 * math.cos(a), base[1] + h * 0.95 * math.sin(a))
        p3 = (base[0] - h * 0.95 * math.cos(a), base[1] - h * 0.95 * math.sin(a))
        d.polygon([p1, p2, p3], fill=color)
    return layer


def artwork(size, scale=1.0, background=True):
    """The icon at `size`, artwork scaled by `scale` around the center (for adaptive safe zone)."""
    big = S
    img = Image.new("RGBA", (big, big), BG if background else (0, 0, 0, 0))
    sweep = rgb_sweep(big // 4, rotate=0.1).resize((big, big), Image.BICUBIC)

    m = int(big * (1 - 0.56 * scale) / 2)  # box margin
    box = (m, m, big - m, big - m)
    radius = int(big * 0.13 * scale)
    stroke = max(8, int(big * 0.035 * scale))

    # Soft outer glow from the RGB outline.
    for width, blur in ((stroke * 5, 0.06), (stroke * 2, 0.025)):  # wide soft halo + tighter bloom
        glow_mask = rounded_mask(big, box, radius, width=width).filter(ImageFilter.GaussianBlur(big * blur * scale))
        glow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
        glow.paste(sweep, (0, 0), glow_mask)
        img = Image.alpha_composite(img, glow)

    # Box body.
    body = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle(box, radius=radius, fill=(24, 24, 24, 255))
    img = Image.alpha_composite(img, body)

    # Crisp RGB outline (the LED strip).
    line = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    line.paste(sweep, (0, 0), rounded_mask(big, box, radius, width=stroke))
    img = Image.alpha_composite(img, line)

    # Sync arrows in the middle.
    inner = int((box[2] - box[0]) * 0.27)
    c = big // 2
    arrows = sync_arrows(big, (c - inner, c - inner, c + inner, c + inner), max(6, int(big * 0.03 * scale)))
    img = Image.alpha_composite(img, arrows)

    return img.resize((size, size), Image.LANCZOS)


def legacy_icon(size):
    """Launcher icon for older Android: rounded black tile with the artwork."""
    art = artwork(size * 4, scale=1.0)
    mask = rounded_mask(size * 4, (0, 0, size * 4 - 1, size * 4 - 1), int(size * 4 * 0.22))
    tile = Image.new("RGBA", (size * 4, size * 4), (0, 0, 0, 0))
    tile.paste(art, (0, 0), mask)
    return tile.resize((size, size), Image.LANCZOS)


def main():
    densities = {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2, "xxhdpi": 3, "xxxhdpi": 4}
    for name, f in densities.items():
        d = os.path.join(OUT, f"mipmap-{name}")
        os.makedirs(d, exist_ok=True)
        legacy_icon(int(48 * f)).save(os.path.join(d, "ic_launcher.png"))
        # Adaptive foreground: 108dp canvas, artwork inside the 66dp safe zone.
        artwork(int(108 * f), scale=0.82, background=False).save(os.path.join(d, "ic_launcher_foreground.png"))

    anydpi = os.path.join(OUT, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    with open(os.path.join(anydpi, "ic_launcher.xml"), "w") as fh:
        fh.write('<?xml version="1.0" encoding="utf-8"?>\n'
                 '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                 '    <background android:drawable="@color/ic_launcher_background"/>\n'
                 '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
                 '</adaptive-icon>\n')
    values = os.path.join(OUT, "values")
    os.makedirs(values, exist_ok=True)
    with open(os.path.join(values, "ic_launcher_background.xml"), "w") as fh:
        fh.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
                 '    <color name="ic_launcher_background">#0D0D0D</color>\n</resources>\n')

    preview = Image.new("RGBA", (560, 300), (40, 40, 40, 255))
    legacy = legacy_icon(192)
    preview.paste(legacy, (40, 54), legacy)
    fg = artwork(432, scale=0.82, background=False)
    adaptive = Image.new("RGBA", (432, 432), BG)
    adaptive = Image.alpha_composite(adaptive, fg)
    circle = Image.new("L", (432, 432), 0)
    ImageDraw.Draw(circle).ellipse((0, 0, 431, 431), fill=255)
    round_icon = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    round_icon.paste(adaptive, (0, 0), circle)
    preview.paste(round_icon.resize((216, 216), Image.LANCZOS), (300, 42), round_icon.resize((216, 216), Image.LANCZOS))
    preview.save(os.path.join(HERE, "icon_preview.png"))
    print("icons written to", OUT)


if __name__ == "__main__":
    main()
