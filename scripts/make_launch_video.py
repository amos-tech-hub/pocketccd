#!/usr/bin/env python3
"""Build the 15s vertical Pocket CCD launch video without Remotion.

Renders frames with Pillow and encodes with ffmpeg. Brand palette is taken from
the app's CameraTheme: paper, ink, accent.
"""
import math
import os
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1080, 1920
FPS = 30
DURATION = 15.0
FRAMES = int(FPS * DURATION)

PAPER = (236, 233, 222)
INK = (19, 20, 18)
CREAM = (240, 238, 230)
ACCENT = (240, 173, 61)

ROOT = "/Users/adam/code/apple/PocketCCD"
FONT = "/System/Library/Fonts/SFNS.ttf"
OUT = "/tmp/pccd_video_frames"


def font(size, weight="Bold"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def ease_out(t):
    return 1 - (1 - t) ** 3


def clamp(v, lo=0.0, hi=1.0):
    return max(lo, min(hi, v))


def load_screen(name, target_w):
    im = Image.open(os.path.join(ROOT, "store/captures/iphone", name)).convert("RGB")
    ratio = target_w / im.width
    return im.resize((target_w, int(im.height * ratio)), Image.LANCZOS)


def grain_layer(seed=7):
    rng = np.random.default_rng(seed)
    return rng.normal(0, 1, (H // 2, W // 2)).astype(np.float32)


GRAIN = grain_layer()


def add_grain(img, amount, offset):
    """Subtle 2003-sensor texture. `amount` is roughly ±levels of noise."""
    g = np.roll(GRAIN, (offset, offset // 2), axis=(0, 1))
    g = (g - g.min()) / (np.ptp(g) + 1e-6)
    up = np.asarray(
        Image.fromarray((g * 255).astype(np.uint8)).resize((W, H), Image.BILINEAR)
    ).astype(np.float32) / 255.0
    a = np.asarray(img).astype(np.float32)
    a = np.clip(a + (up[..., None] - 0.5) * amount * 2, 0, 255)
    return Image.fromarray(a.astype(np.uint8))


def card(screen, width, shadow=18):
    """Screenshot with a thin light frame and a soft shadow."""
    img = load_screen(screen, width)
    pad = 10
    framed = Image.new("RGB", (img.width + pad * 2, img.height + pad * 2), (250, 249, 244))
    framed.paste(img, (pad, pad))
    canvas = Image.new("RGB", (framed.width + shadow * 2, framed.height + shadow * 2), PAPER)
    mask = Image.new("L", framed.size, 255)
    sh = Image.new("L", canvas.size, 0)
    sh.paste(mask, (shadow, shadow + 6))
    sh = sh.filter(ImageFilter.GaussianBlur(shadow * 0.7))
    canvas.paste(Image.new("RGB", canvas.size, (150, 145, 132)), (0, 0), sh)
    canvas.paste(framed, (shadow, shadow))
    return canvas


def draw_text(draw, xy, text, f, fill, anchor="mt", spacing=1.0):
    draw.multiline_text(xy, text, font=f, fill=fill, anchor=anchor, align="center", spacing=40 * spacing)


def scene_a(t, dur=0):
    """It's 2003. Then the flash."""
    img = Image.new("RGB", (W, H), (6, 6, 6))
    d = ImageDraw.Draw(img)
    appear = clamp(t / 0.5)
    y = H // 2 - 40
    draw_text(d, (W / 2, y), "It's 2003.", font(int(150 + 6 * (1 - appear)), "Bold"), CREAM)
    if t > 0.9:
        sub = clamp((t - 0.9) / 0.4)
        draw_text(d, (W / 2, y + 150), "your friends are in a dark room.",
                  font(46, "Medium"), (150, 148, 140))
    return img


def scene_b(t, dur):
    """The result screen: direct flash, not a filter."""
    img = Image.new("RGB", (W, H), PAPER)
    d = ImageDraw.Draw(img)
    p = ease_out(clamp(t / 0.55))
    fade = clamp((dur - t) / 0.35)
    caption_y = 210
    draw_text(d, (W / 2, caption_y), "Direct flash.", font(92, "Bold"), INK)
    draw_text(d, (W / 2, caption_y + 110), "Not a filter.", font(92, "Bold"), (140, 136, 126))
    shot = card("02-result.png", 520)
    y = int(600 + (1 - p) * 120)
    img.paste(shot, ((W - shot.width) // 2, y))
    return img


def scene_c(t, dur):
    """Four cameras, one roll."""
    img = Image.new("RGB", (W, H), PAPER)
    d = ImageDraw.Draw(img)
    p = ease_out(clamp(t / 0.5))
    draw_text(d, (W / 2, 190), "Four cameras.", font(88, "Bold"), INK)
    names = ["A7 Warm 2003", "A8 Party Flash", "C1 Cold Sharp", "N2 Green Grain"]
    for i, n in enumerate(names):
        local = clamp((t - 0.25 - i * 0.16) / 0.3)
        if local <= 0:
            continue
        col = ACCENT if i in (0, 1) else (150, 146, 136)
        draw_text(d, (W / 2, 300 + i * 56), n, font(44, "Semibold"), col)
    shot = card("01-camera.png", 480)
    y = int(730 + (1 - p) * 100)
    img.paste(shot, ((W - shot.width) // 2, y))
    return img


def scene_d(t, dur):
    """End card."""
    img = Image.new("RGB", (W, H), INK)
    d = ImageDraw.Draw(img)
    p = ease_out(clamp(t / 0.5))
    icon_path = os.path.join(ROOT, "Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
    if os.path.exists(icon_path):
        icon = Image.open(icon_path).convert("RGB").resize((200, 200), Image.LANCZOS)
        r = 46
        mask = Image.new("L", (200, 200), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, 199, 199), radius=r, fill=255)
        img.paste(icon, ((W - 200) // 2, 430), mask)
    y = 760 - int((1 - p) * 30)
    draw_text(d, (W / 2, y), "Pocket CCD", font(126, "Bold"), CREAM)
    draw_text(d, (W / 2, y + 150), "Two cameras free.", font(52, "Medium"), (168, 164, 154))
    draw_text(d, (W / 2, y + 215), "$9.99 once. Forever.", font(52, "Medium"), ACCENT)
    draw_text(d, (W / 2, y + 320), "NO SUBSCRIPTION", font(34, "Semibold"), (120, 117, 108))
    if t > 0.6:
        draw_text(d, (W / 2, H - 260), "On the App Store", font(40, "Medium"), (168, 164, 154))
    return img


SCENES = [(0.0, 2.4, scene_a), (2.4, 7.6, scene_b), (7.6, 11.4, scene_c), (11.4, 15.0, scene_d)]


def frame_at(i):
    t = i / FPS
    for start, end, fn in SCENES:
        if start <= t < end:
            img = fn(t - start, end - start)
            # 2-frame white flash on every cut (the shutter)
            for cut in (2.4, 7.6, 11.4):
                dt = t - cut
                if 0 <= dt < 0.09:
                    k = 1 - dt / 0.09
                    img = Image.blend(img, Image.new("RGB", (W, H), (255, 255, 255)), 0.85 * k)
            amount = 7 if start in (0.0, 11.4) else 5
            return add_grain(img, amount, i * 7)
    return Image.new("RGB", (W, H), INK)


def main():
    os.makedirs(OUT, exist_ok=True)
    for i in range(FRAMES):
        frame_at(i).save(os.path.join(OUT, f"f{i:04d}.png"))
        if i % 60 == 0:
            print("frame", i, flush=True)
    print("frames done")


if __name__ == "__main__":
    main()
