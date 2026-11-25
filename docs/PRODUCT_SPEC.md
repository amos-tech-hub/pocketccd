# PocketCCD Product Feature Specification

Status: working product definition  
Last updated: 2026-11-12

## 1. Product summary

PocketCCD is a lightweight iPhone camera that recreates the behavior and emotional character of a small early-2000s digital camera.

It is not a filter marketplace or a full photo editor. Its defining idea is that the camera reacts to light, flash, exposure, and the selected fictional sensor while the photo is captured. The result should feel produced by a particular camera rather than decorated afterward.

Core promise:

> A pocket CCD camera that makes direct-flash memories of friends feel real, immediate, and worth sharing.

## 2. Target use cases

Primary:

- friends taking direct-flash photos at restaurants, parties, concerts, and at night;
- everyday photos that should feel like an old compact digital camera;
- users who want a finished image without editing controls;
- quick Instagram Story and social sharing.

Secondary:

- daytime travel and street snapshots;
- importing an existing photo to apply a selected PocketCCD camera response;
- collecting a day or weekend into a roll or contact sheet.

## 3. Product principles

1. **Camera behavior over filter count.** A few recognizable cameras are better than hundreds of presets.
2. **Capture over editing.** The main interaction is choosing a camera and pressing the shutter.
3. **Preview and result should agree.** Live preview and full-resolution output use the same camera recipe.
4. **Imperfection must be intentional.** Noise, bloom, color drift, and compression should respond to the scene rather than appear as random decoration.
5. **Private by default.** Processing and selection happen on device; no account is required.
6. **Fast and dependable.** Launch, shutter response, saving, and returning from sharing are more important than feature breadth.

## 4. Main user flow

1. Open PocketCCD directly into the viewfinder.
2. Select one of a small number of fictional cameras.
3. Optionally adjust flash, exposure, date stamp, focus, and zoom.
4. Press the on-screen shutter, volume button, or supported Camera Control.
5. PocketCCD captures and renders the scene using the selected camera's sensor behavior.
6. Review the result.
7. Save, open the native share sheet, or send the image to Instagram Story.
8. Return to the camera with the result still available if sharing was cancelled.

## 5. MVP — prove the camera

### 5.1 Live camera

- rear and front camera switching;
- tap to focus with a visible reticle;
- pinch to zoom with zoom readout;
- exposure compensation from -2 to +2 EV;
- flash auto/off initially;
- physical shutter feedback, shutter flash, and haptics;
- optional date stamp;
- photo import through `PhotosPicker`;
- add-only photo-library saving.

Most of this foundation already exists in the proof of concept.

### 5.2 Four fictional CCD cameras

The existing visual looks evolve into stable camera identities. Each camera has
a model code (the identifier used in metadata, receipts and purchase rows) and a
two-word name (what people say out loud, shown in the camera strip):

- **Pocket C1 · Cold Sharp** — cool color, crisp JPEG character, hard flash, early-2000s budget CCD;
- **Pocket A7 · Warm 2003** — warmer skin, orange date stamp, family and travel character;
- **Pocket A8 · Party Flash** — harsh direct flash, black background, free-tier party camera;
- **Pocket N2 · Green Grain** — green-biased shadows, visible night noise, sodium-street character.

Names are localized (`Warm 2003` / `暖调 2003`); the model code never changes.

Each camera owns:

- color and tone response;
- shadow noise and color behavior;
- highlight clipping and bloom;
- sharpening and compression character;
- white-balance bias;
- flash behavior;
- aspect ratio and date treatment;
- interface accent and shutter sound.

### 5.3 Scene-responsive CCD rendering

The rendering engine should model:

- luminance-dependent chroma noise;
- stable sensor-pattern noise plus per-shot noise;
- dark-area banding and color drift;
- Bayer/demosaicing artifacts where appropriate;
- highlight bloom and channel clipping;
- brightness-dependent chromatic aberration;
- corner softness and lens character;
- exposure-dependent sharpening and JPEG artifacts;
- direct-flash subject/background falloff.

The preview may run at reduced resolution, but it must use the same recipe and parameters as the final image.

### 5.4 Result and sharing

- Save to Photos;
- native iOS share sheet;
- dedicated Instagram Story shortcut;
- Facebook and other installed apps available through the share sheet;
- no silent publishing to personal social accounts;
- cancellation never reports success or discards the current result.

## 6. V1 — own direct-flash memories

### 6.1 Flash Party mode

A one-tap mode optimized for indoor and nighttime photos of friends:

- direct-flash exposure and color treatment;
- short three-frame burst where supported;
- local best-frame suggestion: open eyes first, then sharpness;
- keep all originals and let the user override the suggestion;
- immediate 9:16 Story output.

