#!/usr/bin/env python3
"""PocketCCD logo / app icon generator.

Brand contract lives in .tastemaker/style-lock.md:
  black ground, warm amber accent #F0AD3D, warm off-white ink #E6E6E0,
  hairline borders, flat fills, no gradients or glass.

Usage:  python3 scripts/generate_logo.py [--concepts-only]
"""

from __future__ import annotations

import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

S = 4  # supersample factor
BASE = 1024

INK = (230, 230, 224)
INK_DIM = (148, 148, 148)
AMBER = (240, 173, 61)
AMBER_DEEP = (176, 118, 30)
RED = (235, 59, 46)
BG = (11, 12, 10)
PANEL = (19, 20, 18)
GLASS = (7, 8, 6)

MONO = "/System/Library/Fonts/SFNSMono.ttf"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "brand")
ASSETS = os.path.join(ROOT, "Assets.xcassets")
ICONSET = os.path.join(ASSETS, "AppIcon.appiconset")


def canvas(size=BASE, color=BG) -> Image.Image:
    img = Image.new("RGB", (size * S, size * S), color)
    return img


def down(img: Image.Image, size=BASE) -> Image.Image:
    return img.resize((size, size), Image.LANCZOS)


def sc(*vals):
    return [v * S for v in vals]


def line(d: ImageDraw.ImageDraw, pts, width, fill):
    d.line([(x * S, y * S) for x, y in pts], fill=fill, width=int(width * S), joint="curve")


def ellipse(d, box, fill=None, outline=None, width=0):
    d.ellipse([c * S for c in box], fill=fill, outline=outline, width=int(width * S))


def rect(d, box, fill=None, outline=None, width=0, radius=0):
    b = [c * S for c in box]
    if radius:
        d.rounded_rectangle(b, radius=radius * S, fill=fill, outline=outline, width=int(width * S))
    else:
        d.rectangle(b, fill=fill, outline=outline, width=int(width * S))


def bracket_frame(d, inset=150, arm=196, width=15, fill=INK):
    """Four corner brackets: the viewfinder motif."""
    x0, y0, x1, y1 = inset, inset, BASE - inset, BASE - inset
    for (cx, cy, sx, sy) in ((x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)):
        line(d, [(cx, cy + sy * arm), (cx, cy), (cx + sx * arm, cy)], width, fill)


# --------------------------------------------------------------------------- #
# Concept A - viewfinder lens
# --------------------------------------------------------------------------- #
def concept_a(bg=BG):
    img = canvas(color=bg)
    d = ImageDraw.Draw(img)
    bracket_frame(d, inset=146, arm=188, width=15)

    cx = cy = 512
    # lens barrel
    ellipse(d, [cx - 244, cy - 244, cx + 244, cy + 244], outline=AMBER, width=38)
    # glass
    ellipse(d, [cx - 206, cy - 206, cx + 206, cy + 206], fill=GLASS)
    # inner hairline ring
    ellipse(d, [cx - 150, cy - 150, cx + 150, cy + 150], outline=AMBER_DEEP, width=9)
    # iris
    ellipse(d, [cx - 48, cy - 48, cx + 48, cy + 48], fill=AMBER)
    # flat specular glint, upper left
    bbox = [cx - 178, cy - 178, cx + 178, cy + 178]
    d.arc([c * S for c in bbox], start=196, end=252, fill=INK, width=int(12 * S))
    # status LED
    ellipse(d, [836, 176, 868, 208], fill=RED)
    return img


# --------------------------------------------------------------------------- #
# Concept B - six blade aperture
# --------------------------------------------------------------------------- #
def hexagon(cx, cy, r, rot=0.0):
    return [
        (cx + r * math.cos(math.radians(rot + i * 60)),
         cy + r * math.sin(math.radians(rot + i * 60)))
        for i in range(6)
    ]


