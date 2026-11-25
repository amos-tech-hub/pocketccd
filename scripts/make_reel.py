#!/usr/bin/env python3
"""Vertical Reel (1080×1920, 30 fps, ~11 s, no audio) from the A7 daylight set.

Same palette and type as the store screenshots and the 4:5 posts:
cream paper, ink headline, amber accent. Photos are shown whole (no crop),
on a blurred, darkened copy of themselves so the date stamp survives.

Usage:
  python3 scripts/make_reel.py            # render frames + encode
  python3 scripts/make_reel.py --frames   # frames only (for a still check)
"""
import argparse
import os
import shutil
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1080, 1920
FPS = 30
BG_TOP = (233, 227, 213)
BG_BOTTOM = (216, 208, 192)
INK = (24, 25, 22)
SUB = (85, 87, 79)
ACCENT = (176, 118, 30)
CREAM = (247, 244, 236)
WHITE = (255, 255, 255)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
FONT = "/System/Library/Fonts/SFNS.ttf"
ICON = os.path.join(ROOT, "Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
FRAMES_DIR = "/tmp/pccd_reel_frames"

INTRO = 1.2
SCENE = 2.1
OUTRO = 1.6
SHOTS = [
    dict(photo="pictures/IMG_5610.JPG", label="A7 · LAKE · 11:36"),
    dict(photo="pictures/IMG_5616.JPG", label="A7 · PARK · 11:39"),
    dict(photo="pictures/IMG_5653.JPG", label="A7 · KAYAKS · 12:56"),
    dict(photo="pictures/IMG_5697.JPG", label="A7 · BEACH · 14:02"),
]
TOTAL = INTRO + SCENE * len(SHOTS) + OUTRO
FRAMES = int(round(TOTAL * FPS))
CUTS = [INTRO + SCENE * i for i in range(1, len(SHOTS) + 1)]
CUTS.append(INTRO + SCENE * len(SHOTS))


def font(size, weight="Heavy"):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def ease_out(t):
    t = max(0.0, min(1.0, t))
    return 1 - (1 - t) ** 3


def ease_io(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def crop_fill(src, w, h, focus=(0.5, 0.5)):
    sw, sh = src.size
    ratio = w / h
    cw, ch = (sh * ratio, sh) if sw / sh > ratio else (sw, sw / ratio)
    cx, cy = focus[0] * sw, focus[1] * sh
    left = min(max(cx - cw / 2, 0), sw - cw)
    top = min(max(cy - ch / 2, 0), sh - ch)
    return src.crop((int(left), int(top), int(left + cw), int(top + ch)))


def cream_background():
    base = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(base)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)],
               fill=tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)))
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).ellipse([-W * 0.3, -H * 0.5, W * 1.3, H * 0.34], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(int(W * 0.10)))
    return Image.composite(Image.new("RGB", (W, H), ACCENT), base,
                           glow.point(lambda v: int(v * 0.10)))


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1],
                                           radius=radius, fill=255)
    return mask


def build_card(src, max_w, max_h, border=14, radius=26):
    """Whole frame on white paper + baked shadow, at 1.08× for the push-in."""
    zoom = 1.08
    scale = min(max_w / src.width, max_h / src.height) * zoom
    w, h = int(src.width * scale), int(src.height * scale)
    shot = src.resize((w, h), Image.LANCZOS)
    mask = rounded_mask((w, h), radius)
    ow, oh = w + border * 2, h + border * 2
    pad = 70
    card = Image.new("RGBA", (ow + pad * 2, oh + pad * 2), (0, 0, 0, 0))
    shadow = Image.new("RGBA", card.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [pad, pad + 26, pad + ow, pad + oh + 26], radius=radius + border,
        fill=(15, 20, 30, 130))
    card.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(34)))
    frame = Image.new("RGBA", (ow, oh), (255, 255, 255, 255))
    frame.putalpha(rounded_mask((ow, oh), radius + border))
    frame.paste(shot, (border, border), mask)
    card.alpha_composite(frame, (pad, pad))
    return card


def build_backdrop(src):
    bg = crop_fill(src, W, H).resize((W, H), Image.LANCZOS)
    bg = bg.filter(ImageFilter.GaussianBlur(34))
    bg = Image.eval(bg, lambda v: int(v * 0.62))
    veil = Image.new("RGB", (W, H), (12, 14, 12))
    return Image.blend(bg, veil, 0.25)


