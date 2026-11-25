# PocketCCD Implementation Status

Last updated: 2026-11-13

## Implemented

- Unified scene-responsive CCD recipe for live preview and full-resolution export.
- Capture- and roll-level color anchoring per fictional camera, with a slow-moving reference and bounded luminance-neutral correction that reduces white-balance drift without flattening ambient/flash differences.
- Pocket Moment fixed two-second capture with optional sound, three scored still candidates, full-motion CCD rendering, separate photo/video export, and paired Live Photo creation.
- Diagnosis-driven, non-destructive Gentle Rescue for face shadow, clipped face highlights, excessive low-light chroma noise, and low detail; face exposure correction is locally masked and the original remains immediately restorable.
- Persistent Pocket Roll title and short note, retained with developed roll archives.
- Pocket Moment samples three candidate stills across the clip, recommends locally using face/eye/detail scoring, and keeps manual selection available.
- Per-capture one-line notes persisted into the current Pocket Roll.
- Automatic 9:16 Pocket Day video export with chronological photos, restrained motion, roll title/note, camera identity, and capture time.
- Manual Pocket Roll backup export (share sheet to Files or iCloud Drive) and merge-safe restore. No automatic ubiquity backup is implemented; `PocketCCD.entitlements` stays empty on purpose.
- Versioned local Pocket Roll backup export containing current/developed rolls, metadata, notes, and image data; the system share sheet can place it in Files or iCloud Drive.
- Non-destructive backup restore that merges new photos and archives, preserves existing rolls, and moves current-roll overflow into a developed archive.
- Three persistent fictional cameras: Pocket A7, Pocket C1, and Pocket N2.
- Stable per-install sensor identity used by rendering, with a user-facing Sensor Passport.
- Standard, Flash Party, Flash Pair, and Flash Sequence capture modes.
- On-device face/eye and sharpness scoring with suggested best frame; all alternatives remain selectable.
- Best-frame selection uses explicit face-aware ordering: meaningful eye-openness differences rank before sharpness, then overall face/detail quality breaks ties.
- Tap focus, pinch zoom, lens selection, exposure compensation, manual ISO/shutter, white balance, grid, timer, date stamp, import, haptics, and camera switching.
- Public `AVCaptureEventInteraction` hardware shutter support on iOS 17.2+.
- Add-only Photos saving, native share sheet (including Facebook when installed), Instagram Story handoff, camera receipt, and multi-frame sequence sharing.
- Pocket Roll persistence, 24-frame rolls, optional delayed preview, and automatic branded contact-sheet export.
- Full-roll data protection: captures never silently erase a completed roll; starting over requires an explicit destructive confirmation.
- Completed rolls are archived instead of deleted, remain browsable by date, and can be re-exported as square or Story contact sheets; permanent deletion is scoped to one archive and requires confirmation.
- Square and 9:16 contact-sheet exports, plus an on-device Accident Keeper suggestion that never removes alternatives.
- On-device open-hand group shutter gated behind the 3s/10s timer with three stable detections.
- Timer and gesture countdowns have an obvious cancel action; camera-changing controls lock for the complete multi-frame operation.
- Capture-session interruptions show a recovery banner, and media-service resets attempt an automatic restart.
- Dual Memory simultaneous front/rear capture through `AVCaptureMultiCamSession` on supported devices, with an explicitly labeled guided sequential fallback; both originals are retained and shown as a pair.
- Nearby two-device discovery, encrypted peer session, synchronized shutter command, and local reduced-copy exchange for the second viewpoint.
- Paired capture now exits configuration UI before firing both shutters, clears stale peer images per session, and exposes an automatic 9:16 two-viewpoint diptych from the result share menu.

## Validation completed

- Debug build succeeds for the iOS Simulator SDK.
- App installs and launches on an iPhone 17 simulator.
- First-launch camera permission UI and the complete camera chrome render correctly.
- Camera chrome has been checked at iPhone 17 size with no observed clipping or control overflow; deep camera-only flows remain physical-device checks.

## Physical-device validation required

These are implemented but cannot be meaningfully certified in Simulator:

