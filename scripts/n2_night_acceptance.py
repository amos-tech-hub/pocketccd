#!/usr/bin/env python3
"""N2 night acceptance: the gates from Research/CompetitiveImagingBenchmark.md.

Export the night frames from the app (or copy them out of PocketRoll) into a
folder, then:

    python3 scripts/n2_night_acceptance.py <folder>

Gates for POCKET N2 (night look):
    black<0.04   18–55% of pixels        dense blacks, not a lifted fog
    clip250      0.3–3% of channels      point lights may clip, faces may not
    saturation   0.12–0.30               night is not a colour festival
    R/B          1.15–1.35               white-balance product gate

Exit code is 0 only when every frame passes every gate.
"""
import os
import sys

import numpy as np
from PIL import Image

BLACK = (18.0, 55.0)
CLIP = (0.3, 3.0)
SAT = (0.12, 0.30)
RB = (1.15, 1.35)


def measure(path):
    image = Image.open(path).convert("RGB")
    image.thumbnail((1600, 1600), Image.LANCZOS)
    rgb = np.asarray(image).astype(np.float32) / 255.0
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    high, low = rgb.max(axis=2), rgb.min(axis=2)
    sat = np.where(high > 0, (high - low) / np.maximum(high, 1e-6), 0)
    return {
        "black": float((luma < 0.04).mean() * 100),
        "clip": float((high * 255 >= 250).mean() * 100),
        "sat": float(sat.mean()),
        "rb": float(r.mean() / max(b.mean(), 1e-6)),
        "luma": float(luma.mean()),
    }


def verdict(value, band):
    return band[0] <= value <= band[1]


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else "."
    names = sorted(n for n in os.listdir(folder)
                   if n.upper().endswith((".JPG", ".JPEG", ".PNG")))
    if not names:
        raise SystemExit(f"no images in {folder}")

    all_ok = True
    print(f"{'file':28s}{'luma':>6s}{'black%':>8s}{'clip%':>7s}{'sat':>6s}{'R/B':>6s}   verdict")
    for name in names:
        m = measure(os.path.join(folder, name))
        checks = {
            "black": verdict(m["black"], BLACK),
            "clip": verdict(m["clip"], CLIP),
            "sat": verdict(m["sat"], SAT),
            "rb": verdict(m["rb"], RB),
        }
        failed = [k for k, ok in checks.items() if not ok]
        all_ok &= not failed
        mark = "PASS" if not failed else "fail: " + ", ".join(failed)
        print(f"{name:28s}{m['luma']:6.3f}{m['black']:8.1f}{m['clip']:7.2f}"
              f"{m['sat']:6.3f}{m['rb']:6.2f}   {mark}")

    print()
    print("gates: black<0.04 %.0f–%.0f%% · clip %.1f–%.1f%% · sat %.2f–%.2f · R/B %.2f–%.2f"
          % (*BLACK, *CLIP, *SAT, *RB))
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
