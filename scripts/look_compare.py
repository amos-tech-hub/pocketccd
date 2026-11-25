#!/usr/bin/env python3
"""Measure exported Pocket CCD frames and compare looks on the same scene.

The app does not tag look names in the JPEG EXIF, but every photo is also
stored in the film roll with a `cameraRawValue`. Match the exported files to
that manifest once (see docs/SAMPLE_QUALITY_REVIEW_2026-11-19.md, section 1),
save a `{"IMG_1234.JPG": "A7", ...}` map, and feed it in here.

Usage:
    python3 scripts/look_compare.py pictures --labels labels.json
    python3 scripts/look_compare.py pictures --labels labels.json --json out.json

Metrics per image (all on a 1600 px thumbnail unless noted):
    luma      mean Rec.709 luma, 0-1
    p95       95th percentile luma
    clip%     share of RGB channels at or above 250/255
    sat       mean HSV saturation
    noise     high-pass residual on flat shadow patches, 0-255 scale
              (relative between looks, not physical sensor noise)
    R-B       mean R minus mean B (the look target bands use this)
    blk4      share of pixels below luma 0.04
    skyG/B    G/B of the blue sky in the top quarter, when one exists

This is a review tool, not a CI gate: thresholds live in
Research/CompetitiveImagingBenchmark.md.
"""

import argparse
import json
import os
from collections import defaultdict

import numpy as np
from PIL import Image


def _stack3(plane):
    p = np.pad(plane, 1, mode="edge")
    h, w = plane.shape
    return np.stack([p[dy:dy + h, dx:dx + w] for dy in range(3) for dx in range(3)])


def measure(path):
    image = Image.open(path).convert("RGB")
    image.thumbnail((1600, 1600), Image.LANCZOS)
    rgb = np.asarray(image).astype(np.float32) / 255.0
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    high = rgb.max(axis=2)
    low = rgb.min(axis=2)
    sat = np.where(high > 0, (high - low) / np.maximum(high, 1e-6), 0)

    # Grain: high-pass energy where the picture is locally flat and dark.
    residual = luma - np.median(_stack3(luma), axis=0)
    flat = _stack3(luma).std(axis=0) < 0.012
    shadow = flat & (luma < 0.30)
    noise = float(np.mean(np.abs(residual[shadow])) * 255) if shadow.sum() > 500 else float("nan")

    # Neutral patches give a scene-independent white-balance read.
    neutral = (sat < 0.10) & (luma > 0.18) & (luma < 0.85)
    neutral_rb = (float(r[neutral].mean() / max(b[neutral].mean(), 1e-6))
                  if neutral.sum() > 2000 else float("nan"))

    top = slice(0, int(rgb.shape[0] * 0.25))
    sky = (b[top] > r[top] + 0.05) & (luma[top] > 0.35)
    sky_gb = (float(g[top][sky].mean() / max(b[top][sky].mean(), 1e-6))
              if sky.sum() > 1000 else float("nan"))

    return {
        "luma": float(luma.mean()),
        "p95": float(np.percentile(luma, 95)),
        "clip": float((high * 255 >= 250).mean() * 100),
        "sat": float(sat.mean()),
        "noise": noise,
        "R-B": float(r.mean() - b.mean()),
        "blk4": float((luma < 0.04).mean() * 100),
        "skyG/B": sky_gb,
        "neutralR/B": neutral_rb,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", help="exported JPEG folder")
    parser.add_argument("--labels", help='JSON map {"IMG_1234.JPG": "A7"}')
    parser.add_argument("--json", help="write per-image metrics here")
    parser.add_argument("--scene", help='JSON map {"scene": ["IMG_1.JPG", ...]} for a per-scene table')
    args = parser.parse_args()

    labels = {}
    if args.labels:
        with open(args.labels, encoding="utf-8") as fh:
            labels = json.load(fh)

    names = sorted(n for n in os.listdir(args.folder) if n.upper().endswith((".JPG", ".JPEG", ".PNG")))
    rows = []
    for name in names:
        row = {"file": name, "look": labels.get(name, "?")}
        row.update(measure(os.path.join(args.folder, name)))
        rows.append(row)

    header = f"{'file':16s}{'look':5s}{'luma':>6s}{'p95':>6s}{'clip%':>7s}{'sat':>6s}{'noise':>6s}{'R-B':>7s}{'blk4%':>7s}{'skyG/B':>7s}"
    print(header)
    print("-" * len(header))
    for row in rows:
        print(f"{row['file']:16s}{row['look']:5s}{row['luma']:6.3f}{row['p95']:6.3f}"
              f"{row['clip']:7.2f}{row['sat']:6.3f}{row['noise']:6.2f}{row['R-B']:+7.3f}"
              f"{row['blk4']:7.1f}{row['skyG/B']:7.2f}")

    def average(values):
        values = [v for v in values if v == v]
        return sum(values) / len(values) if values else float("nan")

    print()
    groups = defaultdict(list)
    for row in rows:
        groups[row["look"]].append(row)
    print(f"{'look':5s}{'n':>4s}{'luma':>7s}{'sat':>7s}{'noise':>7s}{'R-B':>8s}{'blk4%':>7s}{'skyG/B':>8s}")
    for look in sorted(groups):
        group = groups[look]
        print(f"{look:5s}{len(group):4d}{average([r['luma'] for r in group]):7.3f}"
              f"{average([r['sat'] for r in group]):7.3f}{average([r['noise'] for r in group]):7.2f}"
              f"{average([r['R-B'] for r in group]):+8.3f}{average([r['blk4'] for r in group]):7.1f}"
              f"{average([r['skyG/B'] for r in group]):8.2f}")

    if args.scene:
        with open(args.scene, encoding="utf-8") as fh:
            scenes = json.load(fh)
        by_file = {row["file"]: row for row in rows}
        for scene, files in scenes.items():
            print(f"\n## {scene}")
            for name in files:
                row = by_file.get(name)
                if not row:
                    continue
                print(f"  {row['file']:16s}{row['look']:5s}luma {row['luma']:.3f}  sat {row['sat']:.3f}"
                      f"  R-B {row['R-B']:+.3f}  clip {row['clip']:.2f}%  blk4 {row['blk4']:.1f}%"
                      f"  noise {row['noise']:.2f}  skyG/B {row['skyG/B']:.2f}")

    if args.json:
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(rows, fh, indent=1)
        print(f"\nwrote {args.json}")


if __name__ == "__main__":
    main()
