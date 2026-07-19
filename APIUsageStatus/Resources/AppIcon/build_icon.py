#!/usr/bin/env python3
"""APIUsageStatus app icon generator — design "Deep Space Orbit" (深空星轨).

Layers:
  - nebula_bg.jpg: AI-generated deep-space nebula (MiniMax image-01), graded
    darker and pushed toward indigo
  - faint full ring + glowing cyan→violet gradient arc (usage/monitor motif)
  - central 3-node constellation (multi-provider motif carried over from the
    original icon) with halo, ring and star core per node
  - a few 4-point sparkle stars
  - silhouette: full-bleed rounded rect, corner radius 230/1024 (same as the
    original AppIcon.svg design)

Requires: Pillow, numpy (system python3 on macOS is fine).

Usage:
  python3 build_icon.py            # render preview_1024.png + preview_sizes.png here
  python3 build_icon.py --export   # render and write all sizes into the appiconset
"""

import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
BG_PATH = os.path.join(HERE, "nebula_bg.jpg")
APPICONSET = os.path.normpath(
    os.path.join(HERE, "..", "..", "Assets.xcassets", "AppIcon.appiconset")
)

CORNER_RADIUS = 230  # at 1024, per the original AppIcon.svg

EXPORT_SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}

SS = 2                      # supersampling factor
W = 1024 * SS               # working canvas
CX = CY = W / 2.0

CYAN = (94, 234, 212)       # #5EEAD4
ICE = (103, 232, 249)       # #67E8F9
VIOLET = (167, 139, 250)    # #A78BFA
WHITE = (255, 255, 255)

# ---------------------------------------------------------------- helpers


def smoothstep(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def grid():
    yy, xx = np.mgrid[0:W, 0:W].astype(np.float64)
    return xx, yy


def to_img(rgb, alpha):
    """rgb: (W,W,3) float 0..255, alpha: (W,W) float 0..1 -> RGBA image"""
    a = (np.clip(alpha, 0, 1) * 255).astype(np.uint8)
    data = np.dstack([np.clip(rgb, 0, 255).astype(np.uint8), a])
    return Image.fromarray(data, "RGBA")


def radial_field(xx, yy, cx, cy):
    return np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)


def theta_field(xx, yy, cx, cy):
    # degrees, 0 = east, clockwise positive (y axis down)
    return np.degrees(np.arctan2(yy - cy, xx - cx)) % 360.0


def angle_between(theta, start, end):
    """clockwise sweep from start to end (deg); t in [0,1] inside the sweep"""
    sweep = (end - start) % 360.0
    t = (theta - start) % 360.0
    inside = t <= sweep
    return np.where(inside, t / max(sweep, 1e-6), np.nan), inside


def rounded_rect_mask(size):
    s = 4
    m = Image.new("L", (size * s, size * s), 0)
    dr = ImageDraw.Draw(m)
    dr.rounded_rectangle(
        [0, 0, size * s - 1, size * s - 1],
        radius=CORNER_RADIUS / 1024 * size * s,
        fill=255,
    )
    return m.resize((size, size), Image.LANCZOS)


# ---------------------------------------------------------------- background


def build_background():
    bg = Image.open(BG_PATH).convert("RGB").resize((W, W), Image.LANCZOS)
    bg = ImageEnhance.Color(bg).enhance(1.20)
    bg = ImageEnhance.Brightness(bg).enhance(0.72)
    bg = ImageEnhance.Contrast(bg).enhance(1.12)
    arr = np.asarray(bg).astype(np.float64)

    xx, yy = grid()
    r = radial_field(xx, yy, CX, CY) / (W / 2.0)  # 0 center -> ~1 corners

    # deepen edges (vignette)
    vig = 1.0 - 0.55 * smoothstep(0.40, 1.05, r)
    arr *= vig[..., None]

    # indigo grade: push shadows toward deep indigo
    indigo = np.array([10.0, 14.0, 34.0])
    shadow = (1.0 - smoothstep(0.0, 140.0, arr.mean(axis=2)))[..., None]
    arr = arr * (1 - 0.40 * shadow) + indigo * (0.40 * shadow)

    # soft luminous core behind the glyph
    glow_c = np.array([30.0, 66.0, 96.0])
    core = np.exp(-((r * 2.3) ** 2))
    arr += glow_c * (core * 0.22)[..., None]

    # faint top sheen for glassy depth
    sheen = np.clip(1.0 - yy / W, 0, 1) ** 2.2
    arr += np.array([14.0, 18.0, 32.0]) * (sheen * 0.35)[..., None]

    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB").convert("RGBA")