- real flash timing and the three-frame capture cadence;
- physical volume/Camera Control shutter events;
- camera lens availability, manual exposure limits, and focus behavior;
- Photos add-only authorization and Instagram app handoff;
- two-iPhone Multipeer discovery, synchronization skew, and disconnect recovery;
- hand-pose false-positive rate in real group scenes;
- thermal and memory behavior during long rolls.

Dual Memory capability-checks `AVCaptureMultiCamSession` at runtime. Supported devices use simultaneous capture; other devices show and use the guided sequential fallback. Timing and resource pressure still require physical-device validation.

## External configuration

- Instagram Stories: production Meta app ID `1881548479664873` is in `PocketCCDInstagramAppID` (set 2026-11-18). The handoff URL now carries `?source_application=` as well as the pasteboard key, and a three-case failure (not configured / Instagram unavailable / image not encodable) replaces the old single "install Instagram" alert. Still a device check: the Meta app must have an iOS platform whose bundle ID is `work.doublenine.pocketccd`.
- App Store metadata, privacy answers, screenshots, and signing assets are release operations rather than runtime features.


## A-direction interface pass (2026-11-14)

The camera chrome and the supporting screens were rebuilt to the approved
“instrument” direction (`design-demos/home-drafts/A-states`).

- Top row: 36 pt square controls (flash pill, mode + timer pill, flip, roll with
  count badge, settings) with 44 pt hit targets; the old 44 pt rounded buttons
  and the miniature-camera look selector are gone.
- Look strip: three equal 38 pt segments with a status dot, look name and the
  `stripCaption` micro line; the selected segment carries a 1 pt amber border.
- Exposure: a 24 pt `EV ±0.0` chip that expands to a 16 pt track with a 12 pt
  knob driven by a drag gesture.
- Shutter row: 44 pt import target, 72 pt ring shutter, 68 × 36 lens pill.
- Viewfinder: the status readout moved from the bottom-left capsule to a 26 pt
  square chip under the top tools, and a locale-formatted date stamp now previews
  in the viewfinder when the date stamp is enabled (same formatter as the burn-in).
- Shooting Mode sheet: card buttons (94 pt) with monospaced captions, the moment
  mode spanning the full width.
- Result screen: paper ground, white-bordered photo card, monospaced meta rows,
  ink-filled save button; light color scheme while presented.
- Camera Setup: square sections, 50 pt rows, monospaced values, flat dividers.
- Pocket Roll: `05 / 24` monospaced counter, 2 pt progress line, square action
  buttons with monospaced labels.

Build status: `xcodebuild … -destination 'generic/platform=iOS Simulator'` succeeds.
Visual verification of the camera chrome still requires a physical device — the
Simulator reports `configurationFailed` and shows the unavailable state instead of
the viewfinder.

## Full interface sweep (2026-11-14, second pass)

Every user-facing screen now uses the same instrument vocabulary: `#0B0C0A`
ground, `#11120F` panel, 1 pt `#33362F` hairlines, 50 pt rows, 36 pt controls,
8–9 pt monospaced labels, amber reserved for the active state.

Converted in this pass:

- Camera overlays: first-photo guide, countdown, capture progress, interruption
  banner, focus reticle (amber brackets), permission and unavailable states.
- Manual Controls and More Ways to Shoot: `Form`/`List` replaced with scrollable
  section panels; `ProValueSlider` uses monospaced labels and an amber track.
- Pocket Moment video preview: square save / save-as-Live-Photo buttons.
- Onboarding: monospaced header, square artwork, three-step pager, single filled
  action; paywall rebuilt around a paper-free dark panel with a one-line price
  button.
- Privacy, Camera Guide, About and Sensor Passport: section panels and labelled
  rows instead of `List` sections.
- Imaging Benchmark: progress panel with a 2 pt bar, scene rows with mono
  counters, report actions.
- Paired Capture: connected / nearby / other-viewpoint panels.
- Roll Archive and the image / video export previews.
- Pocket Roll empty state and the Accident Keeper suggestion card.