def concept_b(bg=BG):
    img = canvas(color=bg)
    d = ImageDraw.Draw(img)
    cx = cy = 512
    outer = hexagon(cx, cy, 318, rot=-90)
    inner = hexagon(cx, cy, 128, rot=-60)

    # amber body with a hexagonal throat
    mask = Image.new("L", img.size, 0)
    md = ImageDraw.Draw(mask)
    md.polygon([(x * S, y * S) for x, y in outer], fill=255)
    md.polygon([(x * S, y * S) for x, y in inner], fill=0)
    img.paste(Image.new("RGB", img.size, AMBER), (0, 0), mask)

    # blade seams
    for i in range(6):
        line(d, [inner[i], outer[i]], 7, BG)
    # blade hinge ticks outside the body
    for i in range(6):
        a = math.radians(-90 + i * 60 + 30)
        p0 = (cx + 342 * math.cos(a), cy + 342 * math.sin(a))
        p1 = (cx + 372 * math.cos(a), cy + 372 * math.sin(a))
        line(d, [p0, p1], 8, INK_DIM)
    return img


# --------------------------------------------------------------------------- #
# Concept C - pocket camera body
# --------------------------------------------------------------------------- #
def concept_c(bg=BG):
    img = canvas(color=bg)
    d = ImageDraw.Draw(img)
    # body
    rect(d, [132, 262, 892, 762], fill=PANEL, outline=INK, width=9, radius=18)
    # top plate
    line(d, [(141, 344), (883, 344)], 8, (52, 54, 50))
    ellipse(d, [180, 288, 212, 320], fill=RED)
    rect(d, [246, 288, 372, 318], fill=(58, 60, 56), radius=3)
    # lens
    cx, cy = 512, 566
    ellipse(d, [cx - 176, cy - 176, cx + 176, cy + 176], outline=AMBER, width=26)
    ellipse(d, [cx - 150, cy - 150, cx + 150, cy + 150], fill=GLASS)
    ellipse(d, [cx - 92, cy - 92, cx + 92, cy + 92], outline=AMBER_DEEP, width=8)
    ellipse(d, [cx - 34, cy - 34, cx + 34, cy + 34], fill=AMBER)
    d.arc([(cx - 130) * S, (cy - 130) * S, (cx + 130) * S, (cy + 130) * S],
          start=200, end=250, fill=INK, width=int(9 * S))
    # mono hardware label
    f = ImageFont.truetype(MONO, 34 * S)
    f.set_variation_by_axes([600])
    d.text((838, 300), "CCD", font=f, fill=INK_DIM, anchor="rm")
    return img


# --------------------------------------------------------------------------- #
# Concept D - sensor grid with lens
# --------------------------------------------------------------------------- #
def concept_d(bg=BG):
    img = canvas(color=bg)
    d = ImageDraw.Draw(img)
    cell, gap = 150, 34
    span = cell * 3 + gap * 2
    x0 = (BASE - span) / 2
    y0 = (BASE - span) / 2
    for r in range(3):
        for c in range(3):
            x = x0 + c * (cell + gap)
            y = y0 + r * (cell + gap)
            if (r, c) == (1, 1):
                rect(d, [x, y, x + cell, y + cell], fill=AMBER, radius=6)
            else:
                rect(d, [x, y, x + cell, y + cell], outline=(70, 72, 66), width=9, radius=6)
    return img


CONCEPTS = {"A": concept_a, "B": concept_b, "C": concept_c, "D": concept_d}


def contact_sheet(path):
    pad, tile = 40, 400
    img = Image.new("RGB", (pad + (tile + pad) * 4, tile + pad * 2 + 46), (5, 5, 5))
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(MONO, 24)
    f.set_variation_by_axes([500])
    for i, (name, fn) in enumerate(CONCEPTS.items()):
        tile_img = down(fn(), tile)
        x = pad + i * (tile + pad)
        img.paste(tile_img, (x, pad))
        d.text((x, pad + tile + 12), f"{name}", font=f, fill=INK)
    img.save(path)


