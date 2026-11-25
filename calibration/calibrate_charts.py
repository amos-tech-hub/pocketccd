#!/usr/bin/env python3
"""Fix ColorChecker quads, map to standard CC#1-24, draw overlays, and sample patches."""
import csv
import json
import math
import os
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent

# Standard Macbeth / X-Rite ColorChecker 24 names (1-indexed)
CC_NAMES = [
    "Dark Skin", "Light Skin", "Blue Sky", "Foliage", "Blue Flower", "Bluish Green",
    "Orange", "Purplish Blue", "Moderate Red", "Purple", "Yellow Green", "Orange Yellow",
    "Blue", "Green", "Red", "Yellow", "Magenta", "Cyan",
    "White 9.5", "Neutral 8", "Neutral 6.5", "Neutral 5", "Neutral 3.5", "Black 2",
]

# Standard sRGB (D65, BabelColor / X-Rite post-2014 average) reference values [0..255]
CC_REF_SRGB = np.array([
    [115,  82,  68], [194, 150, 130], [ 98, 122, 157], [ 87, 108,  67], [133, 128, 177], [103, 189, 170],
    [214, 126,  44], [ 80,  91, 166], [193,  90,  99], [ 94,  60, 108], [157, 188,  64], [224, 163,  46],
    [ 56,  61, 150], [ 70, 148,  73], [175,  54,  60], [231, 199,  31], [187,  86, 149], [  8, 133, 161],
    [243, 243, 242], [200, 200, 200], [160, 160, 160], [122, 122, 121], [ 85,  85,  85], [ 52,  52,  52],
], dtype=np.float64)

# Verified outer grid quads (TL, TR, BL, BR) covering all 24 patches symmetrically.
# orientation:
#   "ccw90"     -> 4 cols x 6 rows (portrait), bottom-left is CC#1 (Dark Skin), bottom-right is CC#19 (White)
#   "landscape" -> 6 cols x 4 rows (standard), top-left is CC#1 (Dark Skin), bottom-left is CC#19 (White)
CHART_QUADS = {
    "charts/A70-auto.jpg":       {"quad": [[282,  73], [794,  73], [282, 860], [794, 860]], "orientation": "ccw90"},
    "charts/A70-daylight.jpg":   {"quad": [[282,  73], [794,  73], [282, 860], [794, 860]], "orientation": "ccw90"},
    "charts/A70-manual.jpg":     {"quad": [[282,  73], [794,  73], [282, 860], [794, 860]], "orientation": "ccw90"},
    "charts/S400-auto.jpg":      {"quad": [[347,  87], [890,  87], [347, 919], [890, 919]], "orientation": "ccw90"},
    "charts/S400-daylight.jpg":  {"quad": [[347,  87], [890,  87], [347, 919], [890, 919]], "orientation": "ccw90"},
    "charts/S400-manual.jpg":    {"quad": [[347,  87], [890,  87], [347, 919], [890, 919]], "orientation": "ccw90"},
    "charts/W1-auto.jpg":        {"quad": [[398, 136], [1039, 136], [398, 1111], [1039, 1111]], "orientation": "ccw90"},
    "charts/W1-daylight.jpg":    {"quad": [[398, 136], [1039, 136], [398, 1111], [1039, 1111]], "orientation": "ccw90"},
    "charts/F30-multi.jpg":      {"quad": [[592, 270], [1261, 270], [592, 1298], [1261, 1298]], "orientation": "ccw90"},
    "charts/F30hSLI0100.jpg":    {"quad": [[1280, 1755], [1587, 1755], [1280, 1959], [1587, 1959]], "orientation": "landscape"},
    "charts/F30hSLI0800.jpg":    {"quad": [[1281, 1754], [1588, 1754], [1281, 1958], [1588, 1958]], "orientation": "landscape"},
}

NEW_CHARTS_META = [
    {
        "camera": "FUJIFILM FinePix F30",
        "role": "N2",
        "file": "charts/F30hSLI0100.jpg",
        "source_file": "F30hSLI0100.JPG",
        "source_url": "https://old.imaging-resource.com/PRODS/F30/FULLRES/F30hSLI0100.JPG",
        "source_page": "https://old.imaging-resource.com/PRODS/F30/F30PICS.HTM",
        "exif_model": "FUJIFILM FinePix F30",
        "white_balance": "still-life-iso100",
        "width": 2848,
        "height": 2136,
    },
    {
        "camera": "FUJIFILM FinePix F30",
        "role": "N2",
        "file": "charts/F30hSLI0800.jpg",
        "source_file": "F30hSLI0800.JPG",
        "source_url": "https://old.imaging-resource.com/PRODS/F30/FULLRES/F30hSLI0800.JPG",
        "source_page": "https://old.imaging-resource.com/PRODS/F30/F30PICS.HTM",
        "exif_model": "FUJIFILM FinePix F30",
        "white_balance": "still-life-iso800",
        "width": 2848,
        "height": 2136,
    },
]