No `List`, `Form`, `ContentUnavailableView` or `borderedProminent` remains in the
target. Build stays green for `generic/platform=iOS Simulator`.

Verification boundary is unchanged: the Simulator still reports
`configurationFailed`, so the camera chrome and the capture-result sheet need a
physical device run before they can be called visually verified.

### Device pass 1 fixes (2026-11-15)

First physical-device screenshots surfaced five defects; all are fixed in code:

- **Lens pill wrapped.** `1× LENS` was squeezed into a 68 pt box and broke into
  three lines. The pill is now 56 pt wide with the lens value and a chevron only.
- **Roll page overflowed sideways.** The header card, grid and action bar were
  pushed past both screen edges because `Grid` sized its columns from the
  resizable thumbnails. `BalancedRollGrid` now uses a two-column `LazyVGrid`
  with flexible columns and caps its width.
- **Viewfinder corners were invisible.** They were inset from the full-screen
  viewport, so the top pair sat under the status bar and the bottom pair under
  the control panel. The overlay is now padded 146 pt from the top and 190 pt
  from the bottom so the brackets frame the visible photo area.
- **Exposure chip read `EV + 0.0`.** A stray space in the interpolated string is
  removed (`EV +0.0`).
- **Primary buttons disappeared on dark pages.** `PocketButton` filled state now
  uses the amber fill with black text instead of near-black on near-black.
- Roll badge shrunk and tucked into the corner of its button.

### Device pass 2 fixes (2026-11-15)

- **Return button wrapped.** `RETRY` was clamped to the 44 pt hit width and broke
  into two lines; the visual button now keeps intrinsic width with a 44 pt hit
  height.
- **Stray look chip.** The old black `A7` badge floated between the photo card and
  the metadata row; removed — the metadata row already names the camera.
- **Hard-coded frame number.** The result header claimed `IMG 0017` on every
  capture; it now reads `PREVIEW · HH:mm` until a real frame index exists.

### Date stamp format (2026-11-15)

The stamp is now fixed rather than locale-derived: `PocketDateStamp.text(for:)`
renders `05 11 ’26` (two-digit day, two-digit month, apostrophe, two-digit
year). The live viewfinder preview and `DateStampRenderer` share this one
function, so the preview always matches the burned-in photo. Receipt and paired
memory footers keep the locale date-time because they also print the time.

### Device pass 3 (2026-11-15): fidelity + speed

- **Viewfinder corners** were drawn against the full-screen viewport, so the
  bottom pair fell behind the control panel. They now live inside the chrome, in
  the clear area between the readout and the date stamp.
- **Lens picker** no longer opens the system `Menu` capsule; tapping the lens pill
  reveals a row of square lens chips above it, same border/amber language as the
  look strip. The zoom readout is also a square chip now.
- **Shooting Mode** presents full screen instead of a 500 pt system sheet, so no
  grabber or sheet corner shows.
- **Result** presents full screen and follows S2: preview label + close, title and
  subtitle, white-bordered photo, meta row, `RETRY` + `SAVE TO PHOTOS`, then
  `SHARE · NOTE · STORY`. The note field is hidden until NOTE is tapped.
- **Pocket Roll** was rebuilt against S3: dark surface, title + `05 / 24`, mono
  date line, three-column contact grid with a dashed “N MORE” slot, footer line
  and `EXPORT 9:16`. Contact sheet, Pocket Day, archive and backup moved into the
  ellipsis menu.
- **Capture latency**: colour-anchor sampling now runs on a 512 px proxy with a
  shared `CIContext` (was a full-resolution area average with a new context per
  shot); decoding, mirroring and the CCD render run off the main actor; roll
  writes, benchmark records and analytics now happen after the result sheet is
  presented, and auto-save updates the sheet when it finishes.

### Crash investigation (2026-11-15 00:30)

- No PocketCCD crash report exists on the device; the only evidence is a
  `JetsamEvent` at 23:57 where PocketCCD held ~59,875 pages (~1 GB on a 16 KB
  page device) under system memory pressure. That pattern is a memory kill, not a
  Swift exception.
