# PocketCCD Differentiated Product Backlog

This backlog converts competitive findings into PocketCCD product work. Inclusion here does not mean immediate implementation; each item has a validation gate.

Implementation note (2026-11-13): all product and experimental concepts below now have working in-app implementations or an explicitly labeled safe fallback. See `IMPLEMENTATION_STATUS.md` for build evidence, hardware validation boundaries, and external credentials still required for release.

## Next roadmap — melog and PixCake findings

### P0 — Roll Consistency

- stabilize bounded color drift inside Flash Party, Flash Pair, and Flash Sequence captures;
- preserve intentional ambient-versus-flash exposure and color differences;
- extend consistency to Pocket Roll only after cross-scene tests show that it does not flatten camera character;
- validate with repeated indoor mixed-light sequences and compare per-frame neutral-color variance.

Implemented 2026-11-13: multi-frame captures establish a raw-frame color anchor and apply a camera-mode-specific, luminance-neutral correction capped at six percent per channel. Each Pocket Roll also maintains a slow-moving reference per fictional camera; Flash Party receives the strongest stabilization while Pair, Sequence, Moment, and single captures remain deliberately restrained.

### P1 — Pocket Moment

- one shutter press records a fixed two-second moment;
- recommend a still frame locally while retaining the original clip;
- export a still, Live Photo, or two-second video;
- add the result to the current Pocket Roll without introducing a video editor.

Implemented: the clip is rendered with the active CCD recipe, three candidate stills remain selectable, and the result can be saved as a photo, video, or correctly paired Live Photo.

### P1 — CCD-aware Accident Rescue

- detect a small set of recoverable failures: face shadow, clipped flash highlight, excessive night chroma noise, and mild motion blur;
- offer one non-destructive repaired alternative only when a problem is detected;
- keep the original and preserve the active Pocket camera recipe.

Implemented: Vision face regions and image statistics classify the supported failure modes; exposure correction is face-local, denoise/sharpen are conditional, and rescue never overwrites the original.

### P2 — memory-product details

- roll title and one short line of text per capture;
- local and iCloud backup exploration;
- automatic day-summary only after Pocket Moment retention is validated.

Implemented: notes and titles persist, backups export and import as a local `.pocketccdbackup` file, and a chronological 9:16 Pocket Day video can be generated from the current roll. Automatic iCloud sync is **not** implemented.

### Explicit boundaries

- no beauty reshaping, makeup, sky replacement, generative scene editing, or general layer editor;
- no user-facing arbitrary reference-image color cloning;
- no global look-strength slider that weakens the identity of Pocket A7, C1, or N2.

## Product rule

Every major feature should strengthen at least one of these promises:

1. PocketCCD behaves like a real compact digital camera.
2. PocketCCD is unusually good for direct-flash photos of friends.
3. PocketCCD turns a group of ordinary photos into a shareable memory without becoming an editor.

## P0 — prove the visual moat

### Scene-responsive CCD pipeline

Replace uniform fixed effects with camera-specific response curves driven by scene conditions:

- luminance-dependent chroma noise and shadow color drift;
- channel clipping and highlight bloom;
- chromatic aberration and corner softness;
- ISO/exposure-dependent sharpening and compression artifacts;
- camera-specific auto-white-balance bias;
- direct-flash falloff and face-safe highlight handling.

The live preview and exported still must use the same camera recipe. Preview may reduce working resolution for speed, but it must not substitute a different visual effect.

Digital noise must be decomposed into a stable camera-specific sensor pattern and per-capture shot/read noise rather than treated as generic film grain.

Validation: shoot the same 30-scene set with PocketCCD and fixed-filter competitors. In a blind test, at least 60% of target users should identify PocketCCD as “more like a real old digital camera.”

### Three durable camera personalities

Evolve the current Amber, Blue, and Pink looks into named cameras with stable rendering behavior, interface accents, date treatment, aspect ratio, and sound.

Initial direction:

- Pocket C1: cool, crunchy, hard-flash early-2000s CCD;
- Pocket A7: warm skin, orange date stamp, family-travel compact;
- Pocket N2: green-biased shadows, visible night noise, party camera.

