#!/usr/bin/env python3
"""Four 4:5 social posts from the 2026-11-19 A7 daylight set.

1080×1350, RGB, no alpha. Same palette and type as the store screenshot
pipeline (store/copy-deck.json) so the campaign reads as one system.

Usage:
  python3 scripts/make_social_posts.py [--out store/social/2026-11-19/posts]
"""
import argparse
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1080, 1350
BG_TOP = (233, 227, 213)      # copy-deck bg_top
BG_BOTTOM = (216, 208, 192)   # copy-deck bg_bottom
INK = (24, 25, 22)            # copy-deck ink
SUB = (85, 87, 79)            # copy-deck sub
ACCENT = (176, 118, 30)       # copy-deck accent
PAPER_WHITE = (252, 251, 247)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FONT = "/System/Library/Fonts/SFNS.ttf"
ICON = os.path.join(ROOT, "Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")

POSTS = [
    dict(
        photo="pictures/IMG_5610.JPG", look="A7", scene="LAKE", time="11:36",
        headline="Quiet water,\nhonest colour.", focus=(0.46, 0.52),
    ),
    dict(
        photo="pictures/IMG_5616.JPG", look="A7", scene="PARK", time="11:39",
        headline="A Sunday\nthat stayed.", focus=(0.45, 0.56),
    ),
    dict(
        photo="pictures/IMG_5653.JPG", look="A7", scene="KAYAKS", time="12:56",
        headline="Colour the CCD\ncan keep.", focus=(0.50, 0.55),
    ),
    dict(
        photo="pictures/IMG_5697.JPG", look="A7", scene="BEACH", time="14:02",
        headline="Salt air,\n2003.", focus=(0.50, 0.46),
    ),
]


def font(size, weight="Heavy"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def background():
    base = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(base)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)],
               fill=tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)))
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).ellipse([-W * 0.3, -H * 0.55, W * 1.3, H * 0.30], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(int(W * 0.09)))
    return Image.composite(Image.new("RGB", (W, H), ACCENT), base,
                           glow.point(lambda v: int(v * 0.10)))


def crop_fill(src, box_w, box_h, focus):
    sw, sh = src.size
    ratio = box_w / box_h
    cw, ch = (sh * ratio, sh) if sw / sh > ratio else (sw, sw / ratio)
    cx, cy = focus[0] * sw, focus[1] * sh
    left = min(max(cx - cw / 2, 0), sw - cw)
    top = min(max(cy - ch / 2, 0), sh - ch)
    return src.crop((int(left), int(top), int(left + cw), int(top + ch)))


def photo_card(src, max_w, max_h, border=10, radius=20):
    """Whole frame, no crop: the in-app date stamp stays intact."""
    scale = min(max_w / src.width, max_h / src.height)
    w, h = int(src.width * scale), int(src.height * scale)
    shot = src.resize((w, h), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=255)
    ow, oh = w + border * 2, h + border * 2
    frame = Image.new("RGBA", (ow, oh), (255, 255, 255, 255))
    outer = Image.new("L", (ow, oh), 0)
    ImageDraw.Draw(outer).rounded_rectangle([0, 0, ow - 1, oh - 1],
                                            radius=radius + border, fill=255)
    frame.putalpha(outer)
    frame.paste(shot, (border, border), mask)
    return frame


def compose(post):
    img = background()
    d = ImageDraw.Draw(img)

    # meta line
    d.text((72, 64), f"{post['look']} · {post['scene']} · {post['time']}",
           font=font(28, "Semibold"), fill=SUB)
    name_font = font(28, "Heavy")
    name = "POCKET CCD"
    d.text((W - 72 - d.textlength(name, font=name_font), 64), name,
           font=name_font, fill=INK)

    # headline
    head = font(84, "Heavy")
    y = 150
    for line in post["headline"].split("\n"):
        d.text((72, y), line, font=head, fill=INK)
        y += int(84 * 1.14)

    # accent rule
    d.rounded_rectangle([72, y + 18, 72 + 64, y + 24], radius=3, fill=ACCENT)

    # photo — whole frame, vertically centred in the space under the rule
    top_min = y + 76
    bottom = H - 56
    card = photo_card(Image.open(os.path.join(ROOT, post["photo"])).convert("RGB"),
                      936, bottom - top_min)
    top = top_min + (bottom - top_min - card.height) // 2
    shadow = Image.new("RGBA", (card.width + 160, card.height + 160), (0, 0, 0, 0))
    pad = 80
    ImageDraw.Draw(shadow).rounded_rectangle(
        [pad, pad + 14, pad + card.width, pad + card.height + 14],
        radius=32, fill=(30, 40, 55, 70))
    shadow = shadow.filter(ImageFilter.GaussianBlur(26))
    x = (W - card.width) // 2
    img.paste(shadow, (x - pad, top - pad), shadow)
    img.paste(card, (x, top), card)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join("store", "social", "2026-11-19", "posts"))
    args = ap.parse_args()
    out = os.path.join(ROOT, args.out)
    os.makedirs(out, exist_ok=True)
    for i, post in enumerate(POSTS, 1):
        name = "%02d-%s-%s.jpg" % (i, post["scene"].lower(), post["time"].replace(":", ""))
        path = os.path.join(out, name)
        img = compose(post)
        img.save(path, quality=94, optimize=True, subsampling=0)
        print("✓", os.path.relpath(path, ROOT), img.size)


if __name__ == "__main__":
    main()
