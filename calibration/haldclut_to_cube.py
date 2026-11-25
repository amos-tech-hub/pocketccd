#!/usr/bin/env python3
"""Convert an 8-bit sRGB HaldCLUT PNG to a .cube 3D LUT (red-fastest).

Usage: python3 haldclut_to_cube.py input.png output.cube 33

HaldCLUT level N is encoded as an (N**3) x (N**3) image whose 2D pixel index
is `r + g*G + b*G*G`, with G = cube root of the pixel count. The RawTherapee
film pack ships level 12 (1728x1728 -> G=144).
"""
import sys
import numpy as np
from PIL import Image


def main() -> int:
    src, dst, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    im = Image.open(src).convert("RGB")
    w, h = im.size
    g = round((w * h) ** (1 / 3))
    assert g ** 3 == w * h, f"{w}x{h} is not a HaldCLUT grid"
    arr = np.asarray(im).reshape(-1, 3).astype(np.float32) / 255.0

    coords = np.linspace(0, g - 1, n)
    rr, gg, bb = np.meshgrid(coords, coords, coords, indexing="ij")

    def sample(r, g_, b):
        r0 = np.floor(r).astype(int); g0 = np.floor(g_).astype(int); b0 = np.floor(b).astype(int)
        r1 = np.minimum(r0 + 1, g - 1); g1 = np.minimum(g0 + 1, g - 1); b1 = np.minimum(b0 + 1, g - 1)
        fr = (r - r0)[..., None]; fg = (g_ - g0)[..., None]; fb = (b - b0)[..., None]

        def idx(x, y, z):
            return arr[x + y * g + z * g * g]

        c00 = idx(r0, g0, b0) * (1 - fr) + idx(r1, g0, b0) * fr
        c10 = idx(r0, g1, b0) * (1 - fr) + idx(r1, g1, b0) * fr
        c01 = idx(r0, g0, b1) * (1 - fr) + idx(r1, g0, b1) * fr
        c11 = idx(r0, g1, b1) * (1 - fr) + idx(r1, g1, b1) * fr
        return (c00 * (1 - fg) + c10 * fg) * (1 - fb) + (c01 * (1 - fg) + c11 * fg) * fb

    lut = sample(rr, gg, bb)
    lines = [
        'TITLE "RT Kodak Portra 400 2 (sRGB HaldCLUT)"',
        f"LUT_3D_SIZE {n}",
        "DOMAIN_MIN 0.0 0.0 0.0",
        "DOMAIN_MAX 1.0 1.0 1.0",
        "# Source: RawTherapee Film Simulation HaldCLUT (CC BY-SA 4.0)",
        "# Internal calibration only; do not redistribute in the app bundle.",
        "",
    ]
    # .cube data order is red fastest, then green, then blue.
    for b in range(n):
        for g_ in range(n):
            for r in range(n):
                c = lut[r, g_, b]
                lines.append(f"{c[0]:.6f} {c[1]:.6f} {c[2]:.6f}")
    with open(dst, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(dst, n, "grid", g, "bytes", __import__("os").path.getsize(dst))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