def bilinear(quad, u, v):
    tl, tr, bl, br = [np.array(p, dtype=np.float64) for p in quad]
    top = tl * (1 - u) + tr * u
    bot = bl * (1 - u) + br * u
    return top * (1 - v) + bot * v


def compute_grid(quad, orientation):
    """Returns list of dicts with grid_index (1..24), colorchecker_id (1..24), x, y, box_half_w, box_half_h."""
    tl, tr, bl, br = [np.array(p, dtype=np.float64) for p in quad]
    if orientation == "ccw90":
        ncols, nrows = 4, 6
    else:
        ncols, nrows = 6, 4

    cell_w = np.linalg.norm(tr - tl) / ncols
    cell_h = np.linalg.norm(bl - tl) / nrows
    # Sample central 34% of each cell to stay well clear of black grid dividers
    hw = max(3, int(round(cell_w * 0.17)))
    hh = max(3, int(round(cell_h * 0.17)))

    patches = []
    grid_idx = 0
    for r in range(nrows):
        for c in range(ncols):
            grid_idx += 1
            u = (c + 0.5) / ncols
            v = (r + 0.5) / nrows
            x, y = bilinear(quad, u, v)
            if orientation == "ccw90":
                # Col c (0..3) corresponds to standard landscape row c (0..3)
                # Row r (0..5, top to bottom) corresponds to standard landscape col (5 - r)
                cc_row = c
                cc_col = 5 - r
                cc_id = cc_row * 6 + cc_col + 1
            else:
                cc_id = r * 6 + c + 1
            patches.append({
                "grid_index": grid_idx,
                "colorchecker_id": cc_id,
                "patch_name": CC_NAMES[cc_id - 1],
                "x": round(float(x), 1),
                "y": round(float(y), 1),
                "hw": hw,
                "hh": hh,
            })
    return patches


def srgb_to_linear(rgb01):
    return np.where(rgb01 <= 0.04045, rgb01 / 12.92, ((rgb01 + 0.055) / 1.055) ** 2.4)


def linear_srgb_to_lab(lin):
    # D65 sRGB -> XYZ
    M = np.array([
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ])
    xyz = lin @ M.T
    ref = np.array([0.95047, 1.00000, 1.08883])
    t = xyz / ref
    eps = 216.0 / 24389.0
    kappa = 24389.0 / 27.0
    f = np.where(t > eps, np.cbrt(t), (kappa * t + 16.0) / 116.0)
    L = 116.0 * f[..., 1] - 16.0
    a = 500.0 * (f[..., 0] - f[..., 1])
    b = 200.0 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, b], axis=-1)


def draw_overlay(img_path, out_path, quad, patches, crop_box=None):
    im = Image.open(img_path).convert("RGB")
    draw = ImageDraw.Draw(im)
    tl, tr, bl, br = [tuple(p) for p in quad]
    # Red quad outline
    draw.line([tl, tr, br, bl, tl], fill=(255, 40, 40), width=4)
    for p in patches:
        x, y, hw, hh = p["x"], p["y"], p["hw"], p["hh"]
        draw.rectangle([x - hw, y - hh, x + hw, y + hh], outline=(255, 230, 0), width=3)
        draw.text((x - hw + 3, y - hh + 2), f"#{p['colorchecker_id']}", fill=(255, 255, 0))
    if crop_box:
        im = im.crop(crop_box)
    else:
        im.thumbnail((1400, 1400))
    im.save(out_path)