def zoom_crop(img, zoom, size):
    """zoom 1.0 = full image; >1 crops a centred window and rescales."""
    cw, ch = int(img.width / zoom), int(img.height / zoom)
    left, top = (img.width - cw) // 2, (img.height - ch) // 2
    return img.crop((left, top, left + cw, top + ch)).resize(size, Image.LANCZOS)


def draw_centered(draw, y, text, f, fill, spacing=1.0):
    for line in text.split("\n"):
        w = draw.textlength(line, font=f)
        draw.text(((W - w) / 2, y), line, font=f, fill=fill)
        y += f.size * 1.12 * spacing
    return y


def intro_frame(t):
    # blurred first frame as the ground, cream type on top
    img = BACKDROPS[0].copy()
    img = Image.blend(img, Image.new("RGB", (W, H), (10, 11, 10)), 0.32)
    d = ImageDraw.Draw(img)
    a = ease_out(t / 0.55)
    rise = int((1 - a) * 26)

    d.text((72, 150), "POCKET CCD", font=font(32, "Heavy"), fill=CREAM)
    y = 250 + rise
    for line in ("Four frames.", "One afternoon."):
        f = font(112, "Heavy")
        d.text(((W - d.textlength(line, font=f)) / 2, y), line, font=f, fill=CREAM)
        y += int(112 * 1.12)
    d.rounded_rectangle([W / 2 - 36, y + 24, W / 2 + 36, y + 32], radius=4, fill=ACCENT)

    sub_a = ease_out((t - 0.35) / 0.5)
    if sub_a > 0:
        sub = font(36, "Medium")
        txt = "Straight out of the A7 · 19 Nov 2026"
        col = tuple(int(CREAM[i] * sub_a + (28, 30, 28)[i] * (1 - sub_a)) for i in range(3))
        d.text(((W - d.textlength(txt, font=sub)) / 2, y + 78), txt, font=sub, fill=col)

    # four prints, then the provenance line
    p = ease_out((t - 0.2) / 0.75)
    if p > 0:
        tw, th, gap = 250, 318, 20
        full = tw * 4 + gap * 3
        x0 = (W - full) / 2
        y0 = 1200 + (1 - p) * 160
        for i, shot in enumerate(SHOTS):
            src = Image.open(os.path.join(ROOT, shot["photo"])).convert("RGB")
            tile = crop_fill(src, tw, th, (0.5, 0.5)).resize((tw, th), Image.LANCZOS)
            m = rounded_mask((tw, th), 14)
            img.paste(tile, (int(x0 + i * (tw + gap)), int(y0)), m)
        note = font(30, "Medium")
        txt = "Shot on iPhone 16 Plus · nothing edited after the shot"
        d.text(((W - d.textlength(txt, font=note)) / 2, 1660), txt, font=note,
               fill=(236, 232, 222))
    return img