- Console launch via `devicectl` ended with signal 9, which is what a detached
  console session produces; it is not conclusive on its own.
- Memory fixes: roll grid, archive strip, contact sheets and Pocket Day now
  decode through ImageIO thumbnails (720 / 240 / 1200 px) instead of full
  captures; `captureResult` is released when the result cover dismisses.
- App launches and renders onboarding correctly in the Simulator.

- Roll is now a `fullScreenCover` like result and shooting mode; its own top bar
  handles dismissal, so the duplicated system toolbar button is gone.

### Presentation sweep (2026-11-15)

Every screen now presents full screen with a hand-drawn bar; system navigation
bars and detent sheets are gone from the product surface.

- Full-screen covers: roll, shooting mode, result, paywall, Pocket Moment,
  contact sheet / Pocket Day previews, archive export preview.
- Custom top bars (`PocketDismissBar`: BACK / CLOSE / DONE) replace the system
  navigation bar on Camera Setup, Manual Controls, More Ways to Shoot, Privacy,
  Camera Guide, About, Paired Capture, Imaging Benchmark, Roll Archive and Sensor
  Passport.
- Only `ActivityShareSheet` still uses a system sheet, because it is the iOS share
  panel itself.
- Trade-off: hiding the navigation bar on pushed pages disables the interactive
  swipe-back gesture; the explicit BACK control is the way out.

### System chrome removed (2026-11-15)

Every system surface that could be replaced is now custom:

- `Menu` (roll actions, archive actions, result share) → `PocketSheet` with
  `PocketActionRow` rows.
- `confirmationDialog` (develop roll, contact-sheet format, delete archive, clear
  benchmark) → the same sheet component, with destructive rows in red.
- `alert` (status, save failure, Instagram, purchase message, backup, export
  previews) → `PocketAlert`, a centred panel with a single full-width action.
- `Toggle` → `PocketToggle`, a 42 × 24 square switch in amber.
- `Slider` → custom 2 pt track with a 12 pt knob and drag gesture.
- `navigationTitle` → zero remaining; every page draws its own bar.

Audit after the pass: 0 `Menu`, 0 `Toggle`, 0 `confirmationDialog`, 0 `alert`,
0 `navigationTitle`. What remains by design: `ActivityShareSheet` (the iOS share
panel), `PhotosPicker`, and the keyboard.

- Result dock reduced to three tiers: one 42 pt meta line (look, mode, optional
  SOFTER chip, time), a hairline, then `RETRY` + `SAVE TO PHOTOS`, then a single
  `SHARE · NOTE · STORY` line. The inline note field moved into a centred panel
  so the keyboard cannot cover it and the dock stays quiet.

### Roll header + scroll performance (2026-11-15)

- The separate CAMERA top bar is gone. The header now matches S3: back chevron,
  large roll title and `05 / 24` on one line, then the mono date line with the
  actions ellipsis on its right.
- Thumbnails decode off the main thread through `RollThumbnailCache` (NSCache,
  80 entries) and `RollThumbnailView`; grid cells use a fixed 3:4 slot so the
  lazy grid does not re-measure while scrolling.

- Camera Setup showed two back controls: a leftover `.toolbar(.visible, for: .navigationBar)`
  from the old styling re-enabled the system bar on top of the custom BACK row.
  The modifier is removed; no page re-enables the navigation bar now.

### Interaction polish (2026-11-15)

- `PocketSheet` now has a grab handle and can be dragged down to dismiss.
- The image export preview supports pinch and double-tap zoom (1×–5×).
- Pocket Day video and Pocket Moment: the CLOSE bar moved out of
  `safeAreaInset` into a VStack above the player, so the video no longer paints
  over the status bar and the clock stays readable.
- Swipe-back is restored on every pushed page: a `NavigationSwipeBackEnabler`
  re-arms `interactivePopGestureRecognizer` and only allows the gesture when the
  stack has more than one controller. Full-screen covers still dismiss through
  their own CLOSE/BACK control.

### Header polish + localization (2026-11-15)