### 6.2 Flash Pair

Capture an ambient frame and a direct-flash frame. Provide:

- both original images;
- a minimal diptych;
- a swipe-friendly two-image social export.

### 6.3 Flash Sequence

An optional three-beat memory:

1. ambient moment;
2. direct-flash hero frame;
3. immediate after-flash reaction.

PocketCCD saves the originals and creates a restrained Story/contact-sheet layout.

### 6.4 Physical shutter controls

- volume-button capture through public APIs;
- Camera Control full-press capture on supported devices;
- stable, generously sized on-screen shutter.

## 7. V1.5 — turn captures into memories

### 7.1 Pocket Roll

- group 12 or 24 captures into a roll;
- instant review by default;
- optional delayed-development mode;
- organize by fictional camera and date without building a full editor library.

### 7.2 Automatic contact sheet

- generate a day, weekend, Flash Party, or roll summary;
- square and 9:16 layouts;
- show restrained metadata such as camera, date, flash state, and sequence number;
- no freeform layers, stickers, or complex editing UI.

### 7.3 Camera Receipt

An optional share card showing the fictional camera, date, flash state, focal length, and roll number. The original photo remains clean and unwatermarked.

### 7.4 Sensor Passport

Give every fictional camera a stable technical identity, including fixed-pattern seed, shadow response, clipping behavior, banding tendency, JPEG character, and white-balance bias. The passport is playful product flavor backed by actual rendering parameters.

## 8. Experimental features

### 8.1 Dual Memory

On supported devices, capture the rear-camera scene and the photographer's front-camera reaction simultaneously.

Outputs:

- clean rear-camera original;
- clean front-camera reaction;
- optional paired memory card.

Unsupported devices receive an explicitly labeled guided sequential fallback.

### 8.2 Gesture group shutter

- available only in timer/group mode;
- a deliberate hand gesture starts a visible countdown;
- require several stable detections to prevent accidental capture;
- entirely on-device.

### 8.3 Per-install sensor fingerprint

Assign subtle persistent sensor characteristics to an installation. It must remain restrained, be switchable, and never visibly ruin a capture.

### 8.4 Two-device paired capture

Synchronize two nearby PocketCCD devices to create simultaneous viewpoints and an automatic diptych. Explore only after the single-device product has demonstrated retention.

## 9. Explicit non-goals

- hundreds of filters or cameras;
- generic AI style transfer;
- beauty retouching;
- a full layer/timeline photo editor;
- an in-app social feed;
- mandatory accounts or cloud processing;
- aggressive weekly subscription;
- video/VHS before the still-photo proposition is proven;
- silent posting to Instagram or Facebook.

## 10. Business model hypothesis

Recommended initial structure:

- one meaningful free camera;
- full initial camera set available through a $9.99–$14.99 lifetime unlock;
- the lifetime unlock covers the launch cameras and their refinements, not every future product;
- no capture-count restriction discovered after onboarding;
- consider subscription only if recurring camera releases create demonstrated ongoing value.

## 11. Validation gates

### Visual differentiation

- complete the 30-scene set across daylight, indoor flash, and night;
- in blind comparison, at least 60% of target users identify PocketCCD as more like a real old digital camera than fixed-filter alternatives;
- users can distinguish all three fictional cameras and express a clear favorite.

### Flash use case

- run at least ten real group/night sessions;
- people photographed prefer the chosen PocketCCD frame over the stock Camera frame at least 60% of the time;
- measure whether Flash Pair or Flash Sequence is shared more often than a single image.

### Product quality

- no false save success;
- cancelled sharing preserves the result;
- preview and output remain visually consistent;
- launch and shutter latency remain low enough that the camera feels immediate;
- all camera and sharing paths are verified on physical iPhones.

### Business validation

- monitor activation, D7/D30 retention, share rate, and unlock conversion;
- base economic target: approximately 25,000 MAU at 2% paid conversion;
- do not use paid acquisition until organic sharing and retention are demonstrated.

## 12. Recommended delivery order

1. Validate and tune the current three looks on the 30-scene set.
2. Unify preview and full-resolution rendering recipes.
3. Build the scene-responsive CCD primitives.
4. Rename and complete the three fictional cameras.
5. Add reliable Save, Share, and Instagram Story actions.
6. Prototype Flash Party and local best-frame selection.
7. Test Flash Pair and Flash Sequence in real group sessions.
8. Add Pocket Roll and automatic contact sheets if sharing behavior validates them.
9. Prototype Dual Memory only after the core single-camera experience is stable.

