#!/usr/bin/env python3
"""PocketCCD brand v3 generator.

Source of truth: `pocketCCD_logo.png` at the repo root. The letterforms are
traced with potrace into flat two-colour vector paths; the app icon stacks the
whole wordmark (Pocket / CCD) so it still reads inside a square.

Requires: pillow, numpy, and `potrace` on PATH.
Usage:    python3 scripts/generate_logo_v3.py
Outputs:  brand/v3/vector/wordmark-*.svg, brand/v3/vector/icon.svg
"""
from __future__ import annotations

import os
import re
import subprocess

import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "pocketCCD_logo.png")
OUT = os.path.join(ROOT, "brand", "v3")
VEC = os.path.join(OUT, "vector")
CREAM = "#F2ECE2"
AMBER = "#F0AD3D"
BG = "#0B0C0A"
PAPER = "#ECE8DD"
INK = "#181916"
TRANSFORM = "translate(0,1370) scale(0.1,-0.1)"


def masks() -> tuple[np.ndarray, np.ndarray]:
    src = Image.open(SOURCE).convert("RGB").crop((0, 0, 1536, 1370))
    a = np.asarray(src).astype(np.int16)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    cream = (r > 225) & (g > 215) & (b > 200)
    amber = (r > 150) & (r < 230) & (g > 85) & (g < 160) & (b < 110)

    def clean(mask: np.ndarray) -> np.ndarray:
        im = Image.fromarray((mask * 255).astype(np.uint8))
        im = (im.filter(ImageFilter.MedianFilter(3))
                .filter(ImageFilter.MaxFilter(3))
                .filter(ImageFilter.MinFilter(3)))
        return np.asarray(im) > 128

    return clean(cream), clean(amber)


def trace(mask: np.ndarray, name: str) -> list[str]:
    os.makedirs(VEC, exist_ok=True)
    pbm = os.path.join(VEC, f"{name}.pbm")
    svg = os.path.join(VEC, f"{name}.svg")
    Image.fromarray((~mask * 255).astype(np.uint8)).convert("1").save(pbm)
    subprocess.run(
        ["potrace", "-s", "-o", svg, "--turdsize", "2", "--alphamax", "1.0",
         "--opttolerance", "0.3", pbm],
        check=True,
    )
    return re.findall(r'<path d="(.*?)"', open(svg, encoding="utf-8").read(), re.S)


def main() -> None:
    cream_mask, amber_mask = masks()
    cream = trace(cream_mask, "cream")
    amber = trace(amber_mask, "amber")

    def wordmark(fill: str, background: str | None, name: str) -> None:
        rect = f'<rect width="1536" height="1370" fill="{background}"/>' if background else ""
        body = "".join(f'<path d="{p}"/>' for p in cream)
        acc = "".join(f'<path d="{p}"/>' for p in amber)
        svg = (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="148 512 1234 459" '
            f'width="1234" height="459">{rect}'
            f'<g transform="{TRANSFORM}" fill="{fill}">{body}</g>'
            f'<g transform="{TRANSFORM}" fill="{AMBER}">{acc}</g></svg>'
        )
        open(os.path.join(VEC, name), "w", encoding="utf-8").write(svg)

    wordmark(CREAM, None, "wordmark-dark.svg")
    wordmark(INK, None, "wordmark-light.svg")
    wordmark(CREAM, BG, "wordmark-dark-bg.svg")
    wordmark(INK, PAPER, "wordmark-light-bg.svg")

    # Square icon: stack "Pocket" over "CCD" so every word of the name is present.
    ys, xs = np.where(cream_mask)
    pocket = (xs.min(), xs.max(), ys.min(), ys.max())
    ys, xs = np.where(amber_mask)
    ccd = (xs.min(), xs.max(), ys.min(), ys.max())

    def fit(target_width: float, bounds) -> tuple[float, float, float]:
        width = bounds[1] - bounds[0]
        height = bounds[3] - bounds[2]
        scale = target_width / width
        return scale, scale * height, width

    s1, h1, w1 = fit(820, pocket)
    s2, h2, w2 = fit(340, ccd)
    gap = 56
    top = (1024 - (h1 + gap + h2)) / 2
    t1 = (f"translate({(1024 - s1 * w1) / 2 - s1 * pocket[0]:.2f},"
          f"{top - s1 * pocket[2]:.2f}) scale({s1:.4f})")
    t2 = (f"translate({(1024 - s2 * w2) / 2 - s2 * ccd[0]:.2f},"
          f"{top + h1 + gap - s2 * ccd[2]:.2f}) scale({s2:.4f})")
    body = "".join(f'<path d="{p}"/>' for p in cream)
    acc = "".join(f'<path d="{p}"/>' for p in amber)
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" '
        f'width="1024" height="1024"><rect width="1024" height="1024" fill="{BG}"/>'
        f'<g transform="{t1}"><g transform="{TRANSFORM}" fill="{CREAM}">{body}</g></g>'
        f'<g transform="{t2}"><g transform="{TRANSFORM}" fill="{AMBER}">{acc}</g></g></svg>'
    )
    open(os.path.join(VEC, "icon.svg"), "w", encoding="utf-8").write(svg)
    print("wrote brand/v3/vector/wordmark-*.svg and icon.svg")


if __name__ == "__main__":
    main()