Validation: users should be able to distinguish all three without being shown their names and should express a clear favorite.

## P1 — own a use case

### Flash Party mode

- one-tap direct-flash setup;
- short burst capture;
- select the sharpest/open-eyes candidate locally when feasible;
- tune flash response around subject distance and face highlights;
- offer immediate Save, Share, and Instagram Story actions.

When burst selection is enabled, rank open eyes before sharpness using on-device analysis, retain all originals, and let the user override the suggestion.

Validation: in ten real indoor/night group sessions, the chosen PocketCCD frame should be preferred over the stock Camera frame at least 60% of the time by the people photographed.

### Flash Pair — differentiating creative format

Capture an ambient frame and a direct-flash frame as a deliberate pair. Export them as two originals, a swipe carousel, or a minimal diptych. This turns a technical constraint into a recognizable PocketCCD format.

Validation: measure whether users share the pair more often than a single result.

### Flash Sequence — signature output experiment

Extend Flash Pair into an optional three-beat capture: ambient moment, direct-flash hero frame, and immediate reaction. Export all originals plus a restrained 9:16 sequence card. This should feel like a tiny memory, not an indiscriminate burst.

### Physical shutter controls

Support volume-button capture and Camera Control full-press on compatible systems using public APIs. The on-screen shutter must remain large and positionally stable.

### Reliable result screen and social handoff

- Save using add-only Photos access;
- native iOS share sheet;
- dedicated Instagram Story shortcut;
- preserve the result after cancellation or app switching;
- never show success before the destination confirms completion.

## P2 — turn photos into memories

### Pocket Roll

Group 12 or 24 captures into a lightweight roll. Normal mode remains instant; roll mode can optionally hide results until development.

### Automatic contact sheet

Create a restrained, branded sheet from a day, weekend, or roll. Include only useful metadata: fictional camera, date, flash state, and sequence number. Export square and 9:16 variants without exposing a full editor.

### Camera Receipt

Offer an optional small share card showing the fictional camera, date, flash, focal length, and roll number. This supplies social attribution and reinforces camera identity without watermarking the original.

### Dual Memory

On devices that support simultaneous multi-camera capture, record the rear-camera memory and the photographer's front-camera reaction from one shutter press. Save both originals plus an optional minimal paired card. Fall back explicitly to a guided sequential capture on unsupported devices rather than silently changing behavior.

### Sensor Passport

Give each fictional camera a stable technical identity: fixed-pattern seed, shadow chroma response, clipping order, banding tendency, JPEG behavior, and white-balance bias. The passport is user-facing flavor backed by real rendering parameters.

## P3 — retention experiments

### Per-install sensor fingerprint

Assign subtle persistent characteristics such as hot pixels, shadow tint, and noise response. It must never visibly ruin a photo and needs an off switch.

### Accident Keeper

At the end of a roll, surface one technically imperfect but emotionally interesting frame—motion, blink, flare, or partial composition—as an optional “keeper.” Keep selection on-device and never delete alternatives.

### Paired capture

Explore local two-device synchronization for simultaneous viewpoints and automatic diptychs only after single-device retention is proven.

### Gesture group shutter

Inside timer/group mode only, allow a deliberate hand gesture to begin a visible countdown. Require several stable frames, keep processing on device, and make cancellation obvious.

## Explicitly rejected for now

- hundreds of filters or cameras;
- generic AI style transfer;
- beauty tools;
- full timeline/layer editor;
- social feed and accounts;
- weekly subscription paywall;
- video/VHS before the still-photo proposition is proven.

## Recommended implementation order

1. Finish the 30-scene baseline and blind visual test.
2. Build scene-responsive rendering primitives.
3. Turn the current three looks into stable named cameras.
4. Add result-screen sharing.
5. Prototype Flash Party and Flash Pair.
6. Test Flash Sequence in real night/group sessions.
7. Add physical shutter controls and private best-frame selection.
8. Add contact sheets only after users consistently keep and share captures.
9. Prototype Dual Memory after the single-camera rendering path is stable.