# --------------------------------------------------------------------------- #
# Final mark
# --------------------------------------------------------------------------- #
def draw_mark(img, ox=0, oy=0, size=1024, glass=GLASS, brackets=True, ring_w=40, ink=INK):
    """The PocketCCD mark: viewfinder brackets around an amber CCD lens."""
    d = ImageDraw.Draw(img)
    k = size / 1024.0
    X = lambda v: (ox + v * k) * S
    Y = lambda v: (oy + v * k) * S
    W = lambda v: int(v * k * S)

    cx = cy = 512
    if brackets:
        inset, arm = 132, 212
        for (px, py, sx, sy) in ((inset, inset, 1, 1), (1024 - inset, inset, -1, 1),
                                 (inset, 1024 - inset, 1, -1), (1024 - inset, 1024 - inset, -1, -1)):
            d.line([(X(px), Y(py + sy * arm)), (X(px), Y(py)), (X(px + sx * arm), Y(py))],
                   fill=ink, width=W(24), joint="curve")

    d.ellipse([X(cx - 250), Y(cy - 250), X(cx + 250), Y(cy + 250)], outline=AMBER, width=W(ring_w))
    d.ellipse([X(cx - 210), Y(cy - 210), X(cx + 210), Y(cy + 210)], fill=glass)
    d.ellipse([X(cx - 158), Y(cy - 158), X(cx + 158), Y(cy + 158)], outline=AMBER_DEEP, width=W(8))
    pts = [(cx + 60 * math.cos(math.radians(-90 + i * 60)),
            cy + 60 * math.sin(math.radians(-90 + i * 60))) for i in range(6)]
    d.polygon([(X(x), Y(y)) for x, y in pts], fill=AMBER)


def render_icon(size=1024, bg=BG):
    img = canvas(color=bg)
    draw_mark(img, size=1024)
    return down(img, size)


def squircle_mask(size, n=5.0):
    m = Image.new("L", (size * S, size * S), 0)
    d = ImageDraw.Draw(m)
    a = size * S / 2
    pts = []
    for i in range(720):
        t = 2 * math.pi * i / 720
        ct, st = math.cos(t), math.sin(t)
        x = math.copysign(abs(ct) ** (2 / n), ct) * a + a
        y = math.copysign(abs(st) ** (2 / n), st) * a + a
        pts.append((x, y))
    d.polygon(pts, fill=255)
    return m


def rounded_preview(size=1024, bg=BG, plate=(46, 47, 42)):
    """Icon masked into an iOS squircle, presented on a neutral plate."""
    icon = render_icon(BASE, bg)
    pad = int(BASE * 0.14)
    inner = BASE - pad * 2
    small = icon.resize((inner, inner), Image.LANCZOS)
    m = squircle_mask(inner).resize((inner, inner), Image.LANCZOS)
    out = Image.new("RGB", (BASE, BASE), plate)
    out.paste(small, (pad, pad), m)
    return down(out, size)


# --------------------------------------------------------------------------- #
# Wordmark + lockup
# --------------------------------------------------------------------------- #
def font(size, weight=600):
    f = ImageFont.truetype(MONO, size)
    f.set_variation_by_axes([weight])
    return f


def tracked(d, x, baseline, text, f, fill, tracking):
    for ch in text:
        d.text((x, baseline), ch, font=f, fill=fill, anchor="ls")
        x += f.getlength(ch) + tracking
    return x - tracking


def build_lockup(path, dark=True):
    bg = BG if dark else (255, 255, 255)
    ink = INK if dark else (24, 25, 22)
    amber = AMBER if dark else (186, 122, 18)
    W, H = 3200, 900
    img = Image.new("RGB", (W * S, H * S), bg)
    d = ImageDraw.Draw(img)

    mark_h = 528
    mark_y = (H - mark_h) // 2
    draw_mark(img, ox=80, oy=mark_y, size=mark_h,
              glass=GLASS if dark else (18, 19, 17), ink=ink)

    f = font(248 * S, 600)
    track = 248 * S * 0.03
    bbox_p = f.getbbox("P")
    cap = bbox_p[3] - bbox_p[1]
    baseline = (mark_y + mark_h / 2) * S + cap * 0.36
    x = (80 + mark_h + 92) * S
    x1 = tracked(d, x, baseline, "Pocket", f, ink, track)
    tracked(d, x1 + track * 3.2, baseline, "CCD", f, amber, track)

    import numpy as np
    arr = np.asarray(img)
    mask = np.any(arr != np.array(bg, dtype=arr.dtype), axis=2)
    ys, xs = np.where(mask)
    bbox = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
    pad = 56 * S
    crop = img.crop((max(0, bbox[0] - pad), max(0, bbox[1] - pad),
                     min(W * S, bbox[2] + pad), min(H * S, bbox[3] + pad)))
    out = crop.resize((max(1, round(crop.width / S)), max(1, round(crop.height / S))), Image.LANCZOS)
    out.save(path, optimize=True)
    print("lockup", path, out.size)