- Camera Setup: the round summary card is gone. The page opens with a 26 pt
  “Camera Setup” title and one monospaced line (camera · ratio · save mode ·
  roll count), then the section panels.
- Paywall: the rotated two-camera deck is replaced by three 3:4 look-preview
  cards (A7 warm, C1 cool, N2 night) with a burned date stamp, look name,
  caption and a lock badge on the two paid cameras.
- Localization: every new label now goes through the String Catalog with
  zh-Hans and zh-Hant entries — settings sections and rows, look captions,
  result actions, roll actions and footer, capture progress, paired capture and
  the benchmark rows. `PocketButton` titles are resolved through
  `LocalizedStringKey`, and settings values no longer render verbatim.
  Brand tokens (`A7`, `4:3`, `POCKETCCD`, dates) stay as designed.

### Bug fixes + performance pass (2026-11-15)

- Paywall look cards now read `store.isFullUnlocked`; C1/N2 show the lock only
  while locked and animate away the moment the purchase completes.
- Roll’s empty slot uses the same 3:4 cell as photos (`Color.clear` +
  aspectRatio), so the dashed “N MORE” tile no longer stretches into a wide box.
- Contact-sheet export (both formats, including the footer EXPORT 9:16) renders
  off the main thread and shows a spinner on the button instead of freezing.
- Pocket Day decodes its source frames off the main thread before encoding.
- `RollThumbnailCache` now accounts per-image cost, caps at 64 MB and purges on
  a memory warning.

- Brand: the app icon was replaced with the v3 “P” traced from the supplied
  wordmark (`brand/v3/vector/icon.svg`), and `brand/PocketCCD-Icon-*.png` was
  regenerated from it. Wordmark SVGs (dark/light, with and without background)
  live in `brand/v3/vector/`. `scripts/generate_logo_v3.py` reproduces the trace
  from `pocketCCD_logo.png`.

- Brand: `brand/PocketCCD-Wordmark.svg` is now the canonical logo — the supplied
  artwork with the ground recoloured to `#0B0C0A`, texture (bevel, shadow, grain)
  untouched, embedded as a raster inside the SVG. The app icon uses the same art
  padded on black.

### Roll actions discoverability (2026-11-15)

A bare “…” in the header was the only entry to roll actions; it read as decoration.
Now:

- The header shows a bordered `⋯ MORE` chip with an accessibility label.
- Under the export row, `CONTACT SHEET` and `POCKET DAY` are visible buttons, so
  the two most-used actions no longer hide behind a menu. Pocket Day shows a
  spinner while it renders.
- The MORE sheet still carries everything: rename, both contact-sheet formats,
  Pocket Day, archive, backup/restore, develop.

### Roll header + owned state (2026-11-15)

- Pocket Roll now opens with the same `PocketDismissBar` (CLOSE) as every other
  presented page; the title row sits under it, so all screens share one header
  rhythm. The inline back chevron is gone.
- Settings · PocketCCD: when the non-consumable is owned the row is no longer a
  navigation link. It shows a check, “Unlocked” and one line of explanation.
  While locked, a “Restore Purchases” row sits underneath.
- `CameraSettingsView` refreshes entitlements on appear, so a purchase made
  earlier (or restored on another device) is reflected without relaunching.

### Export preview zoom (2026-11-15)

The contact-sheet preview used `MagnificationGesture` + `scaleEffect` inside a
two-axis ScrollView: the image grew past its clipped bounds, could not be panned,
and the zoom had no pinch anchor. Replaced with `ZoomableImage`, a UIScrollView
wrapper: real pinch from 1× to 6×, panning while zoomed, rubber-band back to fit,
and double-tap that zooms toward the tapped point.

- The capture result photo now uses the same `ZoomableImage` inside its white
  paper mat: pinch 1–6×, pan while zoomed, double-tap toward the tapped point.
  The old `scaleEffect`-based gesture (no panning, no anchor) is gone, and the
  mat keeps its photo aspect ratio.

### Free-tier export mark (2026-11-15)

