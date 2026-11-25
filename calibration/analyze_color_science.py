#!/usr/bin/env python3
"""Analyze color science of measured camera charts + Portra 400 .cube, and optionally PocketCCD renders."""
import json
import math
from pathlib import Path
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent

CC_NAMES = [
    "Dark Skin", "Light Skin", "Blue Sky", "Foliage", "Blue Flower", "Bluish Green",
    "Orange", "Purplish Blue", "Moderate Red", "Purple", "Yellow Green", "Orange Yellow",
    "Blue", "Green", "Red", "Yellow", "Magenta", "Cyan",
    "White 9.5", "Neutral 8", "Neutral 6.5", "Neutral 5", "Neutral 3.5", "Black 2",
]

CC_REF_SRGB = np.array([
    [115,  82,  68], [194, 150, 130], [ 98, 122, 157], [ 87, 108,  67], [133, 128, 177], [103, 189, 170],
    [214, 126,  44], [ 80,  91, 166], [193,  90,  99], [ 94,  60, 108], [157, 188,  64], [224, 163,  46],
    [ 56,  61, 150], [ 70, 148,  73], [175,  54,  60], [231, 199,  31], [187,  86, 149], [  8, 133, 161],
    [243, 243, 242], [200, 200, 200], [160, 160, 160], [122, 122, 121], [ 85,  85,  85], [ 52,  52,  52],
], dtype=np.float64)


def srgb_to_linear(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * (c ** (1.0 / 2.4)) - 0.055)


def srgb255_to_lab(rgb255):
    lin = srgb_to_linear(rgb255 / 255.0)
    M = np.array([
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ])
    xyz = lin @ M.T
    t = xyz / np.array([0.95047, 1.00000, 1.08883])
    eps = 216.0 / 24389.0
    kappa = 24389.0 / 27.0
    f = np.where(t > eps, np.cbrt(t), (kappa * t + 16.0) / 116.0)
    L = 116.0 * f[..., 1] - 16.0
    a = 500.0 * (f[..., 0] - f[..., 1])
    b = 200.0 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, b], axis=-1)


