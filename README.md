# Pocket CCD

An iPhone-only proof of concept for a paid nostalgic CCD camera app. App Store display name: **Pocket CCD**.

## Included

- Live camera preview
- Front/back camera switching
- On/off/auto flash, cycled directly from the camera HUD
- Five CCD cameras with a model code and a spoken name (A7 · Warm 2003, A8 · Party Flash, C1 · Cold Sharp, N2 · Green Grain, M1 · Silver Mono)
- Tap-to-focus with a visible focus reticle
- Pinch-to-zoom with an on-screen zoom readout
- Exposure compensation from -2 to +2 EV
- 3-second and 10-second self-timer with full-screen countdown
- 4:3, 1:1, and 16:9 capture ratios with matching output crop
- Optional rule-of-thirds composition grid
- Persistent grid, date-stamp, and aspect-ratio preferences
- Optional date stamp
- Photo import through `PhotosPicker`
- Add-only photo library saving
- CCD-style highlight bloom, sensor grain, shutter flash, and haptic feedback
- Real-time Core Image look preview at a frame-rate-conscious 24 fps
- Automatic device-aware 0.5×, 1×, and telephoto lens selection
- Manual ISO and shutter-speed controls with automatic device clamping
- Manual 3000–8000K white balance plus an auto-white-balance reset
- Optional automatic saving with add-only Photos permission
- Result-screen save progress, success state, retry messaging, and system sharing
- Mirrored front-camera live preview with orientation-aware frame processing
- In-app eight-scene imaging benchmark with guided capture overlays
- Persistent calibration records containing lens, exposure, ISO, shutter, white balance, and image metrics
- CSV benchmark report export containing only Pocket CCD captures, for offline fitting and regression review
- Two-second Pocket Moment capture with CCD-rendered video, local best-frame selection, and photo/video/Live Photo output
- Per-camera Pocket Roll color consistency, diagnosis-driven non-destructive rescue, and automatic 9:16 day videos
- Roll titles, per-photo notes, and merge-safe local backup export/restore

## Brand

The app icon, wordmark, and logo usage rules live in [`brand/`](brand/README.md).
The icon is wired into `Assets.xcassets/AppIcon.appiconset` and regenerated with
`python3 scripts/generate_logo.py`.

## Run

Open `PocketCCD.xcodeproj`, select a development team, and run on a physical iPhone. The Simulator has no usable camera feed.

Tap the viewfinder to focus, pinch it to zoom, and use the sun slider to compensate exposure before taking a photo.
Use the labeled controls above the viewfinder to change flash, timer, and capture ratio. The settings button contains persistent viewfinder options.
Use the lens readout beside the shutter to switch among the physical cameras available on the current iPhone. Manual exposure and white balance live in Camera Setup; unsupported values are safely clamped to the active camera format.

## Validation goal

Use the controlled eight-scene matrix in [`Research/CompetitiveImagingBenchmark.md`](Research/CompetitiveImagingBenchmark.md). Capture three repetitions per cell across daylight, indoor direct flash, night, and skin-tone scenes; keep only looks that remain distinguishable without labels and stay inside their clipping, color-balance, saturation, black-floor, and sharpness tolerances.

Analyze owned JPEG/PNG/HEIC fixtures without third-party dependencies:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/Pocket CCDClangCache \
SWIFT_MODULECACHE_PATH=/tmp/Pocket CCDSwiftCache \
xcrun swift Research/analyze_samples.swift Research/Samples/pocketccd Research/Samples/face-rois.csv
```

The ROI CSV is optional. Copy `Research/face-rois.example.csv` and record one
normalized top-left-origin face rectangle per matched image when evaluating skin
tone and flash clipping.

For on-device collection, open **Camera Setup → Pocket Lab → Imaging benchmark**, select one D01–S02 scene, return to the camera, and take three repetitions. Pocket CCD records the active scene automatically and can export the resulting CSV from the benchmark screen. The lab accepts no competitor images: ProCCD and other reference captures remain in the development-only offline analysis workflow.

## Social sharing

Implemented on the photo result screen (`SocialSharing.swift`). Instagram Stories deep-link sharing needs a non-empty `PocketCCDInstagramAppID` in `Info.plist` before it works reliably.

The verified feature inventory and the 2026-11 market read are in [`docs/FEATURE_INVENTORY_AND_MARKET_2026-11.md`](docs/FEATURE_INVENTORY_AND_MARKET_2026-11.md).

- **Save** — keep the existing add-only Photos workflow.
- **Share** — present the native iOS share sheet so the user can choose Instagram, Facebook, Messages, and other installed apps.
- **Instagram Story** — provide a dedicated shortcut that opens the Instagram Story composer with the rendered photo already attached.

The user must review and confirm the post in Instagram or Facebook. Pocket CCD will not attempt silent posting to personal social accounts. Automated publishing APIs require account authentication, additional permissions, and—in Instagram's case—typically a professional account, so they are outside the initial scope.

### Acceptance criteria

- Sharing uses the final rendered image, including the selected CCD look and optional date stamp.
- The share sheet works without requiring a Pocket CCD account or Meta SDK integration.
- The Instagram Story button is shown only when the destination is available; otherwise the app provides a clear fallback to the share sheet.
- Cancelling or returning from another app preserves the captured image and does not report a false success.
- The implementation is verified on a physical iPhone with current Instagram and Facebook apps.

## Product research

Differentiation ideas, competitive hypotheses, non-goals, and the ongoing research backlog are maintained in [`docs/PRODUCT_RESEARCH.md`](docs/PRODUCT_RESEARCH.md).

The current consolidated feature definition and delivery scope are maintained in [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md).