# ---------------------------------------------------------------- glyph pieces


def make_arc_layer(radius, width, start, end, c0, c1, alpha=1.0):
    """gradient arc with round caps, clockwise from start deg to end deg."""
    xx, yy = grid()
    r = radial_field(xx, yy, CX, CY)
    th = theta_field(xx, yy, CX, CY)
    t, inside = angle_between(th, start, end)

    aa = 1.6 * SS
    band = smoothstep(width / 2 + aa, width / 2 - aa, np.abs(r - radius))
    mask = np.where(inside, band, 0.0)

    # round caps
    for ang in (start, end):
        ax = CX + radius * math.cos(math.radians(ang))
        ay = CY + radius * math.sin(math.radians(ang))
        d = radial_field(xx, yy, ax, ay)
        cap = smoothstep(width / 2 + aa, width / 2 - aa, d)
        mask = np.maximum(mask, cap)

    tt = np.nan_to_num(t, nan=0.5)
    rgb = np.zeros((W, W, 3))
    for i in range(3):
        rgb[..., i] = c0[i] + (c1[i] - c0[i]) * tt
    return to_img(rgb, mask * alpha)


def make_ring_layer(radius, width, color, alpha):
    xx, yy = grid()
    r = radial_field(xx, yy, CX, CY)
    aa = 1.4 * SS
    band = smoothstep(width / 2 + aa, width / 2 - aa, np.abs(r - radius))
    rgb = np.zeros((W, W, 3))
    rgb[..., 0], rgb[..., 1], rgb[..., 2] = color
    return to_img(rgb, band * alpha)


def make_segment_layer(p0, p1, width, c0, c1, alpha=1.0):
    """gradient line segment with round caps"""
    xx, yy = grid()
    x0, y0 = p0
    x1, y1 = p1
    dx, dy = x1 - x0, y1 - y0
    L2 = dx * dx + dy * dy
    t = np.clip(((xx - x0) * dx + (yy - y0) * dy) / L2, 0.0, 1.0)
    px = x0 + t * dx
    py = y0 + t * dy
    d = np.sqrt((xx - px) ** 2 + (yy - py) ** 2)
    aa = 1.5 * SS
    mask = smoothstep(width / 2 + aa, width / 2 - aa, d)
    rgb = np.zeros((W, W, 3))
    for i in range(3):
        rgb[..., i] = c0[i] + (c1[i] - c0[i]) * t
    return to_img(rgb, mask * alpha)


def make_disc_layer(cx, cy, radius, color, alpha=1.0, ring_width=None):
    xx, yy = grid()
    d = radial_field(xx, yy, cx, cy)
    aa = 1.5 * SS
    if ring_width is None:
        mask = smoothstep(radius + aa, radius - aa, d)
    else:
        mask = smoothstep(radius + aa, radius - aa, d) * smoothstep(
            radius - ring_width - aa, radius - ring_width + aa, d
        )
    rgb = np.zeros((W, W, 3))
    rgb[..., 0], rgb[..., 1], rgb[..., 2] = color
    return to_img(rgb, mask * alpha)


def make_sparkle(cx, cy, size, color, alpha=1.0):
    """4-point star flare"""
    lay = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    dr = ImageDraw.Draw(lay)
    s = size
    w_core = max(2.0 * SS, s * 0.16)
    dr.polygon(
        [(cx, cy - s), (cx + w_core, cy - w_core), (cx + s, cy), (cx + w_core, cy + w_core),
         (cx, cy + s), (cx - w_core, cy + w_core), (cx - s, cy), (cx - w_core, cy - w_core)],
        fill=color + (int(alpha * 255),),
    )
    lay = lay.filter(ImageFilter.GaussianBlur(0.8 * SS))
    core = make_disc_layer(cx, cy, w_core * 1.1, WHITE, alpha)
    return Image.alpha_composite(lay, core)


def blur_alpha(img, radius, gain=1.0):
    a = img.getchannel("A").filter(ImageFilter.GaussianBlur(radius))
    if gain != 1.0:
        a = a.point(lambda v: min(255, int(v * gain)))
    out = img.copy()
    out.putalpha(a)
    return out


# ---------------------------------------------------------------- compose