def scene_frame(idx, t):
    shot = SHOTS[idx]
    src = Image.open(os.path.join(ROOT, shot["photo"])).convert("RGB")
    card = CARDS[idx]
    backdrop = BACKDROPS[idx]

    p = ease_io(t / SCENE)
    bg = zoom_crop(backdrop, 1.0 + 0.05 * p, (W, H))
    img = bg.copy()

    # the print rises, then pushes in slowly
    rise = int((1 - ease_out(t / 0.7)) * 70)
    z = 1.0 + 0.035 * ease_out(t / SCENE)
    cw, ch = int(card.width / z), int(card.height / z)
    left, top = (card.width - cw) // 2, (card.height - ch) // 2
    crop = card.crop((left, top, left + cw, top + ch)).resize((card.width, card.height),
                                                             Image.LANCZOS)
    img.paste(crop, ((W - card.width) // 2, (H - card.height) // 2 + 36 + rise), crop)

    d = ImageDraw.Draw(img)
    kicker = font(30, "Semibold")
    d.text((60, 104), shot["label"], font=kicker, fill=(255, 255, 255),
           stroke_width=2, stroke_fill=(20, 18, 14))
    return img


def outro_frame(t):
    img = cream_background()
    d = ImageDraw.Draw(img)
    a = ease_out(t / 0.6)
    rise = int((1 - a) * 30)
    if os.path.exists(ICON):
        icon = Image.open(ICON).convert("RGB").resize((196, 196), Image.LANCZOS)
        m = rounded_mask((196, 196), 44)
        img.paste(icon, ((W - 196) // 2, 520 + rise), m)
    f1 = font(112, "Heavy")
    txt = "Pocket CCD"
    d.text(((W - d.textlength(txt, font=f1)) / 2, 760 + rise), txt, font=f1, fill=INK)
    f2 = font(44, "Medium")
    txt2 = "Straight out of camera"
    d.text(((W - d.textlength(txt2, font=f2)) / 2, 930 + rise), txt2, font=f2, fill=SUB)
    f3 = font(40, "Semibold")
    txt3 = "Two cameras free · $9.99 once"
    d.text(((W - d.textlength(txt3, font=f3)) / 2, 1040 + rise), txt3, font=f3, fill=ACCENT)
    f5 = font(28, "Semibold")
    txt5 = "NO SUBSCRIPTION"
    d.text(((W - d.textlength(txt5, font=f5)) / 2, 1150 + rise), txt5, font=f5, fill=SUB)
    if t > 0.45:
        f4 = font(34, "Medium")
        txt4 = "On the App Store"
        d.text(((W - d.textlength(txt4, font=f4)) / 2, 1620), txt4, font=f4, fill=SUB)
    return img


GRAIN = None


def grain(img, amount=5, offset=0):
    global GRAIN
    if GRAIN is None:
        rng = np.random.default_rng(11)
        GRAIN = rng.normal(0, 1, (H // 2, W // 2)).astype(np.float32)
    g = np.roll(GRAIN, (offset % (H // 2), (offset // 3) % (W // 2)), axis=(0, 1))
    g = (g - g.min()) / (np.ptp(g) + 1e-6)
    up = np.asarray(Image.fromarray((g * 255).astype(np.uint8)).resize((W, H), Image.BILINEAR))
    up = up.astype(np.float32) / 255.0
    arr = np.asarray(img).astype(np.float32)
    arr = np.clip(arr + (up[..., None] - 0.5) * amount * 2, 0, 255)
    return Image.fromarray(arr.astype(np.uint8))


def frame_at(i):
    t = i / FPS
    if t < INTRO:
        img = intro_frame(t)
    elif t < INTRO + SCENE * len(SHOTS):
        idx = int((t - INTRO) // SCENE)
        img = scene_frame(idx, t - INTRO - idx * SCENE)
    else:
        img = outro_frame(t - INTRO - SCENE * len(SHOTS))
    for cut in CUTS:
        dt = t - cut
        if 0 <= dt < 0.07:
            k = 1 - dt / 0.07
            img = Image.blend(img, Image.new("RGB", (W, H), WHITE), 0.9 * k)
    return grain(img, 5, i * 13)


CARDS = []
BACKDROPS = []


def prepare():
    for shot in SHOTS:
        src = Image.open(os.path.join(ROOT, shot["photo"])).convert("RGB")
        CARDS.append(build_card(src, 900, 1040))
        BACKDROPS.append(build_backdrop(src))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", action="store_true", help="only write frames")
    ap.add_argument("--out", default=os.path.join("store", "social", "2026-11-19",
                                                  "reel-pocketccd-11s.mp4"))
    args = ap.parse_args()

    prepare()
    shutil.rmtree(FRAMES_DIR, ignore_errors=True)
    os.makedirs(FRAMES_DIR, exist_ok=True)
    for i in range(FRAMES):
        frame_at(i).save(os.path.join(FRAMES_DIR, "f%04d.png" % i))
        if i % 60 == 0:
            print("frame", i, "/", FRAMES, flush=True)

    cover = frame_at(int(INTRO * FPS) - 4)
    cover_path = os.path.join(ROOT, os.path.dirname(args.out), "reel-cover.jpg")
    cover.save(cover_path, quality=92, optimize=True, subsampling=0)
    print("✓", os.path.relpath(cover_path, ROOT))

    if args.frames:
        print("frames →", FRAMES_DIR)
        return

    out = os.path.join(ROOT, args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS),
        "-i", os.path.join(FRAMES_DIR, "f%04d.png"),
        "-c:v", "libx264", "-preset", "slow", "-crf", "19",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", out,
    ], check=True)
    print("✓", os.path.relpath(out, ROOT))


if __name__ == "__main__":
    main()
