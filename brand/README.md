# PocketCCD brand mark

> **v3 (2026-11-15)** — the supplied artwork is the brand. Nothing is redrawn.
>
> - Canonical logo: `brand/PocketCCD-Wordmark.svg` (996 × 774). It is the supplied
>   artwork with exactly one change: the navy ground became brand black `#0B0C0A`.
>   The SVG embeds the artwork as a raster so the bevel, soft shadow and grain
>   survive untouched; a true vector trace of that texture produced noise.
> - Raster master: `brand/v3/wordmark-textured.png` (same pixels, black ground).
> - App icon: the same artwork padded on black, 90 % width, centred.
>   `brand/v3/icon-textured-{1024,180,120,87,60,40}.png`; the store icon lives at
>   `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`.
> - Flat alternates (no bevel) from the earlier pass remain in `brand/v3/vector/`
>   as `wordmark-*.svg` if a print-safe flat version is ever needed.
> - Known limit: `CCD` is unreadable below 40 px; the icon is designed for 60 px
>   and up.
>
> The section below describes the previous geometric mark and is kept for
> reference; `brand/legacy/` holds its original exports.

# PocketCCD brand mark

The app icon and wordmark for PocketCCD, derived from `.tastemaker/style-lock.md`:
black ground, warm amber accent, warm off-white ink, hairline geometry, flat fills.

## The mark

A camera viewfinder frame drawn as four corner brackets, holding one amber lens.
The lens barrel is a flat amber ring; the glass is the near-black panel colour;
inside sits a small hexagonal iris — a nod to the six-blade shutters that gave
early consumer CCD cameras their bloom and grain.

- **Meaning:** viewfinder = composing a photo, amber ring = the CCD look that
  defines the app, hex iris = the shutter, brackets = the pocket-camera viewfinder.
- **Construction:** 1024 grid, all geometry on integer multiples of 4.
  Bracket inset 132, arm 212, stroke 24; lens r 250, barrel 40; glass r 210;
  inner ring r 158; iris r 60. Icon body is full-bleed — iOS applies the squircle.
- **Why it holds at 40 px:** the only shapes are a ring, a dot, and four corner
  ticks. Nothing depends on fine detail, text, or thin hairlines.

## Colour

| Role | Value | Source |
| --- | --- | --- |
| Ground | `#0B0C0A` | black background, slightly deeper than the panel |
| Brackets (dark surfaces) | `#E6E6E0` | primary ink |
| Brackets (light surfaces) | `#181916` | ink inverted |
| Lens / accent | `#F0AD3D` | accent |
| Lens gasket | `#B0761E` | accent, darkened |
| Glass | `#070806` | below panel `#131412` |

No gradients, glows, shadows, or translucency anywhere in the mark.

## Files

| File | Use |
| --- | --- |
| `../Assets.xcassets/AppIcon.appiconset/` | built app icon (Xcode 14+, single 1024 source) |
| `PocketCCD-Icon-1024.png` | App Store icon source, sRGB, opaque |
| `PocketCCD-Icon-{180,120,87,60,40}.png` | home screen / Settings / Spotlight exports |
| `PocketCCD-Icon-Rounded.png` | presentation preview only (masked, on a plate) |
| `PocketCCD-Icon-Sizes.png` | legibility check across sizes |
| `PocketCCD-Mark.png` | transparent mark for dark surfaces (off-white brackets) |
| `PocketCCD-Mark-Light.png` | transparent mark for light surfaces (near-black brackets) |
| `PocketCCD-Lockup-Dark.png` | horizontal lockup on black |
| `PocketCCD-Lockup-Light.png` | horizontal lockup on white |

## Wordmark

`SF Mono` Semibold, +3% tracking; "Pocket" in ink, "CCD" in amber. Monospaced
type matches the camera-state labels in the app shell. Never letter-space it
differently, never set "CCD" in ink.

## Regenerate

```sh
python3 scripts/generate_logo.py            # rebuild icon, sizes, lockups, asset catalog
python3 scripts/generate_logo.py --explore  # rebuild exploration sheets in brand/explorations/
```

Only Pillow is required. All geometry is generated, so a colour or proportion
change is a one-line edit.

## Do not

- Do not add gradients, bevels, glows, or drop shadows.
- Do not recolour the ring away from amber, or fill the whole tile with amber.
- Do not place the mark below 40 px, or add text inside the icon.
- Do not imitate ProCCD's icon or any existing camera-app branding.
- Keep clear space of at least one bracket arm (212/1024 ≈ 21% of width) around
  the lockup.