def size_ladder(path):
    sizes = [180, 120, 87, 60, 40]
    icon = render_icon(BASE)
    total_w = sum(sizes) + 70 * (len(sizes) - 1) + 160
    H = 300
    img = Image.new("RGB", (total_w, H), (24, 25, 22))
    d = ImageDraw.Draw(img)
    f = font(22, 500)
    x = 80
    for s in sizes:
        ico = icon.resize((s, s), Image.LANCZOS)
        m = squircle_mask(s).resize((s, s), Image.LANCZOS)
        y = 70
        img.paste(ico, (x, y), m)
        d.text((x, y + s + 26), f"{s}px", font=f, fill=INK_DIM, anchor="ls")
        x += s + 70
    d.text((total_w - 60, H - 40), "PocketCCD icon / size check", font=font(20, 500),
           fill=INK_DIM, anchor="rs")
    img.save(path, optimize=True)


def build_all():
    os.makedirs(OUT, exist_ok=True)
    icon = render_icon(BASE)
    from PIL import ImageCms
    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
    icon.save(os.path.join(OUT, "PocketCCD-Icon-1024.png"), optimize=True, icc_profile=srgb)

    for s in (180, 120, 87, 60, 40):
        icon.resize((s, s), Image.LANCZOS).save(os.path.join(OUT, f"PocketCCD-Icon-{s}.png"), optimize=True)

    rounded_preview(BASE).save(os.path.join(OUT, "PocketCCD-Icon-Rounded.png"), optimize=True)
    size_ladder(os.path.join(OUT, "PocketCCD-Icon-Sizes.png"))

    # transparent marks for other surfaces (dark and light variants)
    for name, bracket_ink in (("PocketCCD-Mark.png", INK), ("PocketCCD-Mark-Light.png", (24, 25, 22))):
        mark = Image.new("RGBA", (BASE * S, BASE * S), (0, 0, 0, 0))
        draw_mark(mark, size=BASE, glass=(11, 12, 10, 255), ink=bracket_ink)
        mark.resize((BASE, BASE), Image.LANCZOS).save(os.path.join(OUT, name), optimize=True)

    build_lockup(os.path.join(OUT, "PocketCCD-Lockup-Dark.png"), dark=True)
    build_lockup(os.path.join(OUT, "PocketCCD-Lockup-Light.png"), dark=False)

    # Xcode asset catalog (source of truth for the built app)
    os.makedirs(ICONSET, exist_ok=True)
    icon.save(os.path.join(ICONSET, "AppIcon-1024.png"), optimize=True, icc_profile=srgb)
    with open(os.path.join(ICONSET, "Contents.json"), "w") as fh:
        fh.write('{\n  "images" : [\n    {\n      "filename" : "AppIcon-1024.png",\n'
                 '      "idiom" : "universal",\n      "platform" : "ios",\n'
                 '      "size" : "1024x1024"\n    }\n  ],\n'
                 '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    with open(os.path.join(ASSETS, "Contents.json"), "w") as fh:
        fh.write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
    print("brand assets written to", OUT)


if __name__ == "__main__":
    if "--explore" in sys.argv:
        exp = os.path.join(OUT, "explorations")
        os.makedirs(exp, exist_ok=True)
        contact_sheet(os.path.join(exp, "concepts.png"))
        variant_sheet(os.path.join(exp, "refinements.png"))
        print("exploration sheets written")
    else:
        build_all()