def compose():
    bg = build_background()

    emissive = Image.new("RGBA", (W, W), (0, 0, 0, 0))

    # --- orbit system -------------------------------------------------
    R_ORBIT = 372 * SS
    emissive = Image.alpha_composite(
        emissive, make_ring_layer(R_ORBIT, 2.4 * SS, (200, 230, 255), 0.10)
    )
    # gradient arc: cyan at 150° sweeping clockwise over the top to violet at 30°
    emissive = Image.alpha_composite(
        emissive, make_arc_layer(R_ORBIT, 10 * SS, 150, 390, CYAN, VIOLET, 0.98)
    )

    # --- constellation -------------------------------------------------
    R_TRI = 168 * SS
    angles = (-90, 30, 150)  # top, bottom-right, bottom-left
    pts = [
        (CX + R_TRI * math.cos(math.radians(a)), CY + R_TRI * math.sin(math.radians(a)))
        for a in angles
    ]
    node_colors = [VIOLET, ICE, CYAN]

    # soft halo behind the whole constellation
    xx, yy = grid()
    r = radial_field(xx, yy, CX, CY)
    halo = np.exp(-((r / (260 * SS)) ** 2))
    rgb = np.zeros((W, W, 3))
    rgb[..., 0], rgb[..., 1], rgb[..., 2] = 90, 140, 200
    emissive = Image.alpha_composite(emissive, to_img(rgb, halo * 0.16))

    # connecting lines
    for i, j in ((0, 1), (1, 2), (2, 0)):
        seg = make_segment_layer(pts[i], pts[j], 8 * SS, node_colors[i], node_colors[j], 0.95)
        emissive = Image.alpha_composite(emissive, seg)

    # nodes: halo + ring + star core
    for (nx, ny), col in zip(pts, node_colors):
        halo_rgb = np.zeros((W, W, 3))
        halo_rgb[..., 0], halo_rgb[..., 1], halo_rgb[..., 2] = col
        d = radial_field(xx, yy, nx, ny)
        h = np.exp(-((d / (70 * SS)) ** 2))
        emissive = Image.alpha_composite(emissive, to_img(halo_rgb, h * 0.34))

        ring = make_disc_layer(nx, ny, 42 * SS, lerp(col, WHITE, 0.55), 1.0, ring_width=11 * SS)
        emissive = Image.alpha_composite(emissive, ring)
        core = make_disc_layer(nx, ny, 15 * SS, WHITE, 1.0)
        emissive = Image.alpha_composite(emissive, core)

    # --- sparkles -----------------------------------------------------
    for sx, sy, ss_, sa in [
        (CX + 300 * SS, CY - 300 * SS, 13 * SS, 0.8),
        (CX - 330 * SS, CY + 210 * SS, 10 * SS, 0.65),
        (CX - 240 * SS, CY - 330 * SS, 8 * SS, 0.5),
    ]:
        emissive = Image.alpha_composite(
            emissive, make_sparkle(sx, sy, ss_, (220, 240, 255), sa)
        )

    # --- glow passes ---------------------------------------------------
    out = bg
    for radius, gain in ((70 * SS, 0.28), (26 * SS, 0.45), (9 * SS, 0.75)):
        out = Image.alpha_composite(out, blur_alpha(emissive, radius, gain))
    out = Image.alpha_composite(out, emissive)

    return out


def render_master():
    master = compose().resize((1024, 1024), Image.LANCZOS)
    final = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    final.paste(master, (0, 0), rounded_rect_mask(1024))
    return final


def main():
    final = render_master()

    if "--export" in sys.argv:
        for name, px in sorted(EXPORT_SIZES.items(), key=lambda kv: kv[1]):
            img = final.resize((px, px), Image.LANCZOS) if px != 1024 else final
            img.save(os.path.join(APPICONSET, name))
            print(f"{name}: {px}x{px} written")
        return 0

    final.save(os.path.join(HERE, "preview_1024.png"))

    sheet = Image.new("RGBA", (1024, 320), (24, 24, 28, 255))
    x = 24
    for s in (256, 128, 64, 48, 32, 16):
        icon = final.resize((s, s), Image.LANCZOS)
        sheet.paste(icon, (x, (320 - s) // 2), icon)
        x += s + 40
    sheet.save(os.path.join(HERE, "preview_sizes.png"))
    print("wrote preview_1024.png and preview_sizes.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