def main():
    manifest_path = ROOT / "manifest.json"
    manifest = json.loads(manifest_path.read_text())

    # Add new F30 Still Life entries if missing
    existing_files = {c["file"] for c in manifest["charts"]}
    for meta in NEW_CHARTS_META:
        fpath = ROOT / meta["file"]
        if meta["file"] not in existing_files and fpath.exists():
            entry = dict(meta)
            entry["bytes"] = fpath.stat().st_size
            manifest["charts"].append(entry)

    csv_rows = []
    measured_all = {}

    print(f"{'Chart':<22} {'Role':<4} {'WB R/G':>7} {'WB B/G':>7} {'Neutral 6 (White -> Black)':<32} {'MeanSat':>7}")
    print("-" * 86)

    for entry in manifest["charts"]:
        rel = entry["file"]
        if rel not in CHART_QUADS:
            continue
        cfg = CHART_QUADS[rel]
        quad = cfg["quad"]
        orient = cfg["orientation"]
        patches = compute_grid(quad, orient)

        # Update manifest entry
        entry["quad_tl_tr_bl_br"] = quad
        entry["orientation"] = orient
        entry["grid"] = (
            "4 columns x 6 rows (90 deg CCW); neutral column = rightmost (top=Black#24, bottom=White#19)"
            if orient == "ccw90"
            else "6 columns x 4 rows (standard landscape); bottom row = neutral (left=White#19, right=Black#24)"
        )
        entry["patch_centers_24"] = [[p["x"], p["y"]] for p in patches]
        # Ordered by standard CC#1..24
        by_cc = sorted(patches, key=lambda p: p["colorchecker_id"])
        entry["colorchecker_centers_24"] = [[p["x"], p["y"]] for p in by_cc]
        entry["note"] = "Verified quad & standard ColorChecker 1-24 mapping."

        # Sample pixels
        img_path = ROOT / rel
        arr = np.asarray(Image.open(img_path).convert("RGB"), dtype=np.float64)
        cc_rgb = np.zeros((24, 3), dtype=np.float64)
        cc_std = np.zeros((24, 3), dtype=np.float64)
        for p in patches:
            ix, iy = int(round(p["x"])), int(round(p["y"]))
            hw, hh = p["hw"], p["hh"]
            roi = arr[iy - hh : iy + hh + 1, ix - hw : ix + hw + 1]
            med = np.median(roi.reshape(-1, 3), axis=0)
            std = np.std(roi.reshape(-1, 3), axis=0)
            cc_rgb[p["colorchecker_id"] - 1] = med
            cc_std[p["colorchecker_id"] - 1] = std
            csv_rows.append({
                "file": rel,
                "camera": entry["camera"],
                "role": entry["role"],
                "white_balance": entry["white_balance"],
                "grid_index": p["grid_index"],
                "colorchecker_id": p["colorchecker_id"],
                "patch_name": p["patch_name"],
                "x": p["x"],
                "y": p["y"],
            })

        # Draw overlay
        stem = Path(rel).stem
        out_overlay = ROOT / "overlays" / f"{stem}-grid.png"
        crop_box = None
        if orient == "landscape":
            # Zoom around the mini ColorChecker so alignment is easy to inspect
            crop_box = (1180, 1660, 1680, 2050)
        draw_overlay(img_path, out_overlay, quad, patches, crop_box=crop_box)

        # Diagnostics
        neutrals = cc_rgb[18:24]  # CC#19 White .. CC#24 Black
        luma_n = (0.2126 * neutrals[:, 0] + 0.7152 * neutrals[:, 1] + 0.0722 * neutrals[:, 2])
        # Mid-gray WB on Neutral 8, 6.5, 5 (CC#20, #21, #22)
        mid = cc_rgb[19:22].mean(axis=0)
        rg = mid[0] / max(mid[1], 1e-6)
        bg = mid[2] / max(mid[1], 1e-6)
        # HSV saturation mean over 18 chromatic patches
        chrom = cc_rgb[:18] / 255.0
        mx = chrom.max(axis=1)
        mn = chrom.min(axis=1)
        sat = np.where(mx > 1e-6, (mx - mn) / mx, 0.0).mean()
        max_patch_std = float(cc_std.max())

        ramp_str = " -> ".join(f"{v:3.0f}" for v in luma_n)
        print(f"{stem:<22} {entry['role']:<4} {rg:7.3f} {bg:7.3f} {ramp_str:<32} {sat:7.3f}  (maxStd={max_patch_std:.1f})")

        lin = srgb_to_linear(cc_rgb / 255.0)
        lab = linear_srgb_to_lab(lin)
        measured_all[stem] = {
            "file": rel,
            "camera": entry["camera"],
            "role": entry["role"],
            "white_balance": entry["white_balance"],
            "wb_rg": round(float(rg), 4),
            "wb_bg": round(float(bg), 4),
            "mean_sat_18": round(float(sat), 4),
            "max_patch_std": round(max_patch_std, 2),
            "srgb_24": np.round(cc_rgb, 2).tolist(),
            "lab_24": np.round(lab, 2).tolist(),
        }

    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    with open(ROOT / "patch-centers.csv", "w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["file", "camera", "role", "white_balance", "grid_index", "colorchecker_id", "patch_name", "x", "y"],
        )
        writer.writeheader()
        writer.writerows(csv_rows)

    (ROOT / "measured-patches.json").write_text(json.dumps(measured_all, indent=2) + "\n")
    print("\nSaved manifest.json, patch-centers.csv, measured-patches.json, and updated overlays/.")


if __name__ == "__main__":
    main()