Free saves, shares, story posts and contact-sheet exports now carry a small
`POCKETCCD` in the bottom-right — same amber mono as the date stamp, ~1.9 % of
the image width, with a soft shadow for legibility on light frames. It is
applied at the export boundary only (`PocketWatermark.applyForExport`), so the
in-app preview, roll thumbnails and archive stay clean. Owning the one-time
unlock returns unwatermarked files. Live Photos and videos are skipped for now:
re-encoding a paired still risks breaking the Live Photo.

- The free-tier mark is announced before it can surprise anyone: the result page
  shows one 7.5 pt monospaced line above RETRY/SAVE while the app is locked
  (“Free saves carry a small POCKETCCD mark. Unlock to remove it.”), and it stops
  appearing after the first successful save. The paywall’s INCLUDED list gained
  “Exports without the POCKETCCD mark”.

### Doc-gap batch (2026-11-15)

- **Watermark removed.** Saves, shares, stories and contact sheets are clean
  again; the paywall claim and the result-page notice went with it.
- **Delayed development works.** With the switch on, a capture goes straight to
  the roll and shows a toast instead of the result sheet.
- **Shutter sound.** Synthesised per camera (A7 soft, C1 crisp, N2 dull) with no
  audio assets, `.ambient` so it respects the ring switch, plus a settings toggle.
- **Roll size.** 12 or 24, chosen in Settings · Save & Roll; full-roll handling,
  the header counter and the contact sheet title all follow the setting.
- **Contact sheet metadata.** A mono line under the title: cameras, date span and
  frame count.
- **Flash falloff.** Captures taken with flash now get a hot centre, warm lift and
  a falloff into the background (`CCDLook.render(flash:)`).
- **Chromatic aberration + corner softness** per camera, applied to captures.
- **Calibration set** expanded from 8 to 30 scenes (10 daylight, 10 flash,
  10 night, 4 misc), each with a shot instruction and a suggested camera.
- `PRODUCT_BACKLOG.md`: the iCloud-sync claim now says local file backup.

### Original frames + remembered camera (2026-11-16)

Two promises the product made but the code did not keep.

- **The camera remembers itself.** Body, flash state and rear lens were `@State`,
  so every cold launch reset to Pocket A7 + automatic flash + 1×. They now live
  in `UserDefaults` (`pocketCCD.identity.*`, see `ShootingIdentity`), the body is
  read in `CameraScreen.init()` so the viewfinder never flashes A7 first, and the
  flash/lens are restored after `prepare()` once their availability is known. A
  non-default restore prints `RESUMED · A8 · FLASH · 1×` for 2.2 s instead of
  changing the camera silently; `RESUMED` is localized, the brand tokens are not.
  A refunded entitlement still falls back to A7, and a permission-denied launch
  does not consume the one-shot restore.
- **Originals are kept on disk when asked.** Settings · ORIGINALS · *Keep
  original frames* (off by default) writes the unprocessed capture bytes before
  any CCD rendering, one folder per shutter press, with a `capture.json` holding
  body, mode, lens, EV, ISO, shutter, kelvin, flash state and per-frame role /
  pixel size. Capped at 300 captures or 1.5 GB, oldest first, newest never
  removed; the settings row shows count and footprint with a confirmed clear.
  Roll, Photos saving and the result sheet are untouched — the write runs on the
  archive actor. Pocket Moment is excluded for now.

Build: `xcodebuild … -destination 'generic/platform=iOS Simulator'` passes
(arm64). Tests: 39 in 14 suites pass, including the identity round-trip,
corrupt-value fallback, archive pruning and a real on-disk write of one capture folder.

Still device-only: whether the restored identity actually survives a relaunch,
whether the resume hint collides with the status row, and how the archive write
affects burst cadence. Operational notes: `ORIGINALS_AND_IDENTITY_2026-11-16.md`.

### Camera chrome fidelity pass (2026-11-16)

Three defects reported from a device screenshot, all in the camera screen
(the section above still describes the three-body A1 layout; the look strip has
been four cards since A8 was added):

