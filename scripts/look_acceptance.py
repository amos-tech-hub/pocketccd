#!/usr/bin/env python3
"""Acceptance gates for the four cameras, run on exported frames.

    python3 scripts/look_acceptance.py pictures \
        --labels labels.json \
        --faces faces.json          # optional, from Research/face_probe.swift

`labels.json` is {"IMG_5616.JPG": "C1", ...}; build it from the film roll
manifest (see docs/SAMPLE_QUALITY_REVIEW_2026-11-19.md §1) — the app does not
write the look into EXIF. Without labels the script only reports numbers.

Gates come from Research/CompetitiveImagingBenchmark.md plus the post-launch
targets in docs/LOOK_TUNING_2026-11-19.md:

    A7  clip 0.5–2.5%  sat 0.24–0.42   skin R/G 1.15–1.35 (if faces given)
    C1  clip < 2%      sat 0.20–0.36   skin R/G 1.15–1.50
    A8  blk4 < 6%      clip < 4%       (no published band; daylight goal)
    N2  blk4 18–55%    clip 0.3–3%     sat 0.12–0.30   neutral R/B 1.15–1.35

Exit code 0 only when every labelled frame passes every gate for its look.
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

GATES = {
    "A7": {"clip": (0.5, 2.5), "sat": (0.24, 0.42), "skin": (1.15, 1.35)},
    "A8": {"clip": (None, 4.0), "blk4": (None, 6.0)},
    "C1": {"clip": (None, 2.0), "sat": (0.20, 0.36), "skin": (1.15, 1.50)},
    "N2": {"blk4": (18.0, 55.0), "clip": (0.3, 3.0), "sat": (0.12, 0.30),
           "neutral_rb": (1.15, 1.35)},
}


def measure(path):
    image = Image.open(path).convert("RGB")
    image.thumbnail((1600, 1600), Image.LANCZOS)
    rgb = np.asarray(image).astype(np.float32) / 255.0
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    high, low = rgb.max(axis=2), rgb.min(axis=2)
    sat = np.where(high > 0, (high - low) / np.maximum(high, 1e-6), 0)
    neutral = (sat < 0.10) & (luma > 0.18) & (luma < 0.85)
    top = slice(0, int(rgb.shape[0] * 0.25))
    sky = (b[top] > r[top] + 0.05) & (luma[top] > 0.35)
    return {
        "luma": float(luma.mean()),
        "clip": float((high * 255 >= 250).mean() * 100),
        "blk4": float((luma < 0.04).mean() * 100),
        "sat": float(sat.mean()),
        "neutral_rb": (float(r[neutral].mean() / max(b[neutral].mean(), 1e-6))
                       if neutral.sum() > 2000 else float("nan")),
        "sky_gb": (float(g[top][sky].mean() / max(b[top][sky].mean(), 1e-6))
                   if sky.sum() > 1000 else float("nan")),
    }


def check(value, band):
    low, high = band
    if value != value:  # NaN: no neutral patch / no sky
        return True
    return (low is None or value >= low) and (high is None or value <= high)


def skin_ratios(faces_path):
    """{file: R/G} from Research/face_probe.swift output."""
    if not faces_path:
        return {}
    with open(faces_path, encoding="utf-8") as fh:
        faces = json.load(fh)
    ratios = {}
    for face in faces:
        ratio = face["r"] / max(face["g"], 1e-6)
        ratios[face["file"]] = max(ratios.get(face["file"], 0), ratio)
    return ratios


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument("--labels", help='JSON {"IMG_5616.JPG": "C1"}')
    ap.add_argument("--faces", help="JSON from Research/face_probe.swift")
    args = ap.parse_args()

    labels = {}
    if args.labels:
        with open(args.labels, encoding="utf-8") as fh:
            labels = json.load(fh)
    skins = skin_ratios(args.faces)

    names = sorted(n for n in os.listdir(args.folder)
                   if n.upper().endswith((".JPG", ".JPEG", ".PNG")))
    if not names:
        raise SystemExit(f"no images in {args.folder}")

    failures = 0
    print(f"{'file':16s}{'look':5s}{'luma':>6s}{'clip%':>7s}{'blk4%':>7s}"
          f"{'sat':>6s}{'neuR/B':>7s}{'skinR/G':>8s}   verdict")
    for name in names:
        look = labels.get(name, "?")
        m = measure(os.path.join(args.folder, name))
        skin = skins.get(name, float("nan"))
        failed = []
        if look in GATES:
            for key, band in GATES[look].items():
                value = skin if key == "skin" else m.get(key, float("nan"))
                if key == "skin" and value != value:
                    continue  # no face in this frame
                if not check(value, band):
                    failed.append(key)
        failures += 1 if failed else 0
        print(f"{name:16s}{look:5s}{m['luma']:6.3f}{m['clip']:7.2f}{m['blk4']:7.1f}"
              f"{m['sat']:6.3f}{m['neutral_rb']:7.2f}{skin:8.2f}   "
              f"{'PASS' if not failed else 'fail: ' + ', '.join(failed)}")

    print("\ngate bands: A7 clip 0.5–2.5% sat 0.24–0.42 skin 1.15–1.35 · "
          "C1 clip <2% sat 0.20–0.36 skin 1.15–1.50 · "
          "A8 blk4 <6% clip <4% · N2 blk4 18–55% clip 0.3–3% sat 0.12–0.30 neuR/B 1.15–1.35")
    print(f"{len(names)} frames, {failures} with a failed gate")
    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main()