def delta_e_2000(lab1, lab2):
    """Vectorized CIEDE2000 between two (N, 3) Lab arrays."""
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1 = np.sqrt(a1**2 + b1**2)
    C2 = np.sqrt(a2**2 + b2**2)
    Cbar = 0.5 * (C1 + C2)
    G = 0.5 * (1.0 - np.sqrt((Cbar**7) / (Cbar**7 + 25.0**7)))
    a1p = (1.0 + G) * a1
    a2p = (1.0 + G) * a2
    C1p = np.sqrt(a1p**2 + b1**2)
    C2p = np.sqrt(a2p**2 + b2**2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360.0
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360.0

    dLp = L2 - L1
    dCp = C2p - C1p
    dhp = h2p - h1p
    dhp = np.where(dhp > 180.0, dhp - 360.0, dhp)
    dhp = np.where(dhp < -180.0, dhp + 360.0, dhp)
    dhp = np.where((C1p * C2p) == 0.0, 0.0, dhp)
    dHp = 2.0 * np.sqrt(C1p * C2p) * np.sin(np.radians(dhp * 0.5))

    Lbarp = 0.5 * (L1 + L2)
    Cbarp = 0.5 * (C1p + C2p)
    hsum = h1p + h2p
    hbarp = np.where(
        (C1p * C2p) == 0.0,
        hsum,
        np.where(
            np.abs(h1p - h2p) <= 180.0,
            0.5 * hsum,
            np.where(hsum < 360.0, 0.5 * (hsum + 360.0), 0.5 * (hsum - 360.0)),
        ),
    )

    T = (
        1.0
        - 0.17 * np.cos(np.radians(hbarp - 30.0))
        + 0.24 * np.cos(np.radians(2.0 * hbarp))
        + 0.32 * np.cos(np.radians(3.0 * hbarp + 6.0))
        - 0.20 * np.cos(np.radians(4.0 * hbarp - 63.0))
    )
    dtheta = 30.0 * np.exp(-(((hbarp - 275.0) / 25.0) ** 2))
    RC = 2.0 * np.sqrt((Cbarp**7) / (Cbarp**7 + 25.0**7))
    SL = 1.0 + (0.015 * (Lbarp - 50.0) ** 2) / np.sqrt(20.0 + (Lbarp - 50.0) ** 2)
    SC = 1.0 + 0.045 * Cbarp
    SH = 1.0 + 0.015 * Cbarp * T
    RT = -np.sin(np.radians(2.0 * dtheta)) * RC

    return np.sqrt((dLp / SL) ** 2 + (dCp / SC) ** 2 + (dHp / SH) ** 2 + RT * (dCp / SC) * (dHp / SH))


def load_cube(path):
    size = None
    data = []
    for line in Path(path).read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("TITLE") or s.startswith("DOMAIN_"):
            continue
        if s.startswith("LUT_3D_SIZE"):
            size = int(s.split()[1])
            continue
        parts = s.split()
        if len(parts) == 3:
            data.append([float(parts[0]), float(parts[1]), float(parts[2])])
    arr = np.array(data, dtype=np.float64).reshape(size, size, size, 3)  # [b, g, r, 3]
    return size, arr


def apply_cube_srgb(rgb255, size, table_bgr):
    pts = np.clip(rgb255 / 255.0, 0.0, 1.0) * (size - 1)
    r, g, b = pts[:, 0], pts[:, 1], pts[:, 2]
    r0 = np.floor(r).astype(int); g0 = np.floor(g).astype(int); b0 = np.floor(b).astype(int)
    r1 = np.minimum(r0 + 1, size - 1); g1 = np.minimum(g0 + 1, size - 1); b1 = np.minimum(b0 + 1, size - 1)
    fr = (r - r0)[:, None]; fg = (g - g0)[:, None]; fb = (b - b0)[:, None]

    c00 = table_bgr[b0, g0, r0] * (1 - fr) + table_bgr[b0, g0, r1] * fr
    c10 = table_bgr[b0, g1, r0] * (1 - fr) + table_bgr[b0, g1, r1] * fr
    c01 = table_bgr[b1, g0, r0] * (1 - fr) + table_bgr[b1, g0, r1] * fr
    c11 = table_bgr[b1, g1, r0] * (1 - fr) + table_bgr[b1, g1, r1] * fr
    out = (c00 * (1 - fg) + c10 * fg) * (1 - fb) + (c01 * (1 - fg) + c11 * fg) * fb
    return np.clip(out * 255.0, 0.0, 255.0)


def generate_synthetic_chart(out_path):
    """Generate a 1200x900 (4:3) synthetic sRGB ColorChecker on 18% neutral gray surround."""
    w, h = 1200, 900
    # 18% linear gray -> sRGB ~119
    img = np.full((h, w, 3), 119, dtype=np.uint8)
    # Dark chart frame
    fx0, fy0, fx1, fy1 = 120, 130, 1080, 770
    img[fy0:fy1, fx0:fx1] = 35
    cw, ch = 156, 156
    ox, oy = 132, 138
    centers = []
    for r in range(4):
        for c in range(6):
            idx = r * 6 + c
            x0 = ox + c * cw + 10
            y0 = oy + r * ch + 10
            x1 = x0 + cw - 20
            y1 = y0 + ch - 20
            img[y0:y1, x0:x1] = np.round(CC_REF_SRGB[idx]).astype(np.uint8)
            centers.append(((x0 + x1) // 2, (y0 + y1) // 2))
    Image.fromarray(img, mode="RGB").save(out_path)
    return centers


def sample_synthetic(img_path, centers, half=30):
    arr = np.asarray(Image.open(img_path).convert("RGB"), dtype=np.float64)
    out = np.zeros((24, 3), dtype=np.float64)
    for i, (cx, cy) in enumerate(centers):
        roi = arr[cy - half : cy + half, cx - half : cx + half]
        out[i] = np.median(roi.reshape(-1, 3), axis=0)
    return out


def summarize(name, rgb24, ref_rgb24=CC_REF_SRGB):
    lab = srgb255_to_lab(rgb24)
    ref_lab = srgb255_to_lab(ref_rgb24)
    de = delta_e_2000(lab, ref_lab)
    # Exposure-normalized (match median L of Neutral 6.5 & 5)
    lin = srgb_to_linear(rgb24 / 255.0)
    ref_lin = srgb_to_linear(ref_rgb24 / 255.0)
    gain = (ref_lin[20:22].mean() / max(lin[20:22].mean(), 1e-6))
    norm_rgb = linear_to_srgb(lin * gain) * 255.0
    norm_lab = srgb255_to_lab(norm_rgb)
    de_norm = delta_e_2000(norm_lab, ref_lab)

    # Chroma ratio on 18 chromatic patches
    c_meas = np.hypot(lab[:18, 1], lab[:18, 2]).mean()
    c_ref = np.hypot(ref_lab[:18, 1], ref_lab[:18, 2]).mean()
    chroma_ratio = c_meas / c_ref

    # Key hue shifts (degrees, positive = CCW toward yellow/green/blue)
    def hue_deg(l):
        return np.degrees(np.arctan2(l[2], l[1])) % 360.0
    def dh(idx):
        d = hue_deg(lab[idx]) - hue_deg(ref_lab[idx])
        return (d + 180.0) % 360.0 - 180.0

    # Neutral midtone WB (R/G, B/G)
    mid = rgb24[19:22].mean(axis=0)
    rg = mid[0] / max(mid[1], 1e-6)
    bg = mid[2] / max(mid[1], 1e-6)
    # Black & White luma
    luma = 0.2126 * rgb24[:, 0] + 0.7152 * rgb24[:, 1] + 0.0722 * rgb24[:, 2]

    print(
        f"{name:<20} ΔE={de.mean():5.2f} (norm {de_norm.mean():5.2f}) "
        f"Chr={chroma_ratio:4.2f}x  WB={rg:.3f}/{bg:.3f}  "
        f"W/B={luma[18]:3.0f}/{luma[23]:2.0f}  "
        f"Δh[Skin2={dh(1):+5.1f}° Sky={dh(2):+5.1f}° Fol={dh(3):+5.1f}° Red={dh(14):+5.1f}° Grn={dh(13):+5.1f}°]"
    )
    return {
        "de2000_mean": round(float(de.mean()), 2),
        "de2000_norm_mean": round(float(de_norm.mean()), 2),
        "chroma_ratio": round(float(chroma_ratio), 3),
        "wb_rg": round(float(rg), 4),
        "wb_bg": round(float(bg), 4),
        "white_luma": round(float(luma[18]), 1),
        "black_luma": round(float(luma[23]), 1),
        "hue_shifts_deg": {
            "light_skin": round(float(dh(1)), 1),
            "blue_sky": round(float(dh(2)), 1),
            "foliage": round(float(dh(3)), 1),
            "red": round(float(dh(14)), 1),
            "green": round(float(dh(13)), 1),
        },
        "srgb_24": np.round(rgb24, 2).tolist(),
    }


def main():
    ref_img = ROOT / "previews" / "colorchecker-ref.png"
    centers = generate_synthetic_chart(ref_img)
    measured = json.loads((ROOT / "measured-patches.json").read_text())

    size, table = load_cube(ROOT / "cube" / "portra400-33.cube")
    portra_rgb = apply_cube_srgb(CC_REF_SRGB, size, table)

    print("=== Reference Cameras & Portra 400 vs Standard ColorChecker (D65 sRGB) ===")
    summary = {}
    for key in ["A70-auto", "A70-manual", "S400-auto", "S400-manual", "W1-auto", "F30hSLI0100", "F30hSLI0800", "F30-multi"]:
        if key in measured:
            summary[key] = summarize(key, np.array(measured[key]["srgb_24"]))
    summary["Portra400-33"] = summarize("Portra400-33 (N1)", portra_rgb)

    # Check if rendered PocketCCD ColorChecker PNGs exist in calibration/previews/rendered/
    render_dir = ROOT / "previews" / "rendered"
    if render_dir.exists():
        print("\n=== PocketCCD Current Looks vs Standard ColorChecker (D65 sRGB) ===")
        pocket_rgb = {}
        for look_code in ["A7", "A8", "C1", "N2", "N1", "M1"]:
            p = render_dir / f"{look_code}-colorchecker-ref.png"
            if p.exists():
                rgb = sample_synthetic(p, centers)
                pocket_rgb[look_code] = rgb
                summary[f"PocketCCD-{look_code}"] = summarize(f"PocketCCD {look_code}", rgb)

        print("\n=== Direct Gap: PocketCCD Look vs Target Reference Camera ===")
        pairs = [
            ("A7", "A70-auto", "Canon A70 (auto)"),
            ("A7", "A70-manual", "Canon A70 (manual)"),
            ("A8", "S400-auto", "Canon S400 (auto)"),
            ("C1", "W1-auto", "Sony W1 (auto)"),
            ("N2", "F30hSLI0100", "Fuji F30 (ISO 100)"),
            ("N2", "F30hSLI0800", "Fuji F30 (ISO 800)"),
            ("N1", "Portra400-33", "RT Portra 400"),
        ]
        for code, ref_key, label in pairs:
            if code not in pocket_rgb:
                continue
            ref_arr = portra_rgb if ref_key == "Portra400-33" else np.array(measured[ref_key]["srgb_24"])
            summarize(f"{code} vs {label[:12]}", pocket_rgb[code], ref_rgb24=ref_arr)

    (ROOT / "color-science-report.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"\nWrote {ref_img} and color-science-report.json")


if __name__ == "__main__":
    main()