- **The corner brackets did not frame the photo.** The preview was centred on
  the whole screen while the brackets were laid out by the chrome's `VStack`, so
  the two disagreed by tens of points — inside the image at the top, well above
  the image at the bottom. The chrome now reports its middle slot through a
  `PreferenceKey`, `ViewfinderGeometry.fittedRect` sizes the photo inside that
  slot, and `CameraViewport` draws the grid, border, brackets and date stamp
  against that same rect. Nothing is positioned by guesswork any more.
- **The top toolbar floated in the middle of the screen.** `TopControls` used
  `ViewThatFits` with `.fixedSize(horizontal: true)`; the chosen row kept its
  ideal width and was centred, leaving margins on both sides. The row now fills
  the width, so the flash and mode pills sit at the left edge and the three
  square tools at the right, as in the A1 mock. The two-row fallback is gone;
  pill labels shrink instead of wrapping.
- **The shutter row had lost two A1 details.** The import slot shows the last
  frame again (the way a compact camera shows the previous shot), and the lens
  pill reads `1× 35MM` instead of a bare `1×`. `CameraLens.focalLengthLabel`
  holds the 35 mm equivalents (13/35/77); it is product flavour for a fictional
  body, not a spec claim.

Build green (arm64 Simulator); 42 tests in 15 suites pass, including new
`ViewfinderGeometry` cases for a tall slot, a short slot and an empty slot.
The camera chrome itself still cannot be rendered in the Simulator
(`configurationFailed`), so the spacing around the brackets and the new date
stamp position need one physical-device look.

### Roll index recovery (2026-11-16)

A capture could be visible in the roll and gone after the next launch: `add()`
wrote the JPEG, `persist()` wrote the manifest, and a failed manifest write was
discarded while nothing ever re-adopted files the index did not list.

- **Adoption on load.** `RollStore.load()` now reconciles the index against the
  directory: `jpg/jpeg` files referenced by neither the current roll nor an
  archive are re-attached to the current roll, ordered by file creation date,
  and persisted immediately so the next launch does not adopt them twice.
- **Reported, not silent.** `RollIndexHealth` carries `adopted`, `missing` and
  `writeFailed`; the camera screen shows one toast at launch
  (`Recovered N frames from disk`, `N frames are missing from this roll`,
  `Roll index could not be saved — frames stay on disk.`) and then clears it.
  Mid-session write failures are reported through `.onChange` because the
  launch report can only see the launch state.
- **Missing counted once.** A file can be referenced by both the current roll
  and an archive; the missing count de-duplicates by file name instead of
  counting the same loss twice.
- **No invented metadata.** An adopted frame becomes `POCKET ?`, not A7: the
  rendered JPEG carries no EXIF, so the body is genuinely unknown. The contact
  sheet's camera summary drops unknown bodies; the per-frame footer shows `?`.
- Adopted frames may push the roll past 24. Truth over tidiness: the counter
  shows 26/24 and the next shutter asks for a develop.

Build: `xcodebuild … build` (arm64 Simulator) passes. Tests: **46 in 16 suites**
pass, including the four new `Pocket Roll index` cases (adopt once, recover
after a failed manifest write, archives are not adopted, missing is reported).
Operational notes: `ROLL_INDEX_RECOVERY_2026-11-16.md`.

### Storage guard, Moment retention, preview parity, one-tap roll export (2026-11-16)

Four changes that turn the camera from "records" into "holds up on the night".

- **Storage guard.** `StorageGuard` classifies free space with
  `volumeAvailableCapacityForImportantUsage` as `ok` / `low` (600 MB) /
  `critical` (150 MB). `critical` blocks the shutter and Dual Memory, skips
  original-frame archiving, and makes `RollStore.add` refuse with its own
  message instead of claiming the roll is full. `low` warns once at launch.
  An unreadable volume counts as `ok` — a failed capacity query must never lock
  a shutter mid-party.
- **Moment clip retention.** The 2-second clip is a temporary file deleted when
  the result sheet goes away, so closing it without saving used to lose the clip
  for good. The close control now asks: `UNSAVED CLIP` offers *Save clip to
  Photos* (then closes) or *Close without saving* (red). Both the video and the
  Live Photo save paths mark the clip as kept.
