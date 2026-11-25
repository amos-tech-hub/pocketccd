# GitHub Camera Idea Research

Snapshot date: 2026-11-12

## Purpose

This document surveys public GitHub camera projects for product ideas, technical patterns, and feasibility evidence. A public repository is not automatically reusable. PocketCCD may learn from behavior and architecture, but code must not be copied unless its license is verified and all attribution/notice obligations are satisfied.

## Highest-value findings

### 1. Dual Memory: capture the subject and photographer at the same instant

Repositories such as [DualCameraKit](https://github.com/Liampronan/DualCameraKit) demonstrate photo-first simultaneous front/back capture using `AVCaptureMultiCamSession`, Metal composition, and layouts such as picture-in-picture, side-by-side, and stacked frames. This makes a better PocketCCD concept than a generic dual-camera mode:

- the rear camera records the memory;
- the front camera records the photographer's reaction;
- export as two originals plus a small contact-sheet composition;
- preserve a sequential fallback on unsupported devices and label it honestly;
- keep the default mode single-camera so thermal and hardware costs remain controlled.

Product fit: **strong, P2 experiment.** The concept reinforces memory rather than technical novelty.

### 2. Preview/result parity must be an engineering invariant

[Lumen](https://github.com/Irenapoghosian/lumen-camera) uses one filter engine for live frames and full-resolution stills, backed by Core Image and Metal. PocketCCD currently uses a lightweight tint overlay for preview and a separate full-resolution rendering path, so exact parity is not guaranteed.

Adopt the principle:

- each fictional camera owns one rendering recipe;
- live preview may use lower-resolution intermediate buffers, but the same stages and parameters;
- deterministic tests verify dimensions, intensity bounds, orientation, and representative pixels;
- dropped late preview frames must not build latency;
- the full-resolution result remains the quality authority.

Product fit: **mandatory P0 architecture work** before effects become more complex.

### 3. Digital sensor noise is not film grain

Public shader research distinguishes digital noise from analog grain. Useful components include:

- persistent fixed-pattern noise tied to a camera identity;
- per-capture shot/read noise with independent channel behavior;
- Bayer/CFA structure and demosaicing artifacts;
- row/column banding in underexposed regions;
- luminance-dependent chroma noise;
- highlight-dependent chromatic aberration and blooming;
- exposure-dependent sharpening and JPEG blocking.

[0.3MP Camera](https://apps.apple.com/us/app/0-3mp-camera/id1661877394) validates the user-facing value of naming these artifacts, while repositories and shader documentation such as FidelityFX Lens and film-emulation projects demonstrate feasible GPU building blocks.

Product fit: **mandatory P0 rendering work.** PocketCCD must avoid reusing a film-grain model and calling it CCD noise.

### 4. Best-frame selection can remain private and local

Projects such as [lumen-raw](https://github.com/hety0211/lumen-raw) show a useful selection order for bursts: prefer open eyes, then rank sharpness. PocketCCD can adopt the behavior without importing its models or code:

- capture a short three-frame burst in Flash Party mode;
- use Apple's on-device Vision face/landmark APIs where available;
- reject obvious closed-eye or blurred candidates;
- keep all originals until the user chooses;
- never upload faces or require an account.

Product fit: **strong P1 support feature**, but it should remain invisible when the first frame is already good.

### 5. Physical shutter affordances matter more than novelty controls

Open-source camera discussions repeatedly request volume-button capture. Modern iOS provides a public camera-event path (`AVCaptureEventInteraction`) on supported OS versions; newer devices also expose Camera Control integration.

PocketCCD should prioritize:

- volume-button shutter using public APIs only;
- Camera Control full-press capture when supported;
- stable shutter size and position;
- haptics and optional period-appropriate shutter sounds.

Product fit: **P1 usability**, not a marketing differentiator.

### 6. Gesture shutter is useful only in a narrow context

Vision-based projects demonstrate live hand-pose detection and automatic actions. A peace-sign or open-palm shutter could help group photos when the phone is propped up, but always-on gesture detection would add battery cost and accidental captures.

Recommended form:

- available only inside a timer/group mode;
- require a deliberate, stable gesture over several frames;
- show a visible countdown and allow cancellation;
- process entirely on device.

Product fit: **candidate P2 experiment**, not part of the core camera.

### 7. Photo strips are feasible but no longer differentiating

[Boothie](https://github.com/esmakocak/Boothie) and many small camera projects implement countdown capture, vintage strips, date stamps, filters, frames, saving, and sharing. The pattern is common.

PocketCCD should not add a generic booth mode merely because it is easy. The accepted version is a **memory contact sheet** generated from a Pocket Roll or Flash Party sequence, using the chosen camera's identity.

Product fit: **keep the contact-sheet plan; reject generic sticker-heavy booth editing.**

## Technical reference matrix

| Reference | Demonstrated idea | PocketCCD use | Code reuse status |
|---|---|---|---|
| Lumen | SwiftUI + AVFoundation + Core Image/Metal; same engine for preview and still | Architecture and parity tests | Inspect license before any copying |
| Prism | Actor-isolated capture, still/burst/night modes, capability gates | Future capture-service design reference | Inspect license before any copying |
| DualCameraKit | Simultaneous front/rear stills and composable layouts | Dual Memory feasibility | Repository states MIT; retain notice if code is later used |
| NextLevel | Mature Swift media-capture patterns | Reference only; project does not currently need a dependency | MIT; avoid dependency unless justified |
| Boothie | SwiftUI photo strips, timer, date, sharing | Confirms commonness, not uniqueness | Inspect license before any copying |
| lumen-raw | Burst grouping, eyes-open then sharpness ranking | Behavioral reference for local best-frame selection | Inspect license/models separately before any reuse |
| Film-Standalone / shader references | Multi-stage grain, bloom, CA, edge softness | Algorithm research only; translate concepts into original Metal/Core Image work | No reuse until license is verified |
| TrackOSC / Vision examples | On-device hand/body/face tracking | Gesture shutter feasibility | Check repository license before reuse |

## Ideas accepted into PocketCCD

1. **Render parity:** preview and export share one camera recipe.
2. **CCD noise decomposition:** stable sensor pattern plus per-shot noise and Bayer artifacts.
3. **Dual Memory:** simultaneous photographer/subject capture on supported devices.
4. **Private best-frame selection:** open eyes first, sharpness second, originals retained.
5. **Physical shutter support:** volume buttons and Camera Control through public APIs.
6. **Gesture group shutter:** experimental, scoped to timer/group mode.

## Ideas rejected or deferred

- generic photo booth with stickers and large frame catalog;
- adopting a heavy third-party camera framework before the custom pipeline requires it;
- copying large film-emulation shader stacks that do not model compact digital cameras;
- cloud face analysis for burst selection;
- always-on gesture recognition;
- dual-camera video before the still-photo proposition is validated.

## Original PocketCCD concepts derived from the research

### Dual Memory Card

Not a conventional picture-in-picture photo. Save three outputs from one press:

1. the rear-camera memory;
2. the photographer's reaction;
3. a minimal PocketCCD card that pairs them with timestamp and camera identity.

This is more emotionally specific than “dual camera” and can be shared without permanently baking the selfie into the main photo.

### Sensor Passport

Each fictional camera gets a documented sensor model: fixed-pattern seed, shadow chroma response, highlight clipping order, banding tendency, JPEG block size/strength, and white-balance bias. A user can optionally view this as a playful “passport,” but the parameters remain stable and drive real rendering.

### Flash Sequence

One press captures a tiny narrative rather than an indiscriminate burst:

- frame A: ambient light immediately before flash;
- frame B: direct-flash hero frame;
- optional frame C: immediate after-flash reaction.

The user receives all originals plus an automatically arranged three-frame Story/contact sheet. This combines Flash Pair, burst selection, and social output into a recognizable PocketCCD signature.

## License and dependency rule

- Do not paste code from a repository with no verified license.
- For MIT/Apache-licensed code, preserve required notices and record the exact source/commit.
- Treat model weights, LUTs, sample images, fonts, and sounds as separately licensed assets.
- Prefer original implementation of small algorithms to adding a large dependency.
- Add a third-party notices file before shipping any external code or asset.

