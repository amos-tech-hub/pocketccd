# PocketCCD competitive imaging benchmark

Updated: 2026-11-13

## Evidence boundary

This benchmark separates three evidence levels:

1. **Public user samples** — photographs explicitly attributed to ProCCD by their posters.
2. **Public user descriptions** — useful for direction, but not suitable for pixel measurements when the original file is unavailable.
3. **Controlled captures** — the only material allowed to set final numeric tolerances. Capture these locally from the same iPhone, scene, framing, focus point, and exposure.

Do not copy third-party photographs into the repository. Keep reference links here and place only locally captured, licensed test fixtures under `Research/Samples`.

Competitor images are development evidence, not product input. PocketCCD must not expose a competitor-photo picker, store competitor images, or mix their measurements into its on-device calibration records. The in-app benchmark records only PocketCCD output; reference measurements and parameter fitting happen with the offline analyzer.

## Reference field

### ProCCD

- [ProCCD App Store listing](https://apps.apple.com/us/app/proccd-digital-film-camera/id1616113199): confirms live effects, manual exposure/ISO/white balance, flash, timer, multiple ratios, lens selection, date stamps, grain, vignette, glow, dispersion, and exposure adjustment.
- [Flickr `proccd` tag](https://www.flickr.com/photos/tags/proccd/): user-attributed samples. One indexed description specifically identifies ProCCD C123 as strongly orange and intended for sunsets.
- [ProCCD NX / XS3 / A620 user comparison](https://www.lemon8-app.com/@rath.teea/7444532790860825104?region=id): default-setting comparison across outdoor, indoor, and night use. The author describes NX as soft, XS3 as warm/vibrant and strongest in good light, and A620 as cool/blue, bright, and flattering for indoor/night skin.
- [ProCCD night portrait example](https://www.lemon8-app.com/@creamn3/7454109816156766727?region=us): public user example of a flash-lit subject separated from a dark background with soft highlight bloom.

### Adjacent competitors

- OldRoll structures each preset as a complete camera simulation combining color response, grain, vignette/light leak, and date treatment rather than a generic tint. Its public guide also notes that portraits usually need less grain and that artificial light can shift a preset enough to require white-balance correction.
- Dazz Cam and NOMO CAM are useful secondary controls for checking whether PocketCCD is merely “retro” or specifically reads as compact-digital/CCD.

### Technical control

- [TTAC point-and-shoot comparison set](https://telehealthtechnology.org/toolkit/digital-camera-point-shoot-sample-photos/) documents controlled differences in flash clipping, low-light detail, white balance, skin saturation, and resolution. It is not a style reference; it defines failure cases the nostalgic treatment must not cross.

## Controlled capture matrix

For every row, capture four outputs without moving the phone: Apple Camera reference, ProCCD reference, PocketCCD unfiltered source, and the relevant PocketCCD look. Disable Smart HDR differences where the app permits it and record the physical lens.

| ID | Scene | Required content | Lighting | PocketCCD target |
|---|---|---|---|---|
| D01 | Daylight | sky, foliage, red object, neutral grey | direct sun | POCKET A7 |
| D02 | Daylight shade | face, white shirt, foliage | open shade | POCKET C1 |
| F01 | Indoor direct flash | face at 1.2 m, white wall, dark background | warm room + flash | POCKET A7 |
| F02 | Close flash stress | face/object at 0.55 m, white detail | low room light + flash | POCKET C1 |
| N01 | Night street | face, sodium/LED sign, black sky | flash on | POCKET N2 |
| N02 | Night available light | storefront, shadow texture, point lights | flash off | POCKET N2 |
| S01 | Skin daylight | face + grey card | indirect daylight | all looks |
| S02 | Skin mixed light | face + white shirt | window + warm lamp | all looks |

Use the same focus point, exposure compensation, aspect ratio, and physical lens for every app. Take three repetitions per cell; a single image is not a benchmark.

## Numeric acceptance targets

Run `swift Research/analyze_samples.swift <folder> [roi.csv]` on exported JPEG/PNG files. The optional ROI file has the columns `file,x,y,width,height`; coordinates are normalized to 0–1 from the displayed image's top-left corner. The analyzer emits one `full` row and, when present, one `roi` row per image. Use the same face ROI across matched captures. Targets are starting tolerances inferred from the public samples and compact-camera failure modes; replace them with controlled-capture medians after the set exists.

### POCKET A7 — warm, vibrant compact camera

- Daylight highlight clipping: `0.5–2.5%` of RGB channels at or above 250.
- Mean red-minus-blue balance: `+0.025–+0.090` in normalized RGB.
- Mean saturation: `0.24–0.42`; avoid uniformly saturating skin and sky.
- Sharpness proxy: `0.035–0.085`; crisp edges with visible but restrained processing.
- F01 face: retain texture; clipped-pixel ratio below `3%` inside the face crop.

### POCKET C1 — bright, cool, clean skin

- Mean red-minus-blue balance: `-0.060–+0.015`.
- Global highlight clipping below `2%`.
- Mean saturation: `0.20–0.36`.
- Sharpness proxy: `0.045–0.095`, the sharpest of the three profiles.
- Skin should move brighter/cooler without crossing into magenta; compare against the grey-card frame, not memory.

### POCKET N2 — dense blacks and separated point light

- Pixels below luma 0.04: `18–55%`, depending on scene.
- Highlight clipping: `0.3–3%`; point lights may clip, faces may not.
- Mean saturation: `0.12–0.30`.
- Sharpness proxy: `0.020–0.060`; avoid sharpening chroma noise.
- Grain proxy may exceed the other profiles, but it must remain exposure-dependent: shadows can be rougher than faces/highlights.

## Visual review gates

Every candidate must pass these side-by-side checks at 100% and phone-screen size:

- **Highlight roll-off:** flash forehead, white clothing, and clouds retain a transition before clipping.
- **Skin hue:** no blanket pink/orange cast; compare lips and neutral skin separately.
- **Black floor:** NIGHT has dense blacks without crushing hair and dark fabric into one shape.
- **Local color:** warm/cool identity comes from channel response and white balance, not a uniform overlay.
- **Texture:** grain is finer in highlights, stronger in shadows, and does not crawl excessively in live preview.
- **Edge behavior:** CHROME is crisp; AMBER is moderate; NIGHT does not halo high-contrast lights.
- **Flash falloff:** foreground is bright while the background falls rapidly, but close subjects are not featureless white.

## Calibration sequence

1. Capture the eight-scene matrix in Apple Camera, ProCCD, and PocketCCD.
2. Export originals without social-media recompression.
3. Keep owned competitor captures in a development-only location outside the app bundle; put only PocketCCD test fixtures intended for repository regression in `Research/Samples/pocketccd` using `<scene>_pocketccd_<look>_<take>.jpg`.
4. Create an ROI CSV for face scenes, run the analyzer, and save its output with the test date and iPhone model. Treat `grain_proxy` as a relative high-frequency residual, not physical sensor noise.
   For captures that came back through the in-app original-frame archive, skip the export step: `swift Research/originals_report.swift <archive-root>` reads the `capture.json` metadata, auto-detects the face, and emits the same metrics plus lit-side skin ratios and the black floor, with the night-flash gates applied.
5. Tune tone curve and white balance first, then saturation, then sharpening, then grain/bloom.
6. Change one parameter family at a time and keep three captures per scene.
7. A profile ships only when every scene stays inside its numeric band and passes the visual gates.