- **Preview parity.** `CCDLook.livePreview` now receives `flashStrength`,
  `colorAnchor` and `consistencyStrength`, so the viewfinder runs the same
  stages in the same order as `render`. `LivePreviewPipeline` estimates `.auto`
  flash from frame luminance (0.16/0.24 hysteresis, sampled every 250 ms) and
  reads the roll anchor through the new read-only `RollStore.peekColorAnchor`
  — `colorAnchor(for:sample:)` writes on every call and would have pushed the
  anchor around at 24 fps. Stabilising is skipped at zero strength.
  Measured on a two-tone card: flash moves the mean by 0.205, while preview vs
  render now differ by 0.00003 (float16 quantisation) with flash and 0.00024
  without. `PreviewParityTests` fails if the flash gap ever exceeds 0.01.
- **One-tap roll export.** The roll's primary action is `EXPORT 9:16`, which
  renders and opens the preview directly; `FORMAT` opens the four-preset sheet
  and Pocket Day moved back into `⋯ MORE`. Exporting a roll is 2 taps instead
  of 5 (export → format → preview → share).

Build: `xcodebuild … build` (arm64 Simulator) passes. Tests: **52 in 18 suites**
pass, including `Preview parity`, `Storage guard` and the read-only anchor case.
Operational notes: `SHOOTING_TO_SHARING_2026-11-16.md`.

### Original-frame fixture reader (2026-11-16)

The regression gate for P2-F now has a reading half. `OriginalsFixtureReader`
(in the test target) decodes the `capture.json` files written by
`OriginalFrameArchive`, resolves the frames they list, and filters captures by
body (`POCKET A8`), flash state (`FLASH` / `NO FLASH` / `AUTO`) or mode
(`flashParty`). Malformed manifests are reported through `skipped` instead of
being ignored, and frames whose files are gone drop the capture into `skipped`
as well.

- Samples live in `Research/Samples/Originals/`, which ships with only a README
  and a `.gitignore` — real photos stay out of the repository. Set
  `POCKETCCD_ORIGINALS_DIR` to point at a container downloaded from Xcode.
- `Real capture parity` is gated on `.enabled(if:)`, so an empty directory
  skips the suite (the synthetic `Preview parity` suite keeps running) while a
  broken corpus fails loudly.
- The suite compares preview and export means on each real capture with a
  provisional 0.03 budget and prints one row per body (`REAL BODY POCKET A8
  n=…`), then `REAL FLASH …` rows.
- Measurements are region-scoped when the folder carries a `roi.json`
  (normalized, top-left origin: `background`, `faceLit`); without one the row is
  labelled `(whole-frame)` on purpose. A whole-frame p05 is **not** the tuning
  log's background — night-flash frames mix a black background and a lit face,
  so the two numbers are not comparable.
- The background row reports `bgP05` **and** `bgP50` **and** `bgBright` (share of
  pixels above luma 40). A p05 alone can be met by one black corner while the
  rest of the background is washed grey; `greyBackgroundIsNotMasked` pins that
  with a 10%-black / 90%-grey frame.
- Skin-ratio and black-floor thresholds stay unpinned until the corpus is real,
  and they are set per body: A7 and A8 do not share a gate. A folder whose
  `roi.json` cannot be parsed goes to `skipped` rather than silently falling
  back to whole-frame numbers.
- Verified once with a temporary generated sample (deleted afterwards): the
  simulator test process can read the checkout path, the reader round-trips, and
  an un-cropped comparison read 0.0137 while the cropped one read 0.0 — the test
  must crop to 4:3 first or it measures the crop instead of the recipe.
- Region mapping is covered by `regionMapping`, which failed on the first
  implementation because an added vertical flip inverted the ROI; `CGImage`
  rows are already top-down, so `context.draw` needs no flip.

Boundary: parity proves two software paths agree on one input. It does not prove
`.auto` flash prediction matches device EXIF; that still needs the dark-room
device comparison.

Build: `xcodebuild … build` (arm64 Simulator) passes. Tests: **60 in 20 suites**
pass with the real-sample suite skipped (empty fixture directory).
