import AVFoundation
import AVKit
import CoreTransferable
import ImageIO
import PhotosUI
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

struct CameraScreen: View {
    /// One coordinate space shared by the viewfinder and the chrome, so the
    /// photo rect and the brackets are computed from the same numbers.
    static let cameraSpace = "PocketCCDCameraSpace"

    @State private var camera = CameraController()
    @State private var viewfinderArea: CGRect = .zero
    @State private var selectedLook: CCDLook
    @State private var didRestoreIdentity = false
    @AppStorage(OriginalFrameArchive.enabledKey) private var keepOriginalFrames = false
    @AppStorage("dateStampEnabled") private var dateStampEnabled = true
    @AppStorage("gridEnabled") private var gridEnabled = true
    @AppStorage("captureAspectRatio") private var aspectRatio = CaptureAspectRatio.fourThree
    /// 35 mm or 50 mm. 50 mm is a centre crop of the same CCD frame, set in
    /// Camera Setup rather than next to the shutter, so the camera keeps its
    /// one-lens identity.
    @AppStorage("cameraFocalLength") private var focalLengthRaw = 35
    @AppStorage("dateStampFormat") private var dateStampFormatRaw = "dayMonthYear"
    @AppStorage("autoSaveEnabled") private var autoSaveEnabled = false
    @AppStorage("capturePreviewEnabled") private var capturePreviewEnabled = false
    @AppStorage("captureMode") private var captureMode = CaptureMode.standard
    @AppStorage("gestureShutterEnabled") private var gestureShutterEnabled = false
    @AppStorage("delayedRollEnabled") private var delayedRollEnabled = false
    @AppStorage("sensorFingerprintEnabled") private var sensorFingerprintEnabled = true
    @AppStorage("shutterSoundEnabled") private var shutterSoundEnabled = true
    @AppStorage("vintageLcdPreviewEnabled") private var vintageLcdPreviewEnabled = false
    @AppStorage("selfieFillLightEnabled") private var selfieFillLightEnabled = false
    @AppStorage("pocketCCD.rollCapacity") private var rollCapacity = 24
    @State private var captureResult: CaptureResult?
    @State private var resultIsTrial = false
    /// Last frame, shown in the import slot the way a real compact camera shows
    /// the previous shot.
    @State private var lastCaptureThumbnail: UIImage?
    @State private var noteEntryIDByFrame: [UUID: UUID] = [:]
    @State private var rollStore = RollStore.shared
    @State private var pairedCapture = PairedCaptureService()
    @State private var dualMemory = DualMemoryController()
    @State private var calibrationStore = CalibrationStore.shared
    @State private var pickedItem: PhotosPickerItem?
    @State private var statusMessage: LocalizedStringResource?
    @State private var showResult = false
    @State private var focusPoint: CGPoint?
    @State private var focusDismissTask: Task<Void, Never>?
    @State private var isDraggingViewfinderEV = false
    @State private var shutterFlash = false
    @State private var selfieFillLight: (screen: UIScreen, brightness: CGFloat)?
    @State private var timerMode = CaptureTimer.off
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var showSettings = false
    @State private var showRoll = false
    @State private var resultWasSaved = false
    @State private var rollSaveFailed = false
    @State private var isAutoSavingResult = false
    @State private var autoSavingResultID: UUID?
    @State private var captureProgress: (current: Int, total: Int)?
    @State private var isProcessingCapture = false
    @State private var inFlightRollWrites = 0
    @State private var toastMessage: LocalizedStringResource?
    @State private var purchaseStore = PurchaseStore.shared
    @State private var showUpgrade = false
    @State private var showRollFull = false
    @AppStorage("hasSeenCaptureGuide") private var hasSeenCaptureGuide = false
    @State private var showCaptureGuide = false
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Read the remembered body before the first frame so the viewfinder
        // never flashes A7 on the way to the camera the user actually uses.
        _selectedLook = State(initialValue: ShootingIdentity.look())
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.issue == .permissionDenied {
                CameraPermissionView()
            } else if camera.issue == .configurationFailed {
                CameraUnavailableView {
                    camera.issue = nil
                    Task { await camera.prepare() }
                }
            } else {
                viewfinderView
                CameraChrome(
                    selectedLook: $selectedLook,
                    timerMode: $timerMode,
                    captureMode: $captureMode,
                    pickedItem: $pickedItem,
                    flashMode: displayedFlashMode,
                    isFlashAvailable: camera.cameraPosition == .front ? captureMode == .standard : camera.isFlashAvailable,
                    isFrontCamera: camera.cameraPosition == .front,
                    availableLenses: camera.availableLenses,
                    selectedLens: camera.selectedLens,
                    exposureBias: camera.exposureBias,
                    isCapturing: camera.isCapturing || captureProgress != nil || isProcessingCapture,
                    isFullUnlocked: purchaseStore.isFullUnlocked,
                    lastThumbnail: lastCaptureThumbnail,
                    onLockedLook: { showUpgrade = true },
                    onFlash: toggleFlash,
                    onSwitchCamera: {
                        focusDismissTask?.cancel()
                        focusPoint = nil
                        Task { await camera.switchCamera() }
                    },
                    onLens: { lens in Task { await camera.switchLens(to: lens) } },
                    onExposure: camera.setExposureBias,
                    onExposureInteraction: { camera.previewPipeline.setInteraction(active: $0) },
                    rollCount: rollStore.entries.count,
                    onRoll: { showRoll = true },
                    onSettings: { showSettings = true },
                    onShutter: beginCapture
                )
            }

            if let countdown {
                CountdownOverlay(value: countdown, onCancel: cancelCountdown)
            }

            if let captureProgress {
                CaptureProgressOverlay(current: captureProgress.current, total: captureProgress.total)
            }

            if let toastMessage {
                VStack {
                    Spacer()
                    StatusToast(message: toastMessage)
                        .padding(.bottom, 156)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if let interruptionMessage = camera.interruptionMessage {
                VStack {
                    CameraInterruptionBanner(message: interruptionMessage) {
                        Task {
                            camera.interruptionMessage = nil
                            await camera.start()
                        }
                    }
                    .padding(.top, 62)
                    Spacer()
                }
                .padding(.horizontal, 16)
            }

            Color.white
                .opacity(selfieFillLight != nil ? 1 : (shutterFlash ? 0.82 : 0))
                .ignoresSafeArea()
                .allowsHitTesting(false)

            HardwareShutterView(isEnabled: !camera.isCapturing && captureProgress == nil && countdown == nil) {
                beginCapture()
            }
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)

            if showCaptureGuide {
                CaptureGuideOverlay {
                    withAnimation(.snappy) { showCaptureGuide = false }
                    hasSeenCaptureGuide = true
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .coordinateSpace(name: Self.cameraSpace)
        .onPreferenceChange(ViewfinderAreaKey.self) { area in
            guard area != viewfinderArea else { return }
            viewfinderArea = area
        }
        .task {
            Self.purgeStaleMomentVideos()
            CaptureTilt.shared.start()
            await camera.prepare()
            #if DEBUG
            if let documents = FileManager.default.urls(for: .documentDirectory,
                                                        in: .userDomainMask).first {
                let stamp = ISO8601DateFormatter().string(from: Date())
                try? stamp.data(using: .utf8)?.write(to: documents.appendingPathComponent("camera-prepared.txt"))
            }
            #endif
            await restoreShootingIdentity()
            reportStorageLevel()
            reportRollIndexHealth()
        }
        .onChange(of: rollStore.indexHealth.writeFailed) { _, failed in
            // A write that fails mid-session cannot be reported at launch, so
            // the flag drives its own toast the moment it flips.
            guard failed else { return }
            showToast("Roll index could not be saved — frames stay on disk.")
        }
        .onAppear {
            if lastCaptureThumbnail == nil, let entry = rollStore.entries.last {
                lastCaptureThumbnail = rollStore.thumbnail(for: entry, maxPixel: 160)
            }
            updateGestureDetection()
            camera.previewPipeline.update(sensorFingerprintEnabled: sensorFingerprintEnabled)
            camera.previewPipeline.update(focalCrop: CGFloat(focalLengthRaw) / 35.0)
            pairedCapture.onRemoteShutter = { beginPairedCapture() }
            if !hasSeenCaptureGuide {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    withAnimation(.snappy) { showCaptureGuide = true }
                }
            }
        }
        .onChange(of: gestureShutterEnabled) { _, _ in updateGestureDetection() }
        .onChange(of: timerMode) { _, _ in updateGestureDetection() }
        .onChange(of: sensorFingerprintEnabled) { _, enabled in
            camera.previewPipeline.update(sensorFingerprintEnabled: enabled)
        }
        .onChange(of: focalLengthRaw) { _, focal in
            camera.previewPipeline.update(focalCrop: CGFloat(focal) / 35.0)
        }
        .onChange(of: purchaseStore.isFullUnlocked) { _, unlocked in
            // A refund or a family-sharing revoke removes the entitlement while
            // a paid camera may still be selected; fall back to a free camera.
            if !unlocked && !selectedLook.isFree { selectedLook = .amber }
        }
        .onChange(of: selectedLook) { _, look in
            ShootingIdentity.remember(look: look)
        }
        .onChange(of: camera.flashMode) { _, mode in
            ShootingIdentity.remember(flash: mode)
        }
        .onChange(of: camera.selectedLens) { _, lens in
            // Switching to the front camera fits the wide lens and must not
            // overwrite the rear-camera choice the user will come back to.
            if camera.cameraPosition == .back {
                ShootingIdentity.remember(lens: lens)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.userDidTakeScreenshotNotification
        )) { _ in
            // iOS cannot block a system screenshot. When the frame is a trial,
            // at least say out loud that the capture is not the product.
            if isTrialLook {
                statusMessage = "Trial frames aren’t saved — upgrade to keep them."
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Returning from Settings after granting camera access must
                // recover without a relaunch; a backgrounded session also needs
                // to be restarted.
                if camera.issue == .permissionDenied || camera.issue == .configurationFailed {
                    Task {
                        await camera.prepare()
            #if DEBUG
            if let documents = FileManager.default.urls(for: .documentDirectory,
                                                        in: .userDomainMask).first {
                let stamp = ISO8601DateFormatter().string(from: Date())
                try? stamp.data(using: .utf8)?.write(to: documents.appendingPathComponent("camera-prepared.txt"))
            }
            #endif
                        await restoreShootingIdentity()
                    }
                } else if camera.isConfigured {
                    Task { await camera.start() }
                }
            case .inactive, .background:
                endSelfieFillLight()
                // A timer running while the app is not visible would fire a
                // stale shutter the moment the user comes back.
                cancelCountdown()
            @unknown default:
                break
            }
        }
        .onDisappear {
            endSelfieFillLight()
            // A cancelled countdown task returns before clearing its state;
            // without this the overlay and shutter lock survived a navigation
            // push and only CANCEL could recover.
            countdownTask?.cancel()
            countdownTask = nil
            countdown = nil
            camera.stop()
        }
        .onChange(of: rollStore.entries.last?.id) { _, _ in
            if let entry = rollStore.entries.last {
                lastCaptureThumbnail = rollStore.thumbnail(for: entry, maxPixel: 160)
            } else {
                lastCaptureThumbnail = nil
            }
        }
        .onChange(of: pickedItem) { _, item in importPhoto(item) }
        .fullScreenCover(isPresented: $showResult, onDismiss: {
            // Do not delete a Moment clip here: a failed roll write re-opens
            // the result and its preview/share actions would point at a
            // deleted file. Stale clips are purged from tmp on launch instead.
            captureResult = nil
            noteEntryIDByFrame = [:]
        }) {
            resultCover
        }
        .navigationDestination(isPresented: $showSettings) {
            CameraSettingsView(
                focalLengthRaw: $focalLengthRaw,
                dateStampFormatRaw: $dateStampFormatRaw,
                gridEnabled: $gridEnabled,
                dateStampEnabled: $dateStampEnabled,
                aspectRatio: $aspectRatio,
                autoSaveEnabled: $autoSaveEnabled,
                capturePreviewEnabled: $capturePreviewEnabled,
                gestureShutterEnabled: $gestureShutterEnabled,
                delayedRollEnabled: $delayedRollEnabled,
                rollCapacity: $rollCapacity,
                shutterSoundEnabled: $shutterSoundEnabled,
                sensorFingerprintEnabled: $sensorFingerprintEnabled,
                keepOriginalFrames: $keepOriginalFrames,
                rollStore: rollStore,
                pairedCapture: pairedCapture,
                selectedLook: selectedLook,
                calibrationStore: calibrationStore,
                camera: camera,
                purchaseStore: purchaseStore,
                onDualMemory: beginDualMemory,
                onPairedCapture: beginPairedCapture
            )
        }
        .fullScreenCover(isPresented: $showRoll) {
            NavigationStack {
                PocketRollView(store: rollStore)
            }
        }
        .fullScreenCover(isPresented: $showUpgrade) {
            UpgradeView(store: purchaseStore)
        }
        .overlay {
            PocketAlert(
                title: "POCKETCCD",
                message: statusMessage.map { String(localized: $0) } ?? "",
                isPresented: Binding(
                    get: { statusMessage != nil },
                    set: { if !$0 { statusMessage = nil } }
                )
            )
        }
        .overlay {
            PocketSheet("POCKET ROLL IS FULL", isPresented: $showRollFull) {
                Text("This roll already has \(rollStore.capacity) photos, so a new shot would be thrown away. Archive this roll and start a new one to keep shooting.")
                    .pocketFont(11)
                    .foregroundStyle(CameraTheme.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                PocketSheetDivider()
                PocketActionRow(title: "Archive roll and start new", symbol: "archivebox", destructive: true) {
                    showRollFull = false
                    rollStore.startNewRoll()
                    showToast("New roll started.")
                }
                PocketSheetDivider()
                PocketActionRow(title: "Not now", symbol: "xmark") {
                    showRollFull = false
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// Kept out of `body` so the type checker does not have to solve the whole
    /// camera screen in one expression.
    private var viewfinderView: some View {
        CameraViewport(
            session: camera.session,
            pipeline: camera.previewPipeline,
            look: selectedLook,
            aspectRatio: aspectRatio,
            flashMode: camera.cameraPosition == .back && camera.isFlashAvailable ? camera.flashMode : .off,
            colorAnchor: rollStore.peekColorAnchor(for: selectedLook),
            consistencyStrength: captureMode.consistencyStrength,
            gridEnabled: gridEnabled,
            focusPoint: focusPoint,
            isAEAFlocked: camera.isAEAFlocked,
            exposureBias: camera.exposureBias,
            isDraggingExposure: isDraggingViewfinderEV,
            zoomFactor: camera.zoomFactor,
            calibrationScene: calibrationStore.activeScene,
            calibrationCount: calibrationStore.activeScene.map { calibrationStore.count(for: $0) } ?? 0,
            dateStampEnabled: dateStampEnabled,
            dateStampFormat: dateStampFormat,
            focalCrop: CGFloat(focalLengthRaw) / 35.0,
            vintageLcdPreviewEnabled: vintageLcdPreviewEnabled,
            isTrial: isTrialLook,
            onFocus: focus,
            onLockAEAF: lockAEAF,
            onZoom: camera.adjustZoom,
            onExposureDrag: handleViewfinderExposureDrag,
            onCycleAspectRatio: cycleAspectRatio,
            availableArea: viewfinderArea
        )
    }

    private func cycleAspectRatio() {
        let all = CaptureAspectRatio.allCases
        guard let index = all.firstIndex(of: aspectRatio) else { return }
        aspectRatio = all[(index + 1) % all.count]
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var displayedFlashMode: AVCaptureDevice.FlashMode {
        if camera.cameraPosition == .front {
            return captureMode == .standard && selfieFillLightEnabled ? .on : .off
        }
        return camera.isFlashAvailable ? camera.flashMode : .off
    }

    private func toggleFlash() {
        if camera.cameraPosition == .front {
            selfieFillLightEnabled.toggle()
        } else {
            camera.flashMode = ShootingIdentity.nextFlash(after: camera.flashMode)
        }
    }

    private func beginSelfieFillLight() -> Bool {
        guard let screen = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive && $0.keyWindow != nil })?.screen
        else { return false }
        selfieFillLight = (screen, screen.brightness)
        screen.brightness = 1
        return true
    }

    private func endSelfieFillLight() {
        guard let fillLight = selfieFillLight else { return }
        fillLight.screen.brightness = fillLight.brightness
        selfieFillLight = nil
    }

    /// Restores the body, flash state and lens from the last session once the
    /// capture session is configured. Runs after `prepare()` because the flash
    /// and lens availability are only known then.
    private func restoreShootingIdentity() async {
        // A permission denial or a failed configuration would otherwise burn the
        // one-shot restore and leave the camera on the factory body for the rest
        // of the launch even after the user recovers access.
        guard !didRestoreIdentity, camera.issue == nil, camera.isConfigured else { return }
        didRestoreIdentity = true

        // A refund or a revoked family share removes the entitlement, so a
        // stored paid body must not survive into this launch.
        if !purchaseStore.isFullUnlocked && !selectedLook.isFree {
            selectedLook = .amber
        }
        if camera.isFlashAvailable {
            camera.flashMode = ShootingIdentity.flash()
        }
        let rememberedLens = ShootingIdentity.lens()
        if camera.availableLenses.contains(rememberedLens) {
            await camera.switchLens(to: rememberedLens)
        }

        guard !ShootingIdentity.isFactoryDefault(
            look: selectedLook,
            flash: camera.flashMode,
            lens: camera.selectedLens
        ) else { return }

        // Say what was restored instead of silently changing the camera. Brand
        // tokens (A8, FLASH, 1×) stay untranslated by design.
        showToast(LocalizedStringResource(stringLiteral: String(localized: "RESUMED")
            + "  ·  "
            + ShootingIdentity.summary(
                look: selectedLook,
                flash: camera.flashMode,
                lens: camera.selectedLens
            )))
    }

    /// Low space is a warning, not a block: a 24-frame roll still fits in a few
    /// hundred megabytes, original-frame bursts may not.
    private func reportStorageLevel() {
        switch StorageGuard.appLevel {
        case .ok:
            break
        case .low:
            showToast("Storage is low — develop this roll or clear negatives.")
        case .critical:
            showToast("Not enough storage — develop this roll or clear negatives.")
        }
    }

    /// True when the volume is so full that a capture would be lost after the
    /// shutter sound. The user gets an action instead of a silent failure.
    private func blockIfStorageCritical() -> Bool {
        guard StorageGuard.appLevel == .critical else { return false }
        statusMessage = "Not enough storage — develop this roll or clear negatives."
        return true
    }

    /// A full roll is the one refusal the user cannot see coming: the shutter
    /// fires, the flash pops, and only a toast afterwards admits that nothing
    /// was saved. Ask before the flash instead.
    private func rollIsFullInsteadOfCapture() -> Bool {
        guard rollStore.isFull || (rollStore.entries.count + inFlightRollWrites >= rollStore.capacity) else { return false }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        showRollFull = true
        return true
    }

    /// Reports a repaired roll exactly once. A frame that survived on disk but
    /// not in the index is good news, yet it must not be silent: the frame
    /// count changed while the app was closed.
    private func reportRollIndexHealth() {
        guard let message = rollStore.indexHealth.message else { return }
        showToast(message)
        rollStore.clearIndexHealth()
    }

    /// Archives the camera's processed originals before any CCD rendering. Never blocks the result screen: a capture is already in
    /// flight and the write happens on the archive's own executor.
    private func archiveOriginalFrames(
        _ captured: [(offset: Int, photo: CapturedPhoto)],
        plan: [(FrameRole, AVCaptureDevice.FlashMode?)],
        at date: Date,
        look: CCDLook,
        mode: CaptureMode
    ) {
        guard OriginalFrameArchive.isEnabled,
              mode != .moment,
              // Optional evidence loses to the capture itself: never let
              // originals be the write that fills the last few megabytes.
              StorageGuard.appLevel != .critical else { return }
        let frames = captured.compactMap { item -> OriginalCaptureFrame? in
            guard item.offset < plan.count,
                  let data = item.photo.originalData else { return nil }
            return OriginalCaptureFrame(role: plan[item.offset].0.rawValue, data: data, diagnostics: item.photo.diagnostics)
        }
        guard !frames.isEmpty else { return }
        let snapshot = OriginalCaptureSnapshot(
            capturedAt: date,
            camera: look.rawValue,
            cameraPosition: camera.cameraPosition == .front ? "front" : "back",
            mode: mode.rawValue,
            lens: camera.selectedLens.rawValue,
            exposureBias: camera.exposureBias,
            iso: camera.manualISO,
            shutterSeconds: camera.shutterSeconds,
            whiteBalanceKelvin: camera.whiteBalanceKelvin,
            flashMode: ShootingIdentity.flashToken(camera.flashMode)
        )
        Task.detached(priority: .utility) {
            await OriginalFrameArchive.shared.archive(frames, snapshot: snapshot)
        }
    }

    private func updateGestureDetection() {
        camera.previewPipeline.setGestureDetection(
            enabled: gestureShutterEnabled && timerMode != .off
        ) {
            beginCapture()
        }
    }

    private func beginCapture() {
        guard countdown == nil, captureProgress == nil, !camera.isCapturing else { return }
        guard timerMode.seconds > 0 else {
            capture()
            return
        }
        countdownTask = Task { @MainActor in
            for value in stride(from: timerMode.seconds, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                countdown = value
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            countdown = nil
            countdownTask = nil
            capture()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        withAnimation(.easeOut) { countdown = nil }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func capture() {
        // A hardware shutter, the open-hand gesture, or a paired remote can all
        // arrive while a capture is still running; ignore them instead of
        // surfacing a spurious "Couldn’t take this photo." alert.
        guard countdown == nil, captureProgress == nil, !camera.isCapturing, !isProcessingCapture else { return }
        guard !blockIfStorageCritical() else { return }
        guard !rollIsFullInsteadOfCapture() else { return }
        isProcessingCapture = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        ShutterSoundPlayer.shared.play(for: selectedLook, flashed: camera.flashMode == .on || displayedFlashMode == .on)
        withAnimation(.easeOut(duration: 0.08)) { shutterFlash = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeIn(duration: 0.16)) { shutterFlash = false }
        }
        let isTrial = !ProductAccess.canUse(selectedLook, isFullUnlocked: purchaseStore.isFullUnlocked)
        let fastBackgroundPath = captureMode == .standard && !isTrial && (!capturePreviewEnabled || delayedRollEnabled)
        if fastBackgroundPath {
            captureFastStandardInBackground()
            return
        }
        Task {
            defer { isProcessingCapture = false }
            do {
                let result = try await performCapture(isTrial: isTrial)
                await presentResult(result, wasTrial: isTrial)
            } catch {
                statusMessage = "Couldn’t take this photo."
            }
        }
    }

    /// Fast point-and-shoot path when Capture Preview is off: unlocks the
    /// shutter as soon as AVFoundation delivers the exposure, then runs CCD
    /// rendering and roll persistence in the background without Vision scoring.
    private func captureFastStandardInBackground() {
        let capturedAt = Date()
        let look = selectedLook
        let shouldMirror = camera.cameraPosition == .front
        let focalCrop = CGFloat(focalLengthRaw) / 35.0
        let stampFormat = dateStampFormat
        let ratio = aspectRatio
        let sensor = activeSensor
        let stamp = dateStampEnabled
        let hasHardwareFlash = camera.cameraPosition == .back && camera.isFlashAvailable
        let useSelfieFill = camera.cameraPosition == .front && displayedFlashMode == .on
        inFlightRollWrites += 1

        Task {
            var exposureReleased = false
            do {
                let photo: CapturedPhoto
                if useSelfieFill && beginSelfieFillLight() {
                    defer { endSelfieFillLight() }
                    try await Task.sleep(for: .milliseconds(250))
                    guard selfieFillLight != nil else { throw CameraIssue.captureFailed }
                    photo = try await camera.capture(flashMode: .off)
                } else {
                    photo = try await camera.capture(flashMode: nil)
                }
                // Hardware exposure is complete; unlock the shutter immediately
                // while rendering and disk writes finish in the background.
                isProcessingCapture = false
                exposureReleased = true

                if ProductAccess.canUse(look, isFullUnlocked: purchaseStore.isFullUnlocked) {
                    archiveOriginalFrames([(0, photo)], plan: [(.standard, nil)], at: capturedAt, look: look, mode: .standard)
                }

                let didFlash = hasHardwareFlash && Self.flashFired(in: photo.originalData)
                let rendered = try await Task.detached(priority: .userInitiated) { () throws -> UIImage in
                    let normalized = shouldMirror ? photo.image.mirroredForSelfie() : photo.image
                    guard let output = look.render(
                        normalized,
                        dateStamp: stamp,
                        aspectRatio: ratio,
                        sensor: sensor,
                        colorAnchor: nil,
                        consistencyStrength: 0,
                        stampDate: capturedAt,
                        flash: didFlash ? 1 : 0,
                        focalCrop: focalCrop,
                        dateStampFormat: stampFormat,
                        conditions: photo.metadata.imagingConditions
                    ) else { throw CameraIssue.captureFailed }
                    return output
                }.value

                let frame = CapturedFrame(image: rendered, role: .standard, assessment: .empty, metadata: photo.metadata)
                let result = CaptureResult(mode: .standard, camera: look, createdAt: capturedAt, frames: [frame], suggestedIndex: 0)
                await presentResult(result, wasTrial: false)
                inFlightRollWrites = max(0, inFlightRollWrites - 1)
            } catch {
                if !exposureReleased { isProcessingCapture = false }
                inFlightRollWrites = max(0, inFlightRollWrites - 1)
                statusMessage = "Couldn’t take this photo."
            }
        }
    }

    private func beginDualMemory() {
        guard captureProgress == nil, !camera.isCapturing, !isProcessingCapture else { return }
        guard !blockIfStorageCritical() else { return }
        guard !rollIsFullInsteadOfCapture() else { return }
        let look = selectedLook
        let wasTrial = isTrialLook
        let ratio = aspectRatio
        let sensor = activeSensor
        let stamp = dateStampEnabled
        let stampFormat = dateStampFormat
        showSettings = false
        captureProgress = (1, 2)
        Task {
            defer { captureProgress = nil }
            do {
                let rearPhoto: CapturedPhoto
                let frontPhoto: CapturedPhoto
                if DualMemoryController.isSimultaneousSupported {
                    await camera.stopAndWait()
                    do {
                        (rearPhoto, frontPhoto) = try await dualMemory.capture()
                    } catch {
                        await camera.start()
                        throw error
                    }
                    await camera.start()
                } else {
                    // Dismissing Settings pushes the camera page out of view,
                    // which stops the session. Without this wait the first
                    // sequential capture always failed `isSessionRunning()`.
                    await camera.ensureRunning()
                    let pair = try await SequentialDualCapture.capture(
                        initialPosition: camera.cameraPosition,
                        switchTo: { position in
                            if camera.cameraPosition != position { await camera.switchCamera() }
                            guard camera.cameraPosition == position else { throw CameraIssue.configurationFailed }
                        },
                        capturePhoto: { try await camera.capture(flashMode: .off) },
                        rearCaptured: { captureProgress = (2, 2) }
                    )
                    rearPhoto = pair.rear
                    frontPhoto = pair.front
                }
                let rear = rearPhoto.image
                let front = frontPhoto.image.mirroredForSelfie()
                let capturedAt = Date()
                let sample = await Task.detached(priority: .userInitiated) {
                    CaptureColorAnchor.measure(rear, aspectRatio: ratio)
                }.value
                let anchor = sample.map { wasTrial ? $0 : rollStore.colorAnchor(for: look, sample: $0) }
                guard let renderedRear = await renderCapture(
                    rear, look: look, dateStamp: stamp, aspectRatio: ratio, sensor: sensor,
                    colorAnchor: anchor, consistencyStrength: 0.14, stampDate: capturedAt,
                    stampFormat: stampFormat, conditions: rearPhoto.metadata.imagingConditions
                ), let renderedFront = await renderCapture(
                    front, look: look, dateStamp: stamp, aspectRatio: ratio, sensor: sensor,
                    colorAnchor: anchor, consistencyStrength: 0.14, stampDate: capturedAt,
                    stampFormat: stampFormat, conditions: frontPhoto.metadata.imagingConditions
                ) else { throw CameraIssue.captureFailed }
                let assessments = await FrameAnalyzer.assessAll([renderedRear, renderedFront])
                let frames = [
                    CapturedFrame(image: renderedRear, role: .standard, assessment: assessments[0], metadata: rearPhoto.metadata),
                    CapturedFrame(image: renderedFront, role: .reaction, assessment: assessments[1], metadata: frontPhoto.metadata)
                ]
                await presentResult(CaptureResult(mode: .flashPair, camera: look, createdAt: capturedAt, frames: frames, suggestedIndex: 0), wasTrial: wasTrial)
            } catch {
                statusMessage = "Couldn’t capture Dual Memory."
            }
        }
    }

    private func beginPairedCapture() {
        showSettings = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            // Settings can push the camera page out of view (which stops the
            // session); wait for it before firing the paired shutter.
            await camera.ensureRunning()
            beginCapture()
        }
    }

    /// Renders a full-resolution capture off the main actor. Every path that
    /// exports a frame goes through this helper so date-stamp format, mirroring
    /// and look parameters cannot drift apart again.
    private func renderCapture(
        _ image: UIImage,
        look: CCDLook,
        dateStamp: Bool,
        aspectRatio: CaptureAspectRatio,
        sensor: SensorIdentity,
        colorAnchor: CaptureColorAnchor?,
        consistencyStrength: CGFloat,
        stampDate: Date,
        stampFormat: DateStampFormat,
        flash: Double = 0,
        focalCrop: CGFloat = 1,
        mirror: Bool = false,
        conditions: CaptureImagingConditions
    ) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let source = mirror ? image.mirroredForSelfie() : image
            return look.render(
                source,
                dateStamp: dateStamp,
                aspectRatio: aspectRatio,
                sensor: sensor,
                colorAnchor: colorAnchor,
                consistencyStrength: consistencyStrength,
                stampDate: stampDate,
                flash: flash,
                focalCrop: focalCrop,
                dateStampFormat: stampFormat,
                conditions: conditions
            )
        }.value
    }

    private func performCapture(isTrial: Bool) async throws -> CaptureResult {
        defer { captureProgress = nil }
        let capturedAt = Date()
        let look = selectedLook
        let mode = captureMode
        let shouldMirror = camera.cameraPosition == .front
        let focalCrop = CGFloat(focalLengthRaw) / 35.0
        let stampFormat = dateStampFormat
        if mode == .moment {
            return try await performMomentCapture()
        }
        let plan: [(FrameRole, AVCaptureDevice.FlashMode?)]
        switch mode {
        case .standard:
            plan = [(.standard, nil)]
        case .flashParty:
            plan = [(.flash, .on), (.flash, .on), (.flash, .on)]
        case .flashPair:
            plan = [(.ambient, .off), (.flash, .on)]
        case .flashSequence:
            plan = [(.ambient, .off), (.flash, .on), (.reaction, .off)]
        case .moment:
            plan = []
        }

        // Fire every exposure before processing the first one: otherwise the
        // ambient/flash/reaction frames were separated by JPEG decode, CCD
        // render and Vision scoring (0.5–1.5 s apart, not one moment).
        let capturedData: [(offset: Int, photo: CapturedPhoto)]
        let hasHardwareFlash = camera.cameraPosition == .back && camera.isFlashAvailable
        if plan.count > 1 {
            capturedData = try await camera.captureSequence(flashModes: plan.map(\.1))
        } else {
            if camera.cameraPosition == .front && displayedFlashMode == .on && beginSelfieFillLight() {
                defer { endSelfieFillLight() }
                // Let the display illuminate the subject before requesting the exposure.
                try await Task.sleep(for: .milliseconds(250))
                guard selfieFillLight != nil else { throw CameraIssue.captureFailed }
                capturedData = [(0, photo: try await camera.capture(flashMode: .off))]
            } else {
                capturedData = [(0, photo: try await camera.capture(flashMode: plan.first?.1 ?? nil))]
            }
        }
        if capturedData.count < plan.count {
            showToast("Captured \(capturedData.count) of \(plan.count) frames")
        }
        if !isTrial && ProductAccess.canUse(look, isFullUnlocked: purchaseStore.isFullUnlocked) {
            archiveOriginalFrames(capturedData, plan: plan, at: capturedAt, look: look, mode: mode)
        }

        var renderedFrames: [(image: UIImage, role: FrameRole, metadata: PhotoFrameMetadata)] = []
        var colorAnchor: CaptureColorAnchor?
        for (index, item) in capturedData.enumerated() {
            let step = plan[item.offset]
            // A single standard photo does not need a "CAPTURING 1/1" veil over
            // the viewfinder while it renders.
            if plan.count > 1 {
                captureProgress = (index + 1, plan.count)
            }
            let capturedPhoto = item.photo
            let ratio = aspectRatio
            let sensor = activeSensor
            let stamp = dateStampEnabled
            // Screen fill already lights the subject during capture. The
            // hard-flash grade is reserved for the hardware flash.
            let didFlash = hasHardwareFlash
                && (step.1 == .on || Self.flashFired(in: capturedPhoto.originalData))
            // A standard shot must use the same unanchored colour recipe as
            // live preview. Stabilization is only useful across a frame set.
            let strength = mode.consistencyStrength
            let prepared = try await Task.detached(priority: .userInitiated) { () throws -> (UIImage, CaptureColorAnchor?) in
                let capturedImage = capturedPhoto.image
                let normalized = shouldMirror ? capturedImage.mirroredForSelfie() : capturedImage
                // Standard capture has no cross-frame stabilization. Avoid an
                // unnecessary resize + area-average pass on every shutter.
                let sample = strength > 0
                    ? CaptureColorAnchor.measure(normalized, aspectRatio: ratio)
                    : nil
                return (normalized, sample)
            }.value
            let image = prepared.0
            if colorAnchor == nil, let sample = prepared.1 {
                colorAnchor = isTrial ? sample : rollStore.colorAnchor(for: look, sample: sample)
            }
            let anchor = strength > 0 ? colorAnchor : nil
            let rendered = try await Task.detached(priority: .userInitiated) { () throws -> UIImage in
                guard let output = look.render(
                    image,
                    dateStamp: stamp,
                    aspectRatio: ratio,
                    sensor: sensor,
                    colorAnchor: anchor,
                    consistencyStrength: strength,
                    stampDate: capturedAt,
                    flash: didFlash ? 1 : 0,
                    focalCrop: focalCrop,
                    dateStampFormat: stampFormat,
                    conditions: capturedPhoto.metadata.imagingConditions
                ) else { throw CameraIssue.captureFailed }
                return output
            }.value
            renderedFrames.append((rendered, step.0, capturedPhoto.metadata))
        }

        // Vision analysis is independent per exposure. Run the small, bounded
        // set concurrently instead of adding each frame's latency serially.
        let assessments = await FrameAnalyzer.assessAll(renderedFrames.map(\.image))
        let frames = zip(renderedFrames, assessments).map { rendered, assessment in
            CapturedFrame(image: rendered.image, role: rendered.role, assessment: assessment, metadata: rendered.metadata)
        }

        guard let suggested = frames.indices.first else { throw CameraIssue.captureFailed }
        let bestIndex = frames.indices.dropFirst().reduce(suggested) { best, candidate in
            frames[candidate].ranksBefore(frames[best]) ? candidate : best
        }
        return CaptureResult(
            mode: mode,
            camera: look,
            createdAt: capturedAt,
            frames: frames,
            suggestedIndex: bestIndex
        )
    }

    private func performMomentCapture() async throws -> CaptureResult {
        captureProgress = (1, 1)
        let look = selectedLook
        let wasTrial = isTrialLook
        let capturedAt = Date()
        let shouldMirror = camera.cameraPosition == .front
        let conditions = camera.imagingConditions
        let ratio = aspectRatio
        let sensor = activeSensor
        let stamp = dateStampEnabled
        let stampFormat = dateStampFormat
        let focalCrop = CGFloat(focalLengthRaw) / 35.0
        let rawVideoURL = try await camera.recordMoment()
        // Candidates come from the untouched recording: the rendered movie
        // already carries the CCD recipe, and re-rendering its frames applied
        // bloom/grain twice and made stills disagree with the video.
        let asset = AVURLAsset(url: rawVideoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        var renderedImages: [UIImage] = []
        var rollAnchor: CaptureColorAnchor?
        var videoBalanceGain: Double?
        for seconds in [0.35, 1.0, 1.65] {
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            let capturedStill = UIImage(cgImage: cgImage)
            let still = shouldMirror ? capturedStill.mirroredForSelfie() : capturedStill
            if videoBalanceGain == nil, let measured = CIImage(image: still) {
                // One measurement for the whole clip; matching the still path
                // and preventing per-frame white-balance flicker.
                videoBalanceGain = CCDLook.sceneBlueGain(measured)
            }
            if rollAnchor == nil {
                let sample = await Task.detached(priority: .userInitiated) {
                    CaptureColorAnchor.measure(still, aspectRatio: ratio)
                }.value
                if let sample {
                    rollAnchor = wasTrial ? sample : rollStore.colorAnchor(for: look, sample: sample)
                }
            }
            guard let rendered = await renderCapture(
                still,
                look: look,
                dateStamp: stamp,
                aspectRatio: ratio,
                sensor: sensor,
                colorAnchor: rollAnchor,
                consistencyStrength: 0.14,
                stampDate: capturedAt,
                stampFormat: stampFormat,
                focalCrop: focalCrop,
                conditions: conditions
            ) else { continue }
            renderedImages.append(rendered)
        }
        guard !renderedImages.isEmpty else { throw CameraIssue.captureFailed }

        // The video export and still-frame analysis consume independent inputs.
        // Running them together removes the sum of both waits from Moment mode.
        async let analyzed = FrameAnalyzer.assessAll(renderedImages)
        async let renderedVideo = MomentVideoRenderer.render(
            sourceURL: rawVideoURL,
            look: look,
            sensor: sensor,
            balanceGain: videoBalanceGain,
            aspectRatio: ratio,
            focalCrop: focalCrop,
            conditions: conditions,
            isFront: shouldMirror
        )
        let (assessments, videoURL) = try await (analyzed, renderedVideo)
        let frames = zip(renderedImages, assessments).map { image, assessment in
            CapturedFrame(image: image, role: .standard, assessment: assessment)
        }
        guard let firstIndex = frames.indices.first else { throw CameraIssue.captureFailed }
        let bestIndex = frames.indices.dropFirst().reduce(firstIndex) { best, candidate in
            frames[candidate].ranksBefore(frames[best]) ? candidate : best
        }
        return CaptureResult(
            mode: .moment,
            camera: look,
            createdAt: capturedAt,
            frames: frames,
            suggestedIndex: bestIndex,
            momentVideoURL: videoURL
        )
    }

    private func focus(at devicePoint: CGPoint, viewPoint: CGPoint) {
        camera.focus(at: devicePoint)
        focusPoint = viewPoint
        UISelectionFeedbackGenerator().selectionChanged()
        // Focusing is a direct-manipulation gesture: drop the preview's long
        // edge while it settles, then restore it.
        camera.previewPipeline.setInteraction(active: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            camera.previewPipeline.setInteraction(active: false)
        }
        scheduleFocusDismiss(after: .milliseconds(1600), matching: viewPoint)
    }

    private func lockAEAF(at devicePoint: CGPoint, viewPoint: CGPoint) {
        focusDismissTask?.cancel()
        camera.lockFocusAndExposure(at: devicePoint)
        focusPoint = viewPoint
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func handleViewfinderExposureDrag(delta: CGFloat, active: Bool) {
        isDraggingViewfinderEV = active
        if active {
            focusDismissTask?.cancel()
            if delta != 0 {
                let updated = min(max(camera.exposureBias + Float(delta), -2), 2)
                camera.setExposureBias(updated)
            }
        } else if !camera.isAEAFlocked, let point = focusPoint {
            scheduleFocusDismiss(after: .milliseconds(1200), matching: point)
        }
    }

    private func scheduleFocusDismiss(after delay: Duration, matching point: CGPoint) {
        focusDismissTask?.cancel()
        focusDismissTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, !camera.isAEAFlocked, !isDraggingViewfinderEV else { return }
            if focusPoint == point { focusPoint = nil }
        }
    }

    private var dateStampFormat: DateStampFormat {
        DateStampFormat(rawValue: dateStampFormatRaw) ?? .dayMonthYear
    }

    private var isTrialLook: Bool {
        !ProductAccess.canUse(selectedLook, isFullUnlocked: purchaseStore.isFullUnlocked)
    }

    private var activeSensor: SensorIdentity {
        sensorFingerprintEnabled ? .current() : .generic
    }

    /// Imported photos keep their own capture date so the date stamp does not
    /// claim a 2019 photo was taken today.
    nonisolated static func captureDate(in data: Data) -> Date {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return .now }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: raw) ?? .now
    }

    /// Moment clips live in tmp and are intentionally not deleted when the
    /// result sheet closes (a failed roll write can re-open it). Sweep files
    /// older than a day instead, so tmp cannot grow without bound.
    private nonisolated static func purgeStaleMomentVideos() {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for url in urls where url.lastPathComponent.hasPrefix("PocketMoment-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// EXIF Flash is a bit field; bit zero records whether the tube actually
    /// fired. This matters for `.auto`, where the requested mode alone cannot
    /// tell the renderer whether it needs highlight protection.
    nonisolated static func flashFired(in data: Data?) -> Bool {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let raw = exif[kCGImagePropertyExifFlash] as? NSNumber else { return false }
        return raw.intValue & 1 == 1
    }

    private func importPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        let look = selectedLook
        let wasTrial = isTrialLook
        // Clear immediately: a failed transfer used to leave the same item
        // selected, so re-picking it never fired onChange again.
        pickedItem = nil
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                statusMessage = "Couldn’t open this photo."
                return
            }
            let importedAt = Self.captureDate(in: data)
            let source = CGImageSourceCreateWithData(data as CFData, nil)
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
            let conditions = PhotoFrameMetadata(properties).imagingConditions
            let ratio = aspectRatio
            let sensor = activeSensor
            let stamp = dateStampEnabled
            let stampFormat = dateStampFormat
            let sample = await Task.detached(priority: .userInitiated) {
                CaptureColorAnchor.measure(image, aspectRatio: ratio)
            }.value
            let anchor = sample.map { wasTrial ? $0 : rollStore.colorAnchor(for: look, sample: $0) }
            guard let rendered = await renderCapture(
                    image,
                    look: look,
                    dateStamp: stamp,
                    aspectRatio: ratio,
                    sensor: sensor,
                    colorAnchor: anchor,
                    consistencyStrength: 0.14,
                    stampDate: importedAt,
                    stampFormat: stampFormat,
                    conditions: conditions
                  ) else {
                statusMessage = "Couldn’t open this photo."
                return
            }
            let frame = CapturedFrame(image: rendered, role: .standard, assessment: await FrameAnalyzer.assess(rendered))
            await presentResult(CaptureResult(
                mode: .standard,
                camera: look,
                createdAt: importedAt,
                frames: [frame],
                suggestedIndex: 0
            ), wasTrial: wasTrial)
            pickedItem = nil
        }
    }

    private func presentResult(_ result: CaptureResult, wasTrial: Bool) async {
        let isTrial = wasTrial || !ProductAccess.canUse(result.camera, isFullUnlocked: purchaseStore.isFullUnlocked)
        resultIsTrial = isTrial
        if !isTrial {
            let source = result.suggestedFrame.image
            let thumb = await Task.detached(priority: .utility) {
                source.preparingThumbnail(of: CGSize(width: 96, height: 96))
            }.value
            lastCaptureThumbnail = thumb ?? source
        }
        // Photos go straight into the Pocket Roll by default unless Capture
        // Preview is turned on in Settings. Trial frames (not stored in roll)
        // and Moment clips (temporary video) still open the preview sheet.
        let isDelayed = delayedRollEnabled && result.mode != .moment && !isTrial
        let shouldShowPreview = isTrial || result.mode == .moment || (capturePreviewEnabled && !isDelayed)
        resultWasSaved = false
        rollSaveFailed = false
        isAutoSavingResult = autoSaveEnabled && !isTrial
        autoSavingResultID = isAutoSavingResult ? result.id : nil
        if shouldShowPreview {
            captureResult = result
            showResult = true
        }
        // JPEG encoding and the Photos transaction can take noticeably longer
        // than presenting the already-rendered result. Keep the manual save
        // action disabled until this finishes so the asset cannot be duplicated.
        if isAutoSavingResult {
            Task { @MainActor in
                let saved = await camera.save(
                    result.suggestedFrame.image,
                    capturedAt: result.createdAt,
                    metadata: result.suggestedFrame.metadata
                )
                // An earlier save may finish after the user has already taken
                // another photo. Never apply that completion to the new result.
                guard autoSavingResultID == result.id else { return }
                resultWasSaved = saved
                isAutoSavingResult = false
                autoSavingResultID = nil
            }
        }
        if !isTrial {
            let stored = await storeInRoll(result)
            rollSaveFailed = !stored
            if !stored {
                // Preserve the pixels even if the result was dismissed while
                // encoding. A failed roll write must leave a direct-save copy.
                captureResult = result
                showResult = true
            }
        }
    }

    /// Note already saved for a frame, so the editor opens with it filled in.
    private func savedNote(forFrameID frameID: UUID) -> String {
        guard let entryID = noteEntryIDByFrame[frameID],
              let entry = rollStore.entries.first(where: { $0.id == entryID }) else { return "" }
        return entry.note ?? ""
    }

    /// Split out of `body`: the result screen's initialiser is large enough that
    /// inlining it pushed the whole camera screen past the type checker's limit.
    @ViewBuilder
    private var resultCover: some View {
        if let captureResult {
            PhotoResultView(
                result: captureResult,
                initiallySaved: resultWasSaved,
                autoSaved: resultWasSaved,
                isAutoSaving: isAutoSavingResult,
                sensor: activeSensor,
                pairedCapture: pairedCapture,
                onSave: { image, frame in
                    await camera.save(image, capturedAt: captureResult.createdAt, metadata: frame.metadata)
                },
                onSaveVideo: { await camera.saveVideo(at: $0, capturedAt: captureResult.createdAt) },
                onSaveLivePhoto: { image, video in
                    await camera.saveLivePhoto(image: image, videoURL: video, capturedAt: captureResult.createdAt)
                },
                onUpdateNote: { note, frameID, frameIndex in
                    guard !resultIsTrial else { return }
                    if let entryID = noteEntryIDByFrame[frameID] {
                        rollStore.updateNote(note, forEntryID: entryID)
                    } else {
                        rollStore.updateNote(note, forCaptureAt: captureResult.createdAt, frameIndex: frameIndex)
                    }
                },
                existingNote: savedNote(forFrameID:),
                keepsNegative: keepOriginalFrames,
                isTrial: resultIsTrial,
                rollSaveFailed: rollSaveFailed
            )
        }
    }

    private func storeInRoll(_ result: CaptureResult) async -> Bool {
        // Encoding yields off the main actor, but callers await the receipt.
        let frames = result.mode == .moment ? [result.suggestedFrame] : result.frames
        let receipt = await rollStore.addFrames(frames, camera: result.camera, mode: result.mode,
                                                createdAt: result.createdAt)
        noteEntryIDByFrame.merge(receipt.entryIDs) { _, new in new }
        switch receipt.failure {
        case .full:
            showToast(receipt.storedCount == 0
                ? "Pocket Roll is full — start a new roll in Settings"
                : "Pocket Roll is full — saved \(receipt.storedCount) of \(receipt.requestedCount) frames")
        case .storage:
            showToast("Not enough storage — develop this roll or clear negatives.")
        case .write:
            showToast("Couldn’t save to the roll. Save this photo to Photos.")
        case .index:
            showToast("Couldn’t confirm this photo in the roll. Save it to Photos.")
        case nil:
            break
        }
        if receipt.isComplete, let scene = calibrationStore.record(
            image: result.suggestedFrame.image, look: result.camera, lens: camera.selectedLens,
            exposureBias: camera.exposureBias, iso: camera.manualISO,
            shutterSeconds: camera.shutterSeconds, whiteBalanceKelvin: camera.whiteBalanceKelvin
        ) {
            showToast("Recorded benchmark \(scene.rawValue) — \(calibrationStore.count(for: scene))/3")
        }
        pairedCapture.send(image: result.suggestedFrame.image)
        ProductMetrics.record(.captureCompleted)
        let completedCaptures = ProductMetrics.count(.captureCompleted)
        if receipt.isComplete && (completedCaptures == 5 || completedCaptures == 20) { requestReview() }
        return receipt.isComplete
    }

    private func showToast(_ message: LocalizedStringResource) {
        withAnimation(.snappy) { toastMessage = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if toastMessage == message {
                withAnimation(.easeOut) { toastMessage = nil }
            }
        }
    }
}

private extension UIImage {
    /// Produces an orientation-normalized pixel buffer matching the mirrored selfie preview.
    func mirroredForSelfie() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.translateBy(x: size.width, y: 0)
            context.cgContext.scaleBy(x: -1, y: 1)
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private struct CameraViewport: View {
    let session: AVCaptureSession
    let pipeline: LivePreviewPipeline
    let look: CCDLook
    let aspectRatio: CaptureAspectRatio
    let flashMode: AVCaptureDevice.FlashMode
    let colorAnchor: CaptureColorAnchor?
    let consistencyStrength: CGFloat
    let gridEnabled: Bool
    let focusPoint: CGPoint?
    let isAEAFlocked: Bool
    let exposureBias: Float
    let isDraggingExposure: Bool
    let zoomFactor: CGFloat
    let calibrationScene: CalibrationScene?
    let calibrationCount: Int
    let dateStampEnabled: Bool
    let dateStampFormat: DateStampFormat
    let focalCrop: CGFloat
    let vintageLcdPreviewEnabled: Bool
    let isTrial: Bool
    let onFocus: (CGPoint, CGPoint) -> Void
    let onLockAEAF: (CGPoint, CGPoint) -> Void
    let onZoom: (CGFloat) -> Void
    let onExposureDrag: (CGFloat, Bool) -> Void
    let onCycleAspectRatio: () -> Void

    /// Height of the middle slot the chrome leaves between the status chip and
    /// the control panel, in the shared `cameraSpace`. `.zero` until the first
    /// layout pass reports it.
    let availableArea: CGRect

    var body: some View {
        GeometryReader { proxy in
            let container = proxy.frame(in: .named(CameraScreen.cameraSpace))
            let slot = availableArea.isEmpty
                ? CGRect(origin: container.origin, size: proxy.size)
                : availableArea
            let image = ViewfinderGeometry.fittedRect(in: slot, aspect: aspectRatio.portraitValue)
            // The slot is taller than a 4:3 frame; fill the leftover with the
            // panel colour so the photo meets the status bar and the dock
            // without a black band on either side.
            if image.maxY < slot.maxY - 0.5 {
                Rectangle()
                    .fill(CameraTheme.panel)
                    .frame(width: slot.width, height: slot.maxY - image.maxY)
                    .position(
                        x: slot.midX - container.minX,
                        y: (image.maxY + slot.maxY) / 2 - container.minY
                    )
            }
            CameraPreview(
                session: session,
                pipeline: pipeline,
                look: look,
                aspectRatio: aspectRatio,
                focalCrop: focalCrop,
                flashMode: flashMode,
                colorAnchor: colorAnchor,
                consistencyStrength: consistencyStrength,
                onFocus: { devicePoint, viewPoint in
                    onFocus(devicePoint, viewPoint)
                },
                onLockAEAF: { devicePoint, viewPoint in
                    onLockAEAF(devicePoint, viewPoint)
                },
                onZoom: onZoom,
                onExposureDrag: onExposureDrag,
                canDragExposure: focusPoint != nil
            )
                .transaction { transaction in
                    transaction.animation = nil
                }
                // The pipeline crops before metering and rendering, just as
                // the saved still does; no second display-only zoom.
                .frame(width: image.width, height: image.height)
                .overlay {
                    // Everything here is drawn against the photo's real rect, so
                    // the brackets can no longer drift away from the frame they
                    // are supposed to be framing.
                    ZStack {
                        if gridEnabled { CompositionGrid() }
                        if vintageLcdPreviewEnabled { VintageLcdScanlineOverlay() }
                        Rectangle().stroke(.white.opacity(0.16), lineWidth: 0.5)
                        ViewfinderCorners()
                        if isTrial {
                            VStack {
                                HStack {
                                    Spacer(minLength: 0)
                                    Text("TRIAL")
                                        .pocketHUDFont(8, weight: .bold, design: .monospaced)
                                        .tracking(1.4)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .frame(height: 20)
                                        .background(.black.opacity(0.45))
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                        }
                        if dateStampEnabled {
                            VStack {
                                Spacer(minLength: 0)
                                HStack {
                                    Spacer(minLength: 0)
                                    Text(verbatim: dateStampFormat.text(for: .now))
                                        .pocketHUDFont(10.5, weight: .bold, design: .monospaced)
                                        .tracking(1.4)
                                        .foregroundStyle(CameraTheme.color(for: look.accent))
                                        .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                                }
                                // Sits above the bottom-right bracket arm so
                                // the stamp and the corner never overlap.
                                .padding(.trailing, 22)
                                .padding(.bottom, 46)
                            }
                        }
                    }
                }
                .clipped()
                .overlay(alignment: .top) {
                    HStack(spacing: 6) {
                        ViewfinderAspectChip(aspectRatio: aspectRatio, action: onCycleAspectRatio)
                        if isAEAFlocked {
                            Text("AE/AF LOCK")
                                .pocketHUDFont(8.5, weight: .bold, design: .monospaced)
                                .tracking(0.9)
                                .foregroundStyle(.black)
                                .padding(.horizontal, 7)
                                .frame(height: 22)
                                .background(CameraTheme.accent)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.top, 10)
                }
                .overlay(alignment: .bottomLeading) {
                    if let calibrationScene {
                        CalibrationCaptureBadge(scene: calibrationScene, count: calibrationCount)
                    }
                }
                .overlay {
                    if let focusPoint {
                        FocusReticle(
                            isLocked: isAEAFlocked,
                            exposureBias: exposureBias,
                            showExposureIndicator: isDraggingExposure || abs(exposureBias) > 0.05
                        )
                        .position(focusPoint)
                        .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if zoomFactor > 1.01 {
                        Text(verbatim: "\(Double(zoomFactor).formatted(.number.precision(.fractionLength(1))))×")
                            .pocketHUDFont(9, weight: .bold, design: .monospaced)
                            .tracking(1)
                            .foregroundStyle(CameraTheme.ink)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(.black.opacity(0.56))
                            .overlay { Rectangle().stroke(.white.opacity(0.22), lineWidth: 0.75) }
                            .padding(.bottom, 12)
                            .allowsHitTesting(false)
                    }
                }
                .position(
                    x: image.midX - container.minX,
                    y: image.midY - container.minY
                )
        }
        .ignoresSafeArea()
    }

}

/// Reports the middle slot the chrome leaves for the viewfinder.
private struct ViewfinderAreaKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

private struct CompositionGrid: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                for index in 1 ... 2 {
                    let x = proxy.size.width * CGFloat(index) / 3
                    let y = proxy.size.height * CGFloat(index) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.20), lineWidth: 0.6)
        }
        .allowsHitTesting(false)
    }
}

private struct VintageLcdScanlineOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let spacing: CGFloat = 3.0
                var y: CGFloat = 0
                while y < size.height {
                    let path = Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(path, with: .color(.black.opacity(0.12)), lineWidth: 0.5)
                    y += spacing
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ViewfinderCorners: View {
    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 16
            let length: CGFloat = 24
            Path { path in
                let minX = inset
                let minY = inset
                let maxX = proxy.size.width - inset
                let maxY = proxy.size.height - inset
                path.move(to: CGPoint(x: minX, y: minY + length))
                path.addLine(to: CGPoint(x: minX, y: minY))
                path.addLine(to: CGPoint(x: minX + length, y: minY))
                path.move(to: CGPoint(x: maxX - length, y: minY))
                path.addLine(to: CGPoint(x: maxX, y: minY))
                path.addLine(to: CGPoint(x: maxX, y: minY + length))
                path.move(to: CGPoint(x: minX, y: maxY - length))
                path.addLine(to: CGPoint(x: minX, y: maxY))
                path.addLine(to: CGPoint(x: minX + length, y: maxY))
                path.move(to: CGPoint(x: maxX - length, y: maxY))
                path.addLine(to: CGPoint(x: maxX, y: maxY))
                path.addLine(to: CGPoint(x: maxX, y: maxY - length))
            }
            .stroke(.white.opacity(0.50), style: StrokeStyle(lineWidth: 1, lineCap: .square))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ViewfinderAspectChip: View {
    let aspectRatio: CaptureAspectRatio
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: aspectRatio.rawValue)
                .pocketHUDFont(9, weight: .bold, design: .monospaced)
                .tracking(0.9)
                .foregroundStyle(CameraTheme.ink)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(.black.opacity(0.52))
                .overlay { Rectangle().stroke(.white.opacity(0.24), lineWidth: 0.75) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Aspect ratio, \(aspectRatio.rawValue)")
        .accessibilityHint("Double tap to switch aspect ratio")
    }
}

private struct FocusReticle: View {
    let isLocked: Bool
    let exposureBias: Float
    let showExposureIndicator: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .stroke(CameraTheme.accent, lineWidth: isLocked ? 2 : 1.5)
                .frame(width: 64, height: 64)
            if isLocked {
                RoundedRectangle(cornerRadius: 1)
                    .stroke(CameraTheme.accent.opacity(0.75), lineWidth: 0.8)
                    .frame(width: 56, height: 56)
            }
            Circle()
                .fill(CameraTheme.accent)
                .frame(width: 3, height: 3)

            if showExposureIndicator {
                let normalized = CGFloat(min(max((exposureBias + 2) / 4, 0), 1))
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(.white.opacity(0.25))
                            .frame(width: 1.5, height: 56)
                        Image(systemName: "sun.max.fill")
                            .pocketHUDFont(10, weight: .bold)
                            .foregroundStyle(CameraTheme.accent)
                            .offset(y: -(normalized * 44) + 22)
                    }
                    .frame(height: 56)
                    Text(verbatim: (exposureBias >= 0 ? "+" : "") + exposureBias.formatted(.number.precision(.fractionLength(1))))
                        .pocketHUDFont(7.5, weight: .bold, design: .monospaced)
                        .foregroundStyle(CameraTheme.accent)
                }
                .offset(x: 48)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
        .transition(.opacity)
    }
}

private struct CameraChrome: View {
    @Binding var selectedLook: CCDLook
    @Binding var timerMode: CaptureTimer
    @Binding var captureMode: CaptureMode
    @Binding var pickedItem: PhotosPickerItem?
    let flashMode: AVCaptureDevice.FlashMode
    let isFlashAvailable: Bool
    let isFrontCamera: Bool
    let availableLenses: [CameraLens]
    let selectedLens: CameraLens
    let exposureBias: Float
    let isCapturing: Bool
    let isFullUnlocked: Bool
    let lastThumbnail: UIImage?
    let onLockedLook: () -> Void
    let onFlash: () -> Void
    let onSwitchCamera: () -> Void
    let onLens: (CameraLens) -> Void
    let onExposure: (Float) -> Void
    let onExposureInteraction: (Bool) -> Void
    let rollCount: Int
    let onRoll: () -> Void
    let onSettings: () -> Void
    let onShutter: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TopControls(timerMode: $timerMode,
                        captureMode: $captureMode,
                        pickedItem: $pickedItem,
                        flashMode: flashMode,
                        isFlashAvailable: isFlashAvailable,
                        isFrontCamera: isFrontCamera,
                        onFlash: onFlash,
                        onSwitchCamera: onSwitchCamera,
                        onSettings: onSettings)
                // Duo / iPad landscape: keep the camera chrome in a phone-wide
                // column instead of spreading the tools across 1540 pt.
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 6)

            // The corner brackets and the date stamp now live inside
            // `CameraViewport`, drawn against the photo's real rect. This slot
            // reports where that rect may live, so both sides agree.
            Color.clear
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ViewfinderAreaKey.self,
                            value: proxy.frame(in: .named(CameraScreen.cameraSpace))
                        )
                    }
                }

            VStack(spacing: 0) {
                LookSelector(
                    selection: $selectedLook,
                    isFullUnlocked: isFullUnlocked,
                    onLockedLook: onLockedLook
                )
                .padding(.top, 8)
                .padding(.bottom, 6)

                CompactExposureControl(
                    value: exposureBias,
                    onChange: onExposure,
                    onInteractionChange: onExposureInteraction
                )
                    .padding(.bottom, 2)

                ShutterControls(thumbnail: lastThumbnail,
                                rollCount: rollCount,
                                look: selectedLook,
                                availableLenses: availableLenses,
                                selectedLens: selectedLens,
                                isCapturing: isCapturing,
                                onRoll: onRoll,
                                onLens: onLens,
                                onShutter: onShutter)
            }
            // The 2 pt top padding paints panel colour over the seam the
            // viewfinder slot leaves above the dock; without it a 2–3 px black
            // line showed between the photo and the controls.
            .padding(.top, 2)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .background(CameraTheme.panel.opacity(0.98))
            .overlay(alignment: .top) { Rectangle().fill(CameraTheme.line).frame(height: 0.5) }
        }
        .disabled(isCapturing)
    }
}

private struct CompactExposureControl: View {
    let value: Float
    let onChange: (Float) -> Void
    let onInteractionChange: (Bool) -> Void
    @State private var isExpanded = false
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 4) {
            if isExpanded {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let fraction = min(max(CGFloat((value + 2) / 4), 0), 1)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.16)).frame(height: 2)
                        Rectangle().fill(CameraTheme.accent)
                            .frame(width: max(2, width * fraction), height: 2)
                        Circle().fill(CameraTheme.accent)
                            .frame(width: 12, height: 12)
                            .offset(x: min(max(0, width * fraction - 6), width - 12))
                    }
                    .frame(height: 16)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                if !isDragging {
                                    isDragging = true
                                    onInteractionChange(true)
                                }
                                let fraction = min(max(gesture.location.x / width, 0), 1)
                                onChange(Float(fraction * 4 - 2))
                            }
                            .onEnded { _ in
                                if isDragging {
                                    isDragging = false
                                    onInteractionChange(false)
                                }
                            }
                    )
                }
                .frame(height: 16)
                .padding(.horizontal, 24)
            }

            Button {
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus.forwardslash.minus")
                        .pocketHUDFont(8, weight: .bold)
                    Text(verbatim: "EV " + (value >= 0 ? "+" : "") + value.formatted(.number.precision(.fractionLength(1))))
                        .pocketHUDFont(8.5, weight: .bold, design: .monospaced)
                        .tracking(0.8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .pocketHUDFont(7, weight: .bold)
                }
                .foregroundStyle(value == 0 ? CameraTheme.muted : CameraTheme.accent)
                .frame(height: 24)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .accessibilityLabel("Exposure compensation")
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(1))))
    }
}

private struct TopControls: View {
    @Binding var timerMode: CaptureTimer
    @Binding var captureMode: CaptureMode
    @Binding var pickedItem: PhotosPickerItem?
    let flashMode: AVCaptureDevice.FlashMode
    let isFlashAvailable: Bool
    let isFrontCamera: Bool
    let onFlash: () -> Void
    let onSwitchCamera: () -> Void
    let onSettings: () -> Void
    @State private var showCaptureModes = false

    var body: some View {
        // The row has to span the full width: `ViewThatFits` measured the ideal
        // width with `fixedSize`, so on a wide iPhone the toolbar collapsed to
        // its content and floated in the middle of the screen instead of
        // pinning the tools to the right edge.
        controls
            .padding(.horizontal, 12)
            .padding(.top, 5)
            .sheet(isPresented: $showCaptureModes) {
                CaptureModePicker(selection: $captureMode, timerMode: $timerMode) {
                    showCaptureModes = false
                }
                .presentationDetents([.height(430)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(0)
                .presentationBackground(CameraTheme.panel)
            }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            flashButton
            captureModeButton
            Spacer(minLength: 0)
            squareTool("camera.rotate.fill", label: "Switch camera", action: onSwitchCamera)
            importTool
            squareTool("slider.horizontal.3", label: "Open camera settings", action: onSettings)
        }
    }

    private var importTool: some View {
        PhotosPicker(selection: $pickedItem, matching: .images) {
            Image(systemName: "photo.on.rectangle")
                .pocketHUDFont(15, weight: .semibold)
                .foregroundStyle(CameraTheme.ink)
                .frame(width: CameraTheme.control, height: CameraTheme.control)
                .background(CameraTheme.cameraWell.opacity(0.94))
                .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                .frame(width: CameraTheme.hit, height: CameraTheme.hit, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Import photo")
    }

    private var flashButton: some View {
            Button(action: onFlash) {
                HStack(spacing: 6) {
                    Image(systemName: flashSymbol)
                        .pocketHUDFont(14, weight: .semibold)
                    Text(flashLabel)
                        .pocketHUDFont(9, weight: .bold, design: .monospaced)
                        .tracking(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(flashIsActive ? CameraTheme.accent : CameraTheme.muted)
                .padding(.horizontal, 10)
                .frame(height: CameraTheme.control)
                .background(CameraTheme.cameraWell.opacity(0.94))
                .overlay {
                    Rectangle().stroke(flashIsActive ? CameraTheme.accent : CameraTheme.line, lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isFlashAvailable && captureMode == .standard ? 1 : 0.45)
            .disabled(!(isFlashAvailable && captureMode == .standard))
            .accessibilityLabel(isFrontCamera ? "Screen fill light, \(flashLabel)" : "Flash, \(flashLabel)")
    }

    private var captureModeButton: some View {
            Button {
                showCaptureModes = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: captureModeSymbol)
                        .pocketHUDFont(14, weight: .semibold)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(captureMode.shortTitle)
                            .pocketHUDFont(9, weight: .bold, design: .monospaced)
                            .tracking(0.8)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text("TIMER \(timerMode == .off ? String(localized: "OFF") : timerMode.shortTitle)")
                            .pocketHUDFont(7.5, weight: .semibold, design: .monospaced)
                            .tracking(0.4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .foregroundStyle(timerMode == .off ? CameraTheme.muted : CameraTheme.accent)
                    }
                    Image(systemName: "chevron.down")
                        .pocketHUDFont(8, weight: .bold)
                        .foregroundStyle(CameraTheme.muted)
                }
                .foregroundStyle(CameraTheme.ink)
                .padding(.horizontal, 9)
                .frame(height: CameraTheme.control)
                .background(CameraTheme.cameraWell.opacity(0.94))
                .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
    }

    private var flashIsActive: Bool {
        isFlashAvailable && captureMode == .standard && flashMode != .off
    }

    @ViewBuilder
    private func squareTool(_ symbol: String, label: LocalizedStringKey, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol)
                    .pocketHUDFont(15, weight: .semibold)
                    .foregroundStyle(CameraTheme.ink)
                    .frame(width: CameraTheme.control, height: CameraTheme.control)
                    .background(CameraTheme.cameraWell.opacity(0.94))
                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                if badge > 0 {
                    Text(badge, format: .number)
                        .pocketHUDFont(7.5, weight: .bold, design: .monospaced)
                        .foregroundStyle(.black)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(CameraTheme.accent, in: Circle())
                        .offset(x: 2, y: -2)
                }
            }
            .frame(width: CameraTheme.hit, height: CameraTheme.hit, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var flashLabel: String {
        guard isFlashAvailable else { return String(localized: "N/A") }
        if isFrontCamera && captureMode == .standard {
            return flashMode == .on ? String(localized: "FILL") : String(localized: "OFF")
        }
        return switch captureMode {
        case .standard:
            switch flashMode {
            case .on: String(localized: "ON")
            case .auto: String(localized: "AUTO")
            default: String(localized: "OFF")
            }
        case .flashParty: String(localized: "FLASH")
        case .flashPair, .flashSequence: String(localized: "MIX")
        case .moment: String(localized: "VIDEO")
        }
    }

    private var flashSymbol: String {
        guard isFlashAvailable else { return "bolt.slash" }
        if isFrontCamera && captureMode == .standard {
            return flashMode == .on ? "sun.max.fill" : "sun.max"
        }
        return switch captureMode {
        case .standard:
            switch flashMode {
            case .on: "bolt.fill"
            case .auto: "bolt.badge.a"
            default: "bolt.slash.fill"
            }
        case .flashParty: "bolt.fill"
        case .flashPair, .flashSequence: "bolt.badge.clock.fill"
        case .moment: "video.fill"
        }
    }

    private var captureModeSymbol: String {
        switch captureMode {
        case .standard: "camera.fill"
        case .moment: "video.fill"
        case .flashParty: "person.3.fill"
        case .flashPair: "rectangle.split.2x1.fill"
        case .flashSequence: "square.stack.3d.up.fill"
        }
    }
}

private struct CaptureModePicker: View {
    @Binding var selection: CaptureMode
    @Binding var timerMode: CaptureTimer
    let completion: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SHOOTING MODE")
                    .pocketHUDFont(9, weight: .bold, design: .monospaced)
                    .tracking(2)
                    .foregroundStyle(CameraTheme.ink)
                Spacer()
                Button(action: completion) {
                    Image(systemName: "xmark")
                        .pocketHUDFont(12, weight: .semibold)
                        .foregroundStyle(CameraTheme.muted)
                        .frame(width: CameraTheme.control, height: CameraTheme.control)
                        .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .frame(width: CameraTheme.hit, height: CameraTheme.hit)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                ForEach(CaptureTimer.allCases) { mode in
                    Button {
                        timerMode = mode
                    } label: {
                        Text(verbatim: timerTitle(mode))
                            .pocketHUDFont(8.5, weight: .bold, design: .monospaced)
                            .tracking(1)
                            .foregroundStyle(timerMode == mode ? .black : CameraTheme.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(timerMode == mode ? CameraTheme.accent : CameraTheme.cameraWell)
                            .overlay {
                                Rectangle().stroke(timerMode == mode ? CameraTheme.accent : CameraTheme.line, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    modeCard(.standard)
                    modeCard(.flashParty)
                }
                HStack(spacing: 8) {
                    modeCard(.flashPair)
                    modeCard(.flashSequence)
                }
                modeCard(.moment)
            }
            .padding(.horizontal, 14)

            Text("The selected camera look is applied to every mode.")
                .pocketFont(10)
                .foregroundStyle(CameraTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CameraTheme.panel.ignoresSafeArea())
        .foregroundStyle(CameraTheme.ink)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func modeCard(_ mode: CaptureMode) -> some View {
        let isSelected = selection == mode
        Button {
            selection = mode
            completion()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: symbol(for: mode))
                        .pocketHUDFont(15, weight: .semibold)
                        .foregroundStyle(isSelected ? CameraTheme.accent : CameraTheme.muted)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .pocketHUDFont(10, weight: .bold)
                            .foregroundStyle(CameraTheme.accent)
                    }
                }
                Text(mode.title)
                    .pocketHUDFont(9.5, weight: .bold, design: .monospaced)
                    .tracking(1)
                    .foregroundStyle(isSelected ? CameraTheme.accent : CameraTheme.ink)
                    .padding(.top, 6)
                Text(detail(for: mode))
                    .pocketHUDFont(7.5, weight: .semibold, design: .monospaced)
                    .tracking(0.3)
                    .foregroundStyle(CameraTheme.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 3)
            }
            .padding(9)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .background(CameraTheme.cameraWell)
            .overlay {
                Rectangle().stroke(isSelected ? CameraTheme.accent : CameraTheme.line.opacity(0.7), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func timerTitle(_ mode: CaptureTimer) -> String {
        switch mode {
        case .off: "OFF"
        case .three: "3S"
        case .ten: "10S"
        }
    }

    private func symbol(for mode: CaptureMode) -> String {
        switch mode {
        case .standard: "camera.fill"
        case .flashParty: "person.3.fill"
        case .flashPair: "rectangle.split.2x1"
        case .flashSequence: "square.stack.3d.up.fill"
        case .moment: "video.fill"
        }
    }

    private func detail(for mode: CaptureMode) -> LocalizedStringResource {
        switch mode {
        case .standard: "One finished photo with the active camera."
        case .flashParty: "A short flash burst that recommends the best frame."
        case .flashPair: "Ambient and direct-flash versions of the same moment."
        case .flashSequence: "Ambient, flash, and reaction in three beats."
        case .moment: "A two-second clip with a still and Live Photo option."
        }
    }
}

private struct LookSelector: View {
    @Binding var selection: CCDLook
    let isFullUnlocked: Bool
    let onLockedLook: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let visibleCount: CGFloat = geometry.size.width >= 470 ? 5 : 4
            let cardWidth = max(88, (geometry.size.width - (visibleCount - 1) * 6) / visibleCount)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(CCDLook.allCases) { look in
                            let isSelected = selection == look
                            let isLocked = !ProductAccess.canUse(look, isFullUnlocked: isFullUnlocked)
                            Button {
                                // A locked body is a trial: it previews and shoots, but the
                                // frame is never stored. Selection is no longer blocked.
                                withAnimation(.easeOut(duration: 0.16)) { selection = look }
                            } label: {
                                VStack(spacing: 3) {
                                    ZStack(alignment: .topTrailing) {
                                        CameraBodyThumbnail(look: look)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 38)
                                        if isLocked {
                                            Text("TRIAL")
                                                .pocketHUDFont(5.5, weight: .bold, design: .monospaced)
                                                .tracking(0.5)
                                                .foregroundStyle(CameraTheme.accent)
                                                .padding(.horizontal, 3.5)
                                                .frame(height: 12)
                                                .background(.black.opacity(0.78))
                                                .overlay {
                                                    Rectangle().stroke(CameraTheme.accent.opacity(0.7), lineWidth: 0.6)
                                                }
                                                .padding(.top, 3)
                                                .padding(.trailing, 3)
                                        }
                                    }

                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(isSelected ? CameraTheme.color(for: look.accent) : CameraTheme.muted.opacity(0.45))
                                            .frame(width: 4.5, height: 4.5)
                                        Text(look.shortName)
                                            .pocketHUDFont(8.5, weight: .bold, design: .monospaced)
                                            .tracking(0.7)
                                            .lineLimit(1)
                                        Text(look.personality)
                                            .pocketHUDFont(6.5, weight: .semibold, design: .monospaced)
                                            .tracking(0.3)
                                            .textCase(.uppercase)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.72)
                                            .opacity(isSelected ? 0.92 : 0.65)
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.bottom, 4)
                                }
                                .foregroundStyle(isSelected ? CameraTheme.accent : CameraTheme.ink.opacity(0.76))
                                .frame(width: cardWidth, height: 62)
                                .background(CameraTheme.cameraWell)
                                .overlay {
                                    Rectangle().stroke(isSelected ? CameraTheme.accent : CameraTheme.line.opacity(0.55), lineWidth: isSelected ? 1.2 : 1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(look.shortName) camera")
                            .accessibilityValue(Text(look.personality))
                            .accessibilityHint(Text(look.stripCaption))
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .id(look)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: selection) { _, look in
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(look, anchor: .center) }
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .frame(height: 62)
        .padding(.horizontal, 12)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Renders the real de-branded camera body asset when present in `Assets.xcassets`,
/// and falls back to a bespoke metallic compact-camera silhouette until all bodies
/// have photo assets installed.
private struct CameraBodyThumbnail: View {
    let look: CCDLook

    var body: some View {
        if let image = UIImage(named: look.bodyAssetName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(.top, 2)
                .padding(.horizontal, 4)
        } else {
            CompactCameraBodyGraphic(look: look)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
        }
    }
}

private struct CompactCameraBodyGraphic: View {
    let look: CCDLook

    var body: some View {
        let style = bodyStyle
        ZStack {
            // Main de-branded metallic/matte body
            RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [style.bodyTop, style.bodyMid, style.bodyBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    if style.twoToneTop {
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(white: 0.80), Color(white: 0.62)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(height: 10)
                            Spacer(minLength: 0)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
                    }
                }
                .overlay(alignment: .leading) {
                    if style.hasGrip {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.black.opacity(0.32))
                            .frame(width: 11)
                            .padding(.vertical, 3)
                            .padding(.leading, 3)
                    } else if style.hasSlideSeam {
                        Rectangle()
                            .fill(Color.black.opacity(0.28))
                            .frame(width: 1)
                            .padding(.leading, 18)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .stroke(style.rimColor, lineWidth: 0.75)
                }

            // Flash + viewfinder + LED
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.94), Color(white: 0.70)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: style.wideFlash ? 13 : 9, height: 4.5)
                    .overlay {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .stroke(Color.black.opacity(0.45), lineWidth: 0.5)
                    }
                if style.hasViewfinder {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color(white: 0.14))
                        .frame(width: 4.5, height: 4.5)
                        .overlay {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .stroke(Color.white.opacity(0.25), lineWidth: 0.4)
                        }
                }
                Circle()
                    .fill(CameraTheme.color(for: look.accent))
                    .frame(width: 2.6, height: 2.6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 14)

            // Lens barrel
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [style.ringOuter, style.ringInner],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 20, height: 20)
                    .overlay {
                        Circle().stroke(Color.black.opacity(0.55), lineWidth: 0.75)
                    }
                Circle()
                    .fill(Color(white: 0.10))
                    .frame(width: 13.5, height: 13.5)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [style.glassTint.opacity(0.55), Color.black],
                            center: .topLeading,
                            startRadius: 1,
                            endRadius: 6
                        )
                    )
                    .frame(width: 9, height: 9)
                Circle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 2.2, height: 2.2)
                    .offset(x: -2, y: -2)
            }
            .offset(x: style.lensCentered ? 2 : 11, y: 1.5)
        }
        .aspectRatio(1.58, contentMode: .fit)
    }

    private struct BodyStyle {
        let bodyTop: Color
        let bodyMid: Color
        let bodyBottom: Color
        let rimColor: Color
        let ringOuter: Color
        let ringInner: Color
        let glassTint: Color
        let cornerRadius: CGFloat
        let wideFlash: Bool
        let hasViewfinder: Bool
        let hasGrip: Bool
        let hasSlideSeam: Bool
        let twoToneTop: Bool
        let lensCentered: Bool
    }

    private var bodyStyle: BodyStyle {
        switch look {
        case .amber:
            BodyStyle(
                bodyTop: Color(red: 0.78, green: 0.74, blue: 0.67),
                bodyMid: Color(red: 0.65, green: 0.61, blue: 0.55),
                bodyBottom: Color(red: 0.48, green: 0.45, blue: 0.40),
                rimColor: Color.white.opacity(0.35),
                ringOuter: Color(white: 0.86),
                ringInner: Color(white: 0.52),
                glassTint: Color(red: 0.65, green: 0.35, blue: 0.55),
                cornerRadius: 4.5, wideFlash: false, hasViewfinder: true,
                hasGrip: false, hasSlideSeam: false, twoToneTop: false, lensCentered: false
            )
        case .party:
            BodyStyle(
                bodyTop: Color(white: 0.88),
                bodyMid: Color(white: 0.74),
                bodyBottom: Color(white: 0.56),
                rimColor: Color.white.opacity(0.45),
                ringOuter: Color(white: 0.92),
                ringInner: Color(white: 0.62),
                glassTint: Color(red: 0.55, green: 0.42, blue: 0.75),
                cornerRadius: 4, wideFlash: true, hasViewfinder: false,
                hasGrip: false, hasSlideSeam: true, twoToneTop: false, lensCentered: false
            )
        case .chrome:
            BodyStyle(
                bodyTop: Color(red: 0.74, green: 0.78, blue: 0.83),
                bodyMid: Color(red: 0.58, green: 0.62, blue: 0.67),
                bodyBottom: Color(red: 0.42, green: 0.45, blue: 0.50),
                rimColor: Color(red: 0.75, green: 0.86, blue: 1.0).opacity(0.45),
                ringOuter: Color(white: 0.84),
                ringInner: Color(white: 0.48),
                glassTint: Color(red: 0.30, green: 0.62, blue: 0.95),
                cornerRadius: 2.5, wideFlash: false, hasViewfinder: true,
                hasGrip: false, hasSlideSeam: false, twoToneTop: false, lensCentered: false
            )
        case .night:
            BodyStyle(
                bodyTop: Color(red: 0.32, green: 0.34, blue: 0.36),
                bodyMid: Color(red: 0.22, green: 0.24, blue: 0.26),
                bodyBottom: Color(red: 0.14, green: 0.15, blue: 0.17),
                rimColor: Color.white.opacity(0.32),
                ringOuter: Color(white: 0.48),
                ringInner: Color(white: 0.22),
                glassTint: Color(red: 0.22, green: 0.82, blue: 0.56),
                cornerRadius: 3, wideFlash: true, hasViewfinder: false,
                hasGrip: false, hasSlideSeam: true, twoToneTop: false, lensCentered: false
            )
        case .mono:
            BodyStyle(
                bodyTop: Color(white: 0.24),
                bodyMid: Color(white: 0.16),
                bodyBottom: Color(white: 0.11),
                rimColor: Color.white.opacity(0.38),
                ringOuter: Color(white: 0.82),
                ringInner: Color(white: 0.46),
                glassTint: Color(white: 0.60),
                cornerRadius: 3, wideFlash: false, hasViewfinder: false,
                hasGrip: true, hasSlideSeam: false, twoToneTop: false, lensCentered: true
            )
        case .negative:
            BodyStyle(
                bodyTop: Color(white: 0.22),
                bodyMid: Color(white: 0.16),
                bodyBottom: Color(white: 0.11),
                rimColor: Color.white.opacity(0.35),
                ringOuter: Color(white: 0.80),
                ringInner: Color(white: 0.44),
                glassTint: Color(red: 0.22, green: 0.74, blue: 0.70),
                cornerRadius: 3.5, wideFlash: false, hasViewfinder: true,
                hasGrip: false, hasSlideSeam: false, twoToneTop: true, lensCentered: true
            )
        }
    }
}

private struct ShutterControls: View {
    let thumbnail: UIImage?
    let rollCount: Int
    let look: CCDLook
    let availableLenses: [CameraLens]
    let selectedLens: CameraLens
    let isCapturing: Bool
    let onRoll: () -> Void
    let onLens: (CameraLens) -> Void
    let onShutter: () -> Void
    @State private var showLenses = false

    var body: some View {
        // The shutter sits in a ZStack, not between the side controls: the
        // roll well and the lens chip are different widths, so an HStack put
        // the shutter 9 pt off centre.
        ZStack {
            HStack(spacing: 0) {
                Button(action: onRoll) {
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            Rectangle().fill(CameraTheme.cameraWell)
                            if let thumbnail {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: CameraTheme.hit - 6, height: CameraTheme.hit - 6)
                                    .clipped()
                            } else {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(CameraTheme.ink)
                            }
                        }
                        .frame(width: CameraTheme.hit, height: CameraTheme.hit)
                        .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }

                        if rollCount > 0 {
                            Text(rollCount, format: .number)
                                .pocketHUDFont(7.5, weight: .bold, design: .monospaced)
                                .foregroundStyle(.black)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(CameraTheme.accent, in: Circle())
                                .offset(x: 4, y: -4)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pocket Roll, \(rollCount) photos")

                Spacer(minLength: 0)

                let canSwitchLens = availableLenses.count > 1
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { showLenses.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: "\(selectedLens.rawValue) \(selectedLens.focalLengthLabel)")
                            .pocketHUDFont(9, weight: .bold, design: .monospaced)
                            .tracking(0.4)
                        if canSwitchLens {
                            Image(systemName: "chevron.down")
                                .pocketHUDFont(7, weight: .bold)
                                .foregroundStyle(CameraTheme.muted)
                        }
                    }
                    .foregroundStyle(CameraTheme.ink)
                    .frame(width: 78, height: CameraTheme.control)
                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                    .frame(width: 78, height: CameraTheme.hit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(canSwitchLens ? 1 : 0.55)
                .disabled(!canSwitchLens)
                .accessibilityLabel("Select lens, current \(selectedLens.rawValue)")
                .onChange(of: availableLenses.count) { _, count in
                    if count <= 1 { showLenses = false }
                }
            }

            Button(action: onShutter) {
                ZStack {
                    Circle()
                        .stroke(CameraTheme.ink, lineWidth: 2)
                        .frame(width: 72, height: 72)
                    Circle()
                        .fill(CameraTheme.ink)
                        .frame(width: 56, height: 56)
                        .scaleEffect(isCapturing ? 0.86 : 1)
                }
                .frame(width: CameraTheme.hit + 32, height: 80)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCapturing)
            .accessibilityLabel("Take photo")
            .accessibilityHint(isCapturing ? "Capture in progress" : "Double tap to capture")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .overlay(alignment: .bottomTrailing) {
            if showLenses {
                HStack(spacing: 6) {
                    ForEach(availableLenses) { lens in
                        Button {
                            onLens(lens)
                            withAnimation(.easeOut(duration: 0.14)) { showLenses = false }
                        } label: {
                            Text(verbatim: lens.rawValue)
                                .pocketHUDFont(10, weight: .bold, design: .monospaced)
                                .foregroundStyle(lens == selectedLens ? Color.black : CameraTheme.ink)
                                .frame(width: 44, height: CameraTheme.control)
                                .background(lens == selectedLens ? CameraTheme.accent : CameraTheme.cameraWell)
                                .overlay { Rectangle().stroke(lens == selectedLens ? CameraTheme.accent : CameraTheme.line, lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(CameraTheme.panel)
                .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                .padding(.trailing, 12)
                .offset(y: -64)
                .transition(.opacity)
                .zIndex(5)
            }
        }
    }
}

private struct CaptureGuideOverlay: View {
    let dismiss: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("YOUR FIRST PHOTO")
                    .pocketHUDFont(8, weight: .bold, design: .monospaced)
                    .tracking(2)
                    .foregroundStyle(CameraTheme.paperInk.opacity(0.55))
                Text("What you see is the finished look")
                    .pocketHUDFont(20, weight: .bold)
                Text("Tap the image to focus, pinch to zoom, and open EV when you want a brighter or darker result.")
                    .pocketHUDFont(12.5)
                    .foregroundStyle(CameraTheme.paperMuted)
                    .fixedSize(horizontal: false, vertical: true)
                PocketButton(title: "START SHOOTING", action: dismiss)
                    .padding(.top, 4)
            }
            .padding(18)
            // Duo / iPad: the guide card used to span the whole 1540 pt width.
            .frame(maxWidth: 640)
            .background(CameraTheme.paper)
            .foregroundStyle(CameraTheme.paperInk)
            .overlay { Rectangle().stroke(CameraTheme.paperInk.opacity(0.16), lineWidth: 1) }
            .padding(.horizontal, 30)
            .padding(.bottom, 228)
        }
        .background(.black.opacity(0.16))
        .accessibilityElement(children: .contain)
    }
}

private struct CountdownOverlay: View {
    let value: Int
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Text(value, format: .number)
                .pocketHUDFont(92, weight: .light, design: .monospaced)
                .foregroundStyle(CameraTheme.accent)
                .contentTransition(.numericText())
            Button(action: onCancel) {
                Text("CANCEL")
                    .pocketHUDFont(9, weight: .bold, design: .monospaced)
                    .tracking(1.6)
                    .foregroundStyle(CameraTheme.ink)
                    .frame(width: 120, height: 36)
                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.48))
        .accessibilityElement(children: .contain)
    }
}

private struct CaptureProgressOverlay: View {
    let current: Int
    let total: Int

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.18)).frame(height: 2)
                    Rectangle()
                        .fill(CameraTheme.accent)
                        .frame(width: max(2, proxy.size.width * CGFloat(current) / CGFloat(max(total, 1))), height: 2)
                }
            }
            .frame(width: 150, height: 2)
            Text("CAPTURING \(current)/\(total)")
                .pocketHUDFont(8.5, weight: .bold, design: .monospaced)
                .tracking(1.4)
                .foregroundStyle(CameraTheme.ink)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.black.opacity(0.78))
        .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

private struct StatusToast: View {
    let message: LocalizedStringResource

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(CameraTheme.paperInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(CameraTheme.paper)
            .overlay { Rectangle().stroke(CameraTheme.paperInk.opacity(0.16), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
    }
}

private struct CameraInterruptionBanner: View {
    let message: LocalizedStringResource
    let resume: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .pocketHUDFont(13, weight: .semibold)
                .foregroundStyle(CameraTheme.accent)
            Text(message)
                .pocketHUDFont(12)
                .foregroundStyle(CameraTheme.ink)
            Spacer(minLength: 4)
            Button(action: resume) {
                Text("RESUME")
                    .pocketHUDFont(8.5, weight: .bold, design: .monospaced)
                    .tracking(1.4)
                    .foregroundStyle(CameraTheme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: CameraTheme.control)
                    .overlay { Rectangle().stroke(CameraTheme.accent, lineWidth: 1) }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(CameraTheme.panel)
        .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
    }
}

private struct CameraSettingsView: View {
    @Binding var focalLengthRaw: Int
    @Binding var dateStampFormatRaw: String
    @Binding var gridEnabled: Bool
    @Binding var dateStampEnabled: Bool
    @Binding var aspectRatio: CaptureAspectRatio
    @Binding var autoSaveEnabled: Bool
    @Binding var capturePreviewEnabled: Bool
    @Binding var gestureShutterEnabled: Bool
    @Binding var delayedRollEnabled: Bool
    @Binding var rollCapacity: Int
    @Binding var shutterSoundEnabled: Bool
    @Binding var sensorFingerprintEnabled: Bool
    @Binding var keepOriginalFrames: Bool
    let rollStore: RollStore
    let pairedCapture: PairedCaptureService
    let selectedLook: CCDLook
    let calibrationStore: CalibrationStore
    @Bindable var camera: CameraController
    @Bindable var purchaseStore: PurchaseStore
    @AppStorage(LocationTagger.enabledKey) private var locationTaggingEnabled = false
    @AppStorage("halationLevel") private var halationLevel = 2
    @AppStorage("vintageLcdPreviewEnabled") private var vintageLcdPreviewEnabled = false
    @AppStorage("shareBorderEnabled") private var shareBorderEnabled = false
    let onDualMemory: () -> Void
    let onPairedCapture: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var originalStats = OriginalArchiveStats()
    @State private var showClearOriginals = false
    @State private var isClearingOriginals = false

    private var originalStatsLine: String {
        "\(originalStats.captures) · \(originalStats.bytes.formatted(.byteCount(style: .file)))"
    }

    private func refreshOriginalStats() async {
        originalStats = await OriginalFrameArchive.shared.stats()
    }

    private var summaryLine: String {
        let save = autoSaveEnabled
            ? String(localized: "AUTO SAVE")
            : String(localized: "REVIEW FIRST")
        return "\(selectedLook.rawValue)  ·  \(aspectRatio.rawValue)  ·  \(save)  ·  \(rollStore.entries.count)/\(rollStore.capacity)"
    }

    var body: some View {
        ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Camera Setup")
                            .pocketFont(26, weight: .bold)
                            .foregroundStyle(CameraTheme.ink)
                        Text(verbatim: summaryLine)
                            .pocketFont(9, weight: .bold, design: .monospaced)
                            .tracking(1.2)
                            .foregroundStyle(CameraTheme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                    .padding(.top, 4)
                    SettingsGroup("CAMERA", symbol: "viewfinder") {
                        SettingsToggleRow("Composition grid", symbol: "grid", isOn: $gridEnabled)
                        SettingsDivider()
                        SettingsToggleRow("2.5″ CCD LCD Preview", symbol: "tv", isOn: $vintageLcdPreviewEnabled)
                        SettingsDivider()
                        SettingsToggleRow("Date stamp", symbol: "calendar", isOn: $dateStampEnabled)
                        SettingsDivider()
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Date stamp format", systemImage: "textformat")
                                .pocketFont(12.5, weight: .semibold)
                                .foregroundStyle(CameraTheme.ink)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                                ForEach(DateStampFormat.allCases) { format in
                                    let isSelected = dateStampFormatRaw == format.rawValue
                                    Button {
                                        dateStampFormatRaw = format.rawValue
                                    } label: {
                                        Text(format.title)
                                            .pocketHUDFont(9, weight: .bold, design: .monospaced)
                                            .tracking(0.6)
                                            .frame(maxWidth: .infinity, minHeight: 34)
                                            .foregroundStyle(isSelected ? .black : CameraTheme.ink)
                                            .background(isSelected ? CameraTheme.accent : CameraTheme.cameraWell)
                                            .overlay {
                                                Rectangle().stroke(isSelected ? CameraTheme.accent : CameraTheme.line, lineWidth: 1)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(14)
                        SettingsDivider()
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Photo shape", systemImage: "aspectratio")
                                .pocketFont(12.5, weight: .semibold)
                                .foregroundStyle(CameraTheme.ink)
                            HStack(spacing: 6) {
                                ForEach(CaptureAspectRatio.allCases) { ratio in
                                    let isSelected = aspectRatio == ratio
                                    Button {
                                        aspectRatio = ratio
                                    } label: {
                                        Text(ratio.rawValue)
                                            .pocketHUDFont(9, weight: .bold, design: .monospaced)
                                            .tracking(0.6)
                                            .frame(maxWidth: .infinity, minHeight: 36)
                                            .foregroundStyle(isSelected ? .black : CameraTheme.ink)
                                            .background(isSelected ? CameraTheme.accent : CameraTheme.cameraWell)
                                            .overlay {
                                                Rectangle().stroke(isSelected ? CameraTheme.accent : CameraTheme.line, lineWidth: 1)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(14)
                        SettingsDivider()
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Focal length", systemImage: "camera.aperture")
                                .pocketFont(12.5, weight: .semibold)
                                .foregroundStyle(CameraTheme.ink)
                            HStack(spacing: 6) {
                                ForEach([35, 50], id: \.self) { mm in
                                    let isSelected = focalLengthRaw == mm
                                    Button {
                                        focalLengthRaw = mm
                                    } label: {
                                        Text(verbatim: "\(mm) mm")
                                            .pocketHUDFont(9, weight: .bold, design: .monospaced)
                                            .tracking(0.6)
                                            .frame(maxWidth: .infinity, minHeight: 36)
                                            .foregroundStyle(isSelected ? .black : CameraTheme.ink)
                                            .background(isSelected ? CameraTheme.accent : CameraTheme.cameraWell)
                                            .overlay {
                                                Rectangle().stroke(isSelected ? CameraTheme.accent : CameraTheme.line, lineWidth: 1)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(14)
                        SettingsDivider()
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Glow", systemImage: "sun.max")
                                .pocketFont(12.5, weight: .semibold)
                                .foregroundStyle(CameraTheme.ink)
                            HStack(spacing: 4) {
                                ForEach(HalationLevel.allCases) { level in
                                    let isSelected = halationLevel == level.rawValue
                                    Button {
                                        halationLevel = level.rawValue
                                    } label: {
                                        Text(level.title)
                                            .pocketHUDFont(8.5, weight: .bold, design: .monospaced)
                                            .tracking(0.4)
                                            .frame(maxWidth: .infinity, minHeight: 36)
                                            .foregroundStyle(isSelected ? .black : CameraTheme.ink)
                                            .background(isSelected ? CameraTheme.accent : CameraTheme.cameraWell)
                                            .overlay {
                                                Rectangle().stroke(isSelected ? CameraTheme.accent : CameraTheme.line, lineWidth: 1)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(14)
                        SettingsDivider()
                        SettingsToggleRow("Location tag", symbol: "location", isOn: $locationTaggingEnabled)
                    }
                    PocketFootnote("Location is written into new photos only while this switch is on.")
                    SettingsGroup("SAVE & ROLL", symbol: "film.stack") {
                        SettingsToggleRow("Capture preview", symbol: "eye", isOn: $capturePreviewEnabled)
                        SettingsDivider()
                        SettingsToggleRow("Automatically save photos", symbol: "square.and.arrow.down", isOn: $autoSaveEnabled)
                        SettingsDivider()
                        SettingsToggleRow("Share frame", symbol: "rectangle.inset.filled", isOn: $shareBorderEnabled)
                        SettingsDivider()
                        NavigationLink {
                            PocketRollView(store: rollStore)
                        } label: {
                            SettingsLinkRow("Current roll", symbol: "film", value: "\(rollStore.entries.count)/\(rollStore.capacity)")
                        }
                        SettingsDivider()
                        HStack(spacing: 8) {
                            Text("Roll size")
                                .pocketFont(12.5)
                                .foregroundStyle(CameraTheme.ink)
                            Spacer(minLength: 8)
                            ForEach([12, 24], id: \.self) { size in
                                let isSelected = rollCapacity == size
                                Button {
                                    rollCapacity = size
                                } label: {
                                    Text(verbatim: "\(size)")
                                        .pocketFont(9, weight: .bold, design: .monospaced)
                                        .foregroundStyle(isSelected ? .black : CameraTheme.ink)
                                        .frame(width: 42, height: 28)
                                        .background(isSelected ? CameraTheme.accent : CameraTheme.cameraWell)
                                        .overlay {
                                            Rectangle().stroke(isSelected ? CameraTheme.accent : CameraTheme.line, lineWidth: 1)
                                        }
                                }
                                .buttonStyle(.plain)
                                .disabled(size < rollStore.entries.count)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        SettingsDivider()
                        SettingsToggleRow("Delayed development", symbol: "hourglass", isOn: $delayedRollEnabled)
                    }
                    SettingsGroup("NEGATIVES", symbol: "tray.and.arrow.down") {
                        SettingsToggleRow("Keep digital negatives", symbol: "photo.on.rectangle.angled", isOn: $keepOriginalFrames)
                        if originalStats.captures > 0 {
                            SettingsDivider()
                            HStack(spacing: 8) {
                                Text("On this iPhone")
                                    .pocketFont(12.5)
                                    .foregroundStyle(CameraTheme.ink)
                                Spacer(minLength: 8)
                                Text(verbatim: originalStatsLine)
                                    .pocketFont(9, weight: .bold, design: .monospaced)
                                    .foregroundStyle(CameraTheme.muted)
                                Button {
                                    showClearOriginals = true
                                } label: {
                                    Text("CLEAR")
                                        .pocketFont(9, weight: .bold, design: .monospaced)
                                        .foregroundStyle(CameraTheme.ink)
                                        .padding(.horizontal, 10)
                                        .frame(height: 28)
                                        .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.leading, 12)
                            .padding(.trailing, 8)
                            .frame(height: 50)
                        }
                    }
                    PocketFootnote("Like a negative, every shot keeps the camera’s untouched file. Re-develop it with another camera later, or re-run a new tuning on old photos. Files stay on this iPhone.")
                    SettingsGroup("SHOOTING", symbol: "camera.fill") {
                        NavigationLink {
                            CreativeCaptureSettingsView(
                                gestureShutterEnabled: $gestureShutterEnabled,
                                shutterSoundEnabled: $shutterSoundEnabled,
                                sensorFingerprintEnabled: $sensorFingerprintEnabled,
                                pairedCapture: pairedCapture,
                                onDualMemory: { dismiss(); onDualMemory() },
                                onPairedCapture: { dismiss(); onPairedCapture() }
                            )
                        } label: {
                            SettingsLinkRow("Group and paired capture", symbol: "person.2.crop.square.stack")
                        }
                        SettingsDivider()
                        NavigationLink {
                            ManualCameraControlsView(camera: camera)
                        } label: {
                            SettingsLinkRow("Exposure and white balance", symbol: "dial.high",
                                            value: camera.proModeEnabled
                                                ? String(localized: "Manual")
                                                : String(localized: "Automatic"))
                        }
                    }
                    SettingsGroup("POCKETCCD", symbol: "camera.aperture") {
                        if purchaseStore.isFullUnlocked {
                            PocketLabeledRow(
                                title: "Pocket CCD Full",
                                detail: "Every camera body is unlocked on this Apple Account.",
                                value: String(localized: "Unlocked"),
                                symbol: "checkmark.seal.fill"
                            )
                        } else {
                            NavigationLink {
                                UpgradeView(store: purchaseStore)
                            } label: {
                                SettingsLinkRow("Pocket CCD Full", symbol: "sparkles", value: String(localized: "One-time purchase"))
                            }
                            SettingsDivider()
                            Button {
                                Task { await purchaseStore.restorePurchases() }
                            } label: {
                                SettingsLinkRow("Restore Purchases", symbol: "arrow.clockwise", showsChevron: false)
                            }
                            .buttonStyle(.plain)
                        }
                        SettingsDivider()
                        NavigationLink { PocketCameraGuideView() } label: { SettingsLinkRow("Camera Guide", symbol: "book.closed") }
                        SettingsDivider()
                        NavigationLink { PocketPrivacyView() } label: { SettingsLinkRow("Privacy", symbol: "hand.raised") }
                        SettingsDivider()
                        NavigationLink { PocketAboutView() } label: { SettingsLinkRow("About Pocket CCD", symbol: "info.circle") }
                    }
                    HStack(spacing: 18) {
                        Label("Tap to focus", systemImage: "viewfinder")
                        Label("Pinch to zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .font(.caption)
                    .foregroundStyle(CameraTheme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 12)
                }
                .padding(16)
                // Duo / iPad width: keep the settings column readable instead
                // of stretching every row across 1500 pt.
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        .background(CameraTheme.background)
        .tint(CameraTheme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { PocketDismissBar() }
        .pocketSwipeBack()
        .task {
            await purchaseStore.refreshEntitlements()
            LocationTagger.shared.resumeIfEnabledAndAuthorized()
            await refreshOriginalStats()
        }
        .onChange(of: locationTaggingEnabled) { _, enabled in
            LocationTagger.shared.setEnabled(enabled)
        }
        .overlay {
            PocketSheet("DIGITAL NEGATIVES", isPresented: $showClearOriginals) {
                PocketActionRow(
                    title: isClearingOriginals ? "Deleting…" : "Delete negatives",
                    symbol: "trash",
                    destructive: true
                ) {
                    guard !isClearingOriginals else { return }
                    isClearingOriginals = true
                    showClearOriginals = false
                    Task { @MainActor in
                        await OriginalFrameArchive.shared.removeAll()
                        await refreshOriginalStats()
                        isClearingOriginals = false
                    }
                }
                PocketSheetDivider()
                PocketActionRow(title: "Cancel", symbol: "xmark") {
                    showClearOriginals = false
                }
            }
        }
        .overlay {
            PocketAlert(
                title: "POCKETCCD",
                message: purchaseStore.purchaseMessage ?? "",
                isPresented: Binding(
                    get: { purchaseStore.purchaseMessage != nil },
                    set: { if !$0 { purchaseStore.dismissMessage() } }
                )
            )
        }
    }
}

private struct CameraSetupSummary: View {
    let look: CCDLook
    let aspectRatio: CaptureAspectRatio
    let autoSaveEnabled: Bool
    let rollCount: Int

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(CameraTheme.line, lineWidth: 7)
                Circle().stroke(CameraTheme.accent.opacity(0.9), lineWidth: 2)
                Image(systemName: "camera.aperture")
                    .font(.title2)
                    .foregroundStyle(CameraTheme.accent)
            }
            .frame(width: 66, height: 66)
            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("YOUR POCKET CAMERA")
                        .font(.caption2.monospaced().bold())
                        .tracking(1.2)
                        .foregroundStyle(CameraTheme.accent)
                    Text(look.rawValue)
                        .font(.title3.monospaced().weight(.bold))
                }
                Text("\(aspectRatio.rawValue)  ·  \(autoSaveEnabled ? String(localized: "AUTO SAVE") : String(localized: "REVIEW FIRST"))  ·  \(rollCount)/24")
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(CameraTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(CameraTheme.cameraWell)
        .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(CameraTheme.muted)
                .padding(.leading, 2)
            VStack(spacing: 0) { content }
                .background(CameraTheme.cameraWell)
                .overlay { Rectangle().stroke(CameraTheme.line.opacity(0.7), lineWidth: 1) }
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String; let symbol: String; @Binding var isOn: Bool
    init(_ title: String, symbol: String, isOn: Binding<Bool>) { self.title = title; self.symbol = symbol; _isOn = isOn }
    var body: some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 12.5))
                .foregroundStyle(CameraTheme.ink)
            Spacer(minLength: 8)
            PocketToggle(isOn: $isOn)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 50)
    }
}

private struct SettingsLinkRow: View {
    let title: String; let symbol: String; var value: String?
    var showsChevron = true
    init(_ title: String, symbol: String, value: String? = nil, showsChevron: Bool = true) {
        self.title = title; self.symbol = symbol; self.value = value; self.showsChevron = showsChevron
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 12.5))
                .foregroundStyle(CameraTheme.ink)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(CameraTheme.muted)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(CameraTheme.muted)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
        .contentShape(Rectangle())
    }
}

private struct SettingsDivider: View {
    var body: some View { Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1) }
}

private struct ManualCameraControlsView: View {
    @Bindable var camera: CameraController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PocketPageTitle(
                    title: "Manual Controls",
                    subtitle: "Fixed ISO, shutter and Kelvin. Leave it off for the fastest point-and-shoot."
                )

                SettingsGroup("EXPOSURE", symbol: "dial.high") {
                    SettingsToggleRow("Manual exposure", symbol: "dial.high", isOn: Binding(
                        get: { camera.proModeEnabled },
                        set: { camera.setProMode($0) }
                    ))
                    if camera.proModeEnabled {
                        SettingsDivider()
                        VStack(spacing: 16) {
                            ProValueSlider(
                                title: "ISO",
                                value: Double(camera.manualISO),
                                range: 25 ... 1600,
                                displayValue: camera.manualISO.formatted(.number.precision(.fractionLength(0))),
                                onChange: { camera.setManualISO(Float($0)) }
                            )
                            ProValueSlider(
                                title: "SHUTTER",
                                value: camera.shutterSeconds,
                                range: 1.0 / 1000.0 ... 1.0 / 4.0,
                                displayValue: shutterLabel(camera.shutterSeconds),
                                onChange: camera.setShutterSeconds
                            )
                        }
                        .padding(12)
                    }
                }

                SettingsGroup("WHITE BALANCE", symbol: "thermometer") {
                    VStack(spacing: 16) {
                        ProValueSlider(
                            title: "KELVIN",
                            value: Double(camera.whiteBalanceKelvin),
                            range: 3000 ... 8000,
                            displayValue: "\(Int(camera.whiteBalanceKelvin))K",
                            onChange: { camera.setWhiteBalanceKelvin(Float($0)) }
                        )
                    }
                    .padding(12)
                    SettingsDivider()
                    Button(action: camera.setAutoWhiteBalance) {
                        Text("USE AUTO WHITE BALANCE")
                            .pocketFont(9, weight: .bold, design: .monospaced)
                            .tracking(1.4)
                            .foregroundStyle(CameraTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 50)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                PocketFootnote("Lower values look cooler; higher values look warmer. Auto is recommended for changing light.")
            }
            .padding(14)
        }
        .background(CameraTheme.background)
        .tint(CameraTheme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { PocketDismissBar() }
        .pocketSwipeBack()
    }

    private func shutterLabel(_ seconds: Double) -> String {
        seconds >= 1 ? seconds.formatted(.number.precision(.fractionLength(1))) + "s" : "1/\(Int((1 / seconds).rounded()))"
    }
}

private struct CreativeCaptureSettingsView: View {
    @Binding var gestureShutterEnabled: Bool
    @Binding var shutterSoundEnabled: Bool
    @Binding var sensorFingerprintEnabled: Bool
    let pairedCapture: PairedCaptureService
    let onDualMemory: () -> Void
    let onPairedCapture: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PocketPageTitle(
                    title: "More Ways to Shoot",
                    subtitle: "Group capture, gesture shutter and paired devices."
                )

                SettingsGroup("CAMERA CHARACTER", symbol: "camera.aperture") {
                    SettingsToggleRow("Shutter sound", symbol: "speaker.wave.2", isOn: $shutterSoundEnabled)
                    SettingsDivider()
                    SettingsToggleRow("Personal sensor character", symbol: "camera.aperture", isOn: $sensorFingerprintEnabled)
                }
                PocketFootnote("Keeps a subtle, stable sensor pattern on this device. It never leaves your phone.")

                SettingsGroup("GROUP CAPTURE", symbol: "person.2.crop.square.stack") {
                    SettingsToggleRow("Open-hand shutter", symbol: "hand.raised", isOn: $gestureShutterEnabled)
                    SettingsDivider()
                    NavigationLink {
                        PairedCaptureView(service: pairedCapture, onLocalShutter: onPairedCapture)
                    } label: {
                        SettingsLinkRow("Two-device paired capture", symbol: "antenna.radiowaves.left.and.right")
                    }
                }
                PocketFootnote("The hand gesture works only with the 3s or 10s timer and requires three stable detections.")

                SettingsGroup("DUAL MEMORY", symbol: "person.2.crop.square.stack") {
                    Button(action: onDualMemory) {
                        HStack(spacing: 8) {
                            Text("Capture scene + reaction")
                                .pocketFont(12.5)
                                .foregroundStyle(CameraTheme.ink)
                            Spacer(minLength: 8)
                            Image(systemName: "camera.viewfinder")
                                .pocketFont(12, weight: .semibold)
                                .foregroundStyle(CameraTheme.accent)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 50)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                PocketFootnote(LocalizedStringResource(stringLiteral: DualMemoryController.isSimultaneousSupported
                     ? "This device supports simultaneous front/rear capture."
                     : "This device uses an explicitly guided rear-then-front fallback."))
            }
            .padding(14)
        }
        .background(CameraTheme.background)
        .tint(CameraTheme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { PocketDismissBar() }
        .pocketSwipeBack()
    }
}

private struct ProValueSlider: View {
    let title: LocalizedStringResource
    let value: Double
    let range: ClosedRange<Double>
    let displayValue: String
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .pocketFont(8.5, weight: .bold, design: .monospaced)
                    .tracking(1.2)
                    .foregroundStyle(CameraTheme.muted)
                Spacer(minLength: 8)
                Text(verbatim: displayValue)
                    .pocketFont(9, weight: .bold, design: .monospaced)
                    .tracking(0.8)
                    .foregroundStyle(CameraTheme.accent)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let fraction = min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
                ZStack(alignment: .leading) {
                    Rectangle().fill(CameraTheme.line).frame(height: 2)
                    Rectangle().fill(CameraTheme.accent).frame(width: max(2, width * fraction), height: 2)
                    Rectangle()
                        .fill(CameraTheme.accent)
                        .frame(width: 12, height: 12)
                        .offset(x: min(max(0, width * fraction - 6), width - 12))
                }
                .frame(height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let fraction = min(max(gesture.location.x / width, 0), 1)
                            onChange(range.lowerBound + (range.upperBound - range.lowerBound) * fraction)
                        }
                )
            }
            .frame(height: 20)
        }
    }
}

enum CaptureTimer: Int, CaseIterable, Identifiable {
    case off = 0
    case three = 3
    case ten = 10

    var id: Self { self }
    var seconds: Int { rawValue }
    var shortTitle: String { self == .off ? "OFF" : "\(rawValue)S" }
    var title: LocalizedStringResource {
        switch self {
        case .off: "Timer off"
        case .three: "3 seconds"
        case .ten: "10 seconds"
        }
    }
}

enum CameraTheme {
    static let ink = Color(white: 0.9)
    static let muted = Color(white: 0.58)
    static let panel = Color(red: 0.075, green: 0.078, blue: 0.072)
    static let background = Color(red: 0.043, green: 0.047, blue: 0.039)
    static let cameraWell = Color(red: 0.035, green: 0.038, blue: 0.034)
    static let line = Color(red: 0.28, green: 0.29, blue: 0.25)
    static let accent = Color(red: 0.94, green: 0.68, blue: 0.24)
    static let shutter = Color(red: 0.82, green: 0.83, blue: 0.77)
    static let record = Color(red: 0.92, green: 0.23, blue: 0.18)
    static let control: CGFloat = 36
    static let hit: CGFloat = 44
    static let paper = Color(red: 0.925, green: 0.914, blue: 0.875)
    static let paperInk = Color(red: 0.075, green: 0.08, blue: 0.07)
    static let paperMuted = Color(red: 0.39, green: 0.40, blue: 0.36)

    static func color(for token: ColorToken) -> Color {
        switch token {
        case .amber:
            accent
        case .red:
            Color(red: 0.92, green: 0.30, blue: 0.24)
        case .blue:
            Color(red: 0.40, green: 0.72, blue: 0.96)
        case .pink:
            Color(red: 0.96, green: 0.42, blue: 0.62)
        case .silver:
            Color(white: 0.84)
        case .teal:
            Color(red: 0.18, green: 0.72, blue: 0.70)
        }
    }
}

private struct CameraPermissionView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            Text("CAMERA ACCESS")
                .pocketFont(8, weight: .bold, design: .monospaced)
                .tracking(2)
                .foregroundStyle(CameraTheme.accent)
            Text("Pocket CCD needs the camera")
                .pocketFont(26, weight: .bold)
                .foregroundStyle(CameraTheme.ink)
            Text("Allow camera access in Settings to take CCD photos. Nothing leaves the phone.")
                .pocketFont(13)
                .foregroundStyle(CameraTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            PocketButton(title: "OPEN SETTINGS", filled: true) {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        // Duo / iPad: keep the recovery copy in a readable column.
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CameraTheme.background)
    }
}

private struct CameraUnavailableView: View {
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            Text("CAMERA")
                .pocketFont(8, weight: .bold, design: .monospaced)
                .tracking(2)
                .foregroundStyle(CameraTheme.accent)
            Text("Camera unavailable")
                .pocketFont(26, weight: .bold)
                .foregroundStyle(CameraTheme.ink)
            Text("Pocket CCD couldn’t start the camera. Close other camera apps and try again.")
                .pocketFont(13)
                .foregroundStyle(CameraTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            PocketButton(title: "TRY AGAIN", filled: true, action: retry)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        // Duo / iPad: keep the recovery copy in a readable column.
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CameraTheme.background)
    }
}

private struct PhotoResultView: View {
    let result: CaptureResult
    let initiallySaved: Bool
    let autoSaved: Bool
    let isAutoSaving: Bool
    let sensor: SensorIdentity
    @Bindable var pairedCapture: PairedCaptureService
    let onSave: (UIImage, CapturedFrame) async -> Bool
    let onSaveVideo: (URL) async -> Bool
    let onSaveLivePhoto: (UIImage, URL) async -> Bool
    let onUpdateNote: (String, UUID, Int) -> Void
    /// Reads the note already saved for a frame so editing resumes from it
    /// instead of from an empty field.
    let existingNote: (UUID) -> String
    /// Whether this shot kept its untouched camera file. Shown as a small chip,
    /// because the strongest moment to explain negatives is right after shooting.
    let keepsNegative: Bool
    let isTrial: Bool
    let rollSaveFailed: Bool
    @AppStorage("shareBorderEnabled") private var shareBorderEnabled = false
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var savedFrameIDs: Set<UUID>
    @State private var savedRescueIDs: Set<UUID> = []
    @State private var saveFailed = false
    @State private var showRollWriteWarning = false
    @State private var selectedIndex: Int
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var shareDateStamp = false
    @State private var storyFailure: InstagramStoriesSharer.Failure?
    @State private var canShareToStory = false
    @State private var rescuedImage: UIImage?
    @State private var note = ""
    @State private var showVideoPreview = false
    @State private var isEditingNote = false
    @State private var showShareActions = false
    /// The 2-second clip lives in the temporary directory and is deleted when
    /// this screen goes away; closing without saving is the one way a Moment is
    /// lost for good, so it asks first.
    @State private var clipSaved = false
    @State private var confirmUnsavedClip = false

    init(
        result: CaptureResult,
        initiallySaved: Bool,
        autoSaved: Bool,
        isAutoSaving: Bool,
        sensor: SensorIdentity,
        pairedCapture: PairedCaptureService,
        onSave: @escaping (UIImage, CapturedFrame) async -> Bool,
        onSaveVideo: @escaping (URL) async -> Bool,
        onSaveLivePhoto: @escaping (UIImage, URL) async -> Bool,
        onUpdateNote: @escaping (String, UUID, Int) -> Void,
        existingNote: @escaping (UUID) -> String,
        keepsNegative: Bool,
        isTrial: Bool,
        rollSaveFailed: Bool = false
    ) {
        self.result = result
        self.initiallySaved = initiallySaved
        self.autoSaved = autoSaved
        self.isAutoSaving = isAutoSaving
        self.sensor = sensor
        self.pairedCapture = pairedCapture
        self.onSave = onSave
        self.onSaveVideo = onSaveVideo
        self.onSaveLivePhoto = onSaveLivePhoto
        self.onUpdateNote = onUpdateNote
        self.existingNote = existingNote
        self.keepsNegative = keepsNegative
        self.isTrial = isTrial
        self.rollSaveFailed = rollSaveFailed
        _showRollWriteWarning = State(initialValue: rollSaveFailed)
        _savedFrameIDs = State(initialValue: initiallySaved ? [result.suggestedFrame.id] : [])
        _selectedIndex = State(initialValue: result.suggestedIndex)
    }

    var body: some View {
        ZStack {
            CameraTheme.background.ignoresSafeArea()
                .task {
                    canShareToStory = InstagramStoriesSharer.isAvailable
                }
            VStack(spacing: 0) {
                resultHeader
                ZStack(alignment: .bottomLeading) {
                    ZStack {
                        CameraTheme.cameraWell
                        if isTrial {
                            // A trial result is shown inside a secure host: the
                            // system screenshot of this area comes out black.
                            SecurePreview {
                                Image(uiImage: previewImage)
                                    .resizable()
                                    .scaledToFit()
                            }
                            .padding(6)
                        } else {
                            ZoomableImage(image: previewImage)
                                .padding(6)
                        }
                    }
                    .overlay { Rectangle().stroke(CameraTheme.line.opacity(0.65), lineWidth: 1) }
                    .aspectRatio(previewAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if result.frames.count > 1 {
                    ResultFilmstrip(
                        frames: result.frames,
                        selectedIndex: $selectedIndex,
                        suggestedIndex: result.suggestedIndex
                    )
                    .frame(height: 74)
                    .background(CameraTheme.background)
                }

                resultDock
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if !shareItems.isEmpty {
                ActivityShareSheet(items: shareItems) { completed in
                    if completed { ProductMetrics.record(.resultShared) }
                    showShareSheet = false
                }
                .presentationDetents([.medium, .large])
            }
        }
        .fullScreenCover(isPresented: $showVideoPreview) {
            if let videoURL = result.momentVideoURL {
                MomentVideoPreview(
                    url: videoURL,
                    stillImage: previewImage,
                    onSaveVideo: saveMomentVideo,
                    onSaveLivePhoto: saveMomentLivePhoto
                )
            }
        }
        .overlay {
            PocketAlert(
                title: "ROLL SAVE INCOMPLETE",
                message: String(localized: "Not all photos were safely saved to the roll. Save the photos you want to keep to Photos before closing."),
                isPresented: $showRollWriteWarning
            )
        }
        .overlay {
            PocketAlert(
                title: "COULDN’T SAVE",
                message: String(localized: "Check Photos access in Settings and try again."),
                isPresented: $saveFailed
            )
        }
        .overlay {
            PocketSheet("UNSAVED CLIP", isPresented: $confirmUnsavedClip) {
                PocketActionRow(title: "Save clip to Photos", symbol: "square.and.arrow.down") {
                    confirmUnsavedClip = false
                    guard let url = result.momentVideoURL else {
                        dismiss()
                        return
                    }
                    Task {
                        if await saveMomentVideo(url) {
                            dismiss()
                        } else {
                            saveFailed = true
                        }
                    }
                }
                PocketSheetDivider()
                PocketActionRow(title: "Close without saving", symbol: "trash", destructive: true) {
                    confirmUnsavedClip = false
                    dismiss()
                }
            }
        }
        .overlay {
            PocketAlert(
                title: storyFailure?.title ?? "INSTAGRAM UNAVAILABLE",
                message: storyFailure?.message ?? "",
                isPresented: Binding(
                    get: { storyFailure != nil },
                    set: { presented in
                        if !presented { storyFailure = nil }
                    }
                )
            )
        }
        .overlay {
            if isEditingNote {
                ZStack {
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                        .onTapGesture { isEditingNote = false }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("NOTE")
                            .pocketFont(8.5, weight: .bold, design: .monospaced)
                            .tracking(2)
                            .foregroundStyle(CameraTheme.muted)
                        TextField(
                            "",
                            text: $note,
                            prompt: Text("Add one line about this moment")
                                .foregroundColor(CameraTheme.muted)
                        )
                        .textFieldStyle(.plain)
                        .pocketFont(13)
                        .foregroundStyle(CameraTheme.ink)
                        .tint(CameraTheme.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 44)
                        .background(CameraTheme.cameraWell)
                        .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                        HStack(spacing: 8) {
                            PocketButton(title: "CANCEL", filled: false) {
                                note = existingNote(selectedFrame.id)
                                isEditingNote = false
                            }
                            PocketButton(title: "SAVE NOTE", filled: true) {
                                onUpdateNote(note, selectedFrame.id, selectedIndex)
                                isEditingNote = false
                            }
                        }
                    }
                    .padding(16)
                    .background(CameraTheme.panel)
                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                    .padding(.horizontal, 28)
                }
            }
        }
        .overlay {
            PocketSheet("SHARE", isPresented: $showShareActions) {
                HStack {
                    Text("Date stamp on share")
                        .pocketFont(12)
                        .foregroundStyle(CameraTheme.ink)
                    Spacer(minLength: 8)
                    Toggle("", isOn: $shareDateStamp)
                        .labelsHidden()
                        .tint(CameraTheme.accent)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                PocketSheetDivider()
                PocketActionRow(title: "Share 4:5 crop", symbol: "rectangle.portrait") {
                    showShareActions = false
                    presentShare(croppedFourByFive(previewImage))
                }
                PocketSheetDivider()
                PocketActionRow(title: "Share photo", symbol: "square.and.arrow.up") {
                    showShareActions = false
                    presentShare(previewImage)
                }
                PocketSheetDivider()
                PocketActionRow(title: "Share camera receipt", symbol: "doc.text.image") {
                    showShareActions = false
                    presentShare(CameraReceiptRenderer.render(
                        image: selectedFrame.image,
                        camera: result.camera,
                        mode: result.mode,
                        identity: sensor,
                        date: result.createdAt
                    ))
                }
                if result.frames.count > 1 {
                    PocketSheetDivider()
                    PocketActionRow(title: "Share sequence sheet", symbol: "rectangle.grid.3x2") {
                        showShareActions = false
                        if let sheet = ContactSheetRenderer.render(
                            images: result.frames.map(\.image),
                            entries: [],
                            format: .story
                        ) {
                            presentShare(sheet)
                        }
                    }
                }
                if let remote = pairedCapture.receivedImage {
                    PocketSheetDivider()
                    PocketActionRow(title: "Share paired diptych", symbol: "rectangle.split.2x1") {
                        showShareActions = false
                        presentShare(PairedMemoryRenderer.render(
                            local: selectedFrame.image,
                            remote: remote,
                            date: result.createdAt
                        ))
                    }
                }
                if let videoURL = result.momentVideoURL {
                    PocketSheetDivider()
                    PocketActionRow(title: "Preview 2-second video", symbol: "play.rectangle") {
                        showShareActions = false
                        showVideoPreview = true
                    }
                    PocketSheetDivider()
                    PocketActionRow(title: "Share 2-second video", symbol: "video") {
                        showShareActions = false
                        presentShare(videoURL)
                    }
                }
            }
        }
        .onChange(of: selectedIndex) { _, _ in rescuedImage = nil }
        .onChange(of: rollSaveFailed) { _, failed in
            if failed { showRollWriteWarning = true }
        }
        .onChange(of: autoSaved) { _, saved in
            if saved { savedFrameIDs.insert(result.suggestedFrame.id) }
        }
        .onDisappear {
            if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onUpdateNote(note, selectedFrame.id, selectedIndex)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var resultHeader: some View {
        HStack(spacing: 10) {
            Text("PREVIEW · \(result.createdAt.formatted(.dateTime.hour().minute()))")
                .pocketFont(8.5, weight: .bold, design: .monospaced)
                .tracking(1.2)
                .foregroundStyle(CameraTheme.muted)

            Spacer(minLength: 0)

            Button {
                attemptClose()
            } label: {
                Image(systemName: "xmark")
                    .pocketFont(12, weight: .semibold)
                    .foregroundStyle(CameraTheme.ink)
                    .frame(width: CameraTheme.control, height: CameraTheme.control)
                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                    .frame(width: CameraTheme.hit, height: CameraTheme.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close preview")
        }
        .foregroundStyle(CameraTheme.ink)
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(CameraTheme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(CameraTheme.line).frame(height: 0.5) }
    }

    private var resultDock: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(CameraTheme.color(for: result.camera.accent))
                    .frame(width: 5, height: 5)
                Text(verbatim: "\(result.camera.shortName) · \(result.mode.shortTitle)")
                    .pocketFont(8, weight: .bold, design: .monospaced)
                    .tracking(1)
                if keepsNegative {
                    Text("NEGATIVE")
                        .pocketFont(7.5, weight: .bold, design: .monospaced)
                        .tracking(0.8)
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .overlay {
                            Rectangle().stroke(CameraTheme.line, lineWidth: 1)
                        }
                        .accessibilityLabel("Negative kept on this iPhone")
                }
                Spacer(minLength: 8)

                if selectedFrame.rescue.needsRescue {
                    Button {
                        rescuedImage = rescuedImage == nil
                            ? CCDRescueRenderer.render(selectedFrame.image, diagnosis: selectedFrame.rescue)
                            : nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "wand.and.stars")
                                .pocketFont(10, weight: .semibold)
                            Text(LocalizedStringKey(rescuedImage == nil ? "SOFTER" : "ORIGINAL"))
                                .pocketFont(8, weight: .bold, design: .monospaced)
                                .tracking(1.2)
                        }
                        .foregroundStyle(CameraTheme.accent)
                        .frame(height: 24)
                        .padding(.horizontal, 6)
                        .overlay { Rectangle().stroke(CameraTheme.accent.opacity(0.5), lineWidth: 1) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Text(result.createdAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                    .pocketFont(8, weight: .bold, design: .monospaced)
                    .tracking(1)
                    .foregroundStyle(CameraTheme.muted)
            }
            .foregroundStyle(CameraTheme.muted)
            .padding(.horizontal, 16)
            .frame(height: 42)

            Rectangle().fill(CameraTheme.line.opacity(0.6)).frame(height: 0.5)

            HStack(spacing: 8) {
                Button {
                    dismiss()
                } label: {
                    Text("RETRY")
                        .pocketFont(9, weight: .bold, design: .monospaced)
                        .tracking(1.6)
                        .foregroundStyle(CameraTheme.ink)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        // Without an opaque background the hit area was the
                        // glyphs, not the 48 pt frame: taps inside the border
                        // but around the two words did nothing.
                        .contentShape(Rectangle())
                        .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                }
                .buttonStyle(.plain)

                Button {
                    save()
                } label: {
                    Group {
                        if isSaving || isAutoSaving {
                            ProgressView().tint(Color.black)
                        } else if isTrial {
                            Text("TRIAL — NOT SAVED")
                                .pocketFont(9, weight: .bold, design: .monospaced)
                                .tracking(1.6)
                        } else if isSaved {
                            Text("SAVED TO PHOTOS")
                                .pocketFont(9, weight: .bold, design: .monospaced)
                                .tracking(1.6)
                        } else {
                            Text("SAVE TO PHOTOS")
                                .pocketFont(9, weight: .bold, design: .monospaced)
                                .tracking(1.6)
                        }
                    }
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(CameraTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(isSaving || isAutoSaving || isSaved || isTrial)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            HStack(spacing: 0) {
                resultFooterAction("square.and.arrow.up", "SHARE") {
                    showShareActions = true
                }
                Rectangle().fill(CameraTheme.line.opacity(0.55)).frame(width: 1, height: 34)
                resultFooterAction("text.bubble", "ADD NOTE") {
                    note = existingNote(selectedFrame.id)
                    withAnimation(.easeOut(duration: 0.16)) { isEditingNote = true }
                }
                // Instagram's handoff needs its URL scheme installed; hiding the
                // action otherwise avoids offering a button that can only fail.
                if canShareToStory && !isTrial {
                    Rectangle().fill(CameraTheme.line.opacity(0.55)).frame(width: 1, height: 34)
                    resultFooterAction("camera.on.rectangle", "IG STORY") {
                        shareToStory()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 14)
        }
        .background(CameraTheme.panel)
        .overlay(alignment: .top) { Rectangle().fill(CameraTheme.line).frame(height: 0.5) }
    }

    /// Three text links with no icon read as one sentence; a symbol above each
    /// label makes them look like the separate actions they are.
    private func resultFooterAction(
        _ symbol: String,
        _ title: LocalizedStringResource,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .pocketFont(8, weight: .bold, design: .monospaced)
                    .tracking(1.3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(CameraTheme.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var selectedFrame: CapturedFrame {
        let frames = result.frames
        // `CaptureResult` guarantees at least one frame; make that explicit so
        // a future empty result fails here instead of indexing -1.
        guard !frames.isEmpty else {
            preconditionFailure("CaptureResult must contain at least one frame")
        }
        return frames[min(max(selectedIndex, 0), frames.count - 1)]
    }

    private var isSaved: Bool {
        rescuedImage != nil
            ? savedRescueIDs.contains(selectedFrame.id)
            : savedFrameIDs.contains(selectedFrame.id)
    }

    private func presentShare(_ item: Any) {
        // A trial frame has no shareable copy: sharing would hand over exactly
        // what the trial is not meant to give.
        guard !isTrial else { return }
        var item = item
        if var image = item as? UIImage {
            if shareDateStamp {
                image = stampedForSharing(image, camera: result.camera, date: result.createdAt)
            }
            if shareBorderEnabled {
                image = ShareBorderRenderer.render(image, camera: result.camera, date: result.createdAt)
            }
            item = ImagingColorPipeline.exportImage(image) ?? image
        }
        shareItems = [item]
        showShareSheet = true
    }

    /// 4:5 is what a feed actually shows; the saved frame keeps its 4:3.
    private func croppedFourByFive(_ image: UIImage) -> UIImage {
        let target: CGFloat = 4.0 / 5.0
        var crop = CGRect(origin: .zero, size: image.size)
        if image.size.width / max(image.size.height, 1) > target {
            let width = image.size.height * target
            crop.origin.x = (image.size.width - width) / 2
            crop.size.width = width
        } else {
            let height = image.size.width / target
            crop.origin.y = (image.size.height - height) / 2
            crop.size.height = height
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(image.scale, 1)
        format.opaque = false
        return UIGraphicsImageRenderer(size: crop.size, format: format).image { _ in
            image.draw(at: CGPoint(x: -crop.minX, y: -crop.minY))
        }
    }

    /// Closing is the only irreversible exit for a Moment: the clip is a
    /// temporary file that the camera screen deletes on dismiss.
    private func attemptClose() {
        if result.momentVideoURL != nil, !clipSaved {
            confirmUnsavedClip = true
        } else {
            dismiss()
        }
    }

    private func saveMomentVideo(_ url: URL) async -> Bool {
        guard !isTrial else { return false }
        let saved = await onSaveVideo(url)
        if saved { clipSaved = true }
        return saved
    }

    private func saveMomentLivePhoto(_ image: UIImage, _ url: URL) async -> Bool {
        guard !isTrial else { return false }
        let saved = await onSaveLivePhoto(image, url)
        if saved { clipSaved = true }
        return saved
    }

    /// Ships in 1.0.1: the Meta app id is configured, so the action appears
    /// whenever Instagram itself is installed (see `canShareToStory`).
    private func shareToStory() {
        guard !isTrial else { return }
        Task {
            storyFailure = await InstagramStoriesSharer.share(previewImage)
        }
    }

    private func save() {
        // A trial frame is for looking, never for keeping.
        guard !isTrial else { return }
        let frame = selectedFrame
        let image = previewImage
        let isRescue = rescuedImage != nil
        isSaving = true
        Task {
            let success = await onSave(image, frame)
            isSaving = false
            guard success else {
                saveFailed = true
                return
            }
            if isRescue {
                savedRescueIDs.insert(frame.id)
            } else {
                savedFrameIDs.insert(frame.id)
            }
            saveFailed = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Saved is done: close the preview the same way RETRY does.
            dismiss()
        }
    }

    private var previewAspect: CGFloat {
        let size = previewImage.size
        guard size.width > 0, size.height > 0 else { return 3.0 / 4.0 }
        return size.width / size.height
    }

    private var previewImage: UIImage { rescuedImage ?? selectedFrame.image }

}

enum MomentVideoRenderer {
    /// AVFoundation internally synchronizes export sessions but does not yet
    /// expose Sendable conformance. The completion callback is the sole owner.
    private final class ExportBridge: @unchecked Sendable {
        let exporter: AVAssetExportSession
        init(_ exporter: AVAssetExportSession) { self.exporter = exporter }
    }

    static func processedFrame(_ source: CIImage, look: CCDLook, sensor: SensorIdentity,
                               balanceGain: Double? = nil,
                               conditions: CaptureImagingConditions, isFront: Bool) -> CIImage {
        // Keep a finite canvas for size-dependent glow/grain. Individual blur
        // stages clamp their own edges; clamping the whole source here would
        // give the look an infinite extent and invalid effect radii.
        let image = isFront ? mirrored(source) : source
        return look.videoFrame(image, sensor: sensor, balanceGain: balanceGain,
                               conditions: conditions).cropped(to: image.extent)
    }

    /// The still path mirrors front-camera frames; the movie used to skip it,
    /// so a selfie Moment played back unmirrored next to a mirrored still.
    private static func mirrored(_ source: CIImage) -> CIImage {
        let extent = source.extent
        let translation = 2 * extent.minX + extent.width
        return source
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: translation, y: 0))
    }

    static func render(sourceURL: URL, look: CCDLook, sensor: SensorIdentity,
                       balanceGain: Double? = nil,
                       aspectRatio: CaptureAspectRatio = .fourThree,
                       focalCrop: CGFloat = 1,
                       conditions: CaptureImagingConditions = .init(),
                       isFront: Bool = false) async throws -> URL {
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        // Crop first, then grade: the look's pixel-scale bloom/grain should be
        // computed against the final frame, and the 16:9 / 1:1 / 50 mm framing
        // must match the stills from the same Moment.
        let workingURL = try await croppedVideoIfNeeded(
            sourceURL: sourceURL,
            aspectRatio: aspectRatio,
            focalCrop: focalCrop
        ) ?? sourceURL
        defer {
            if workingURL != sourceURL {
                try? FileManager.default.removeItem(at: workingURL)
            }
        }
        let asset = AVURLAsset(url: workingURL)
        let composition = AVVideoComposition(asset: asset) { request in
            request.finish(with: processedFrame(request.sourceImage, look: look, sensor: sensor,
                                                balanceGain: balanceGain,
                                                conditions: conditions, isFront: isFront), context: nil)
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketMoment-CCD-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: outputURL) }
        }
        try await export(asset: asset, composition: composition, to: outputURL)
        completed = true
        return outputURL
    }

    /// Crops the recording to the selected aspect / focal length. Returns nil
    /// when the source is already the target framing, so the common 4:3 path
    /// still pays for a single export.
    static func croppedVideoIfNeeded(
        sourceURL: URL,
        aspectRatio: CaptureAspectRatio,
        focalCrop: CGFloat
    ) async throws -> URL? {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let transformed = CGRect(origin: .zero, size: natural).applying(preferred).standardized
        let displaySize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard displaySize.width > 1, displaySize.height > 1 else { return nil }
        let displayRect = CGRect(origin: .zero, size: displaySize)
        let crop = aspectRatio.cropRect(in: displayRect, focalCrop: focalCrop)
        guard crop.width < displaySize.width - 1 || crop.height < displaySize.height - 1 else { return nil }

        // H.264 wants even dimensions.
        let renderSize = CGSize(
            width: max(2, (crop.width / 2).rounded(.down) * 2),
            height: max(2, (crop.height / 2).rounded(.down) * 2)
        )
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        let nominalRate = try await track.load(.nominalFrameRate)
        let fps = nominalRate > 0 ? Int(nominalRate.rounded()) : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        // Normalize the preferred transform so the displayed frame starts at
        // (0, 0), then move the crop rectangle to the composition origin.
        var transform = preferred
        if transformed.minX != 0 || transformed.minY != 0 {
            transform = transform.concatenating(
                CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY)
            )
        }
        transform = transform.concatenating(
            CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        )
        layer.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketMoment-Crop-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        do {
            try await export(asset: asset, composition: composition, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return outputURL
    }

    private static func export(asset: AVAsset, composition: AVVideoComposition, to outputURL: URL) async throws {
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw CameraIssue.captureFailed
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = composition
        let bridge = ExportBridge(exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.exportAsynchronously {
                switch bridge.exporter.status {
                case .completed: continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: bridge.exporter.error ?? CameraIssue.captureFailed)
                default:
                    continuation.resume(throwing: CameraIssue.captureFailed)
                }
            }
        }
    }
}

private struct MomentVideoPreview: View {
    let url: URL
    let stillImage: UIImage
    let onSaveVideo: (URL) async -> Bool
    let onSaveLivePhoto: (UIImage, URL) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    @State private var isSaving = false
    @State private var saveMessage: String?

    init(
        url: URL,
        stillImage: UIImage,
        onSaveVideo: @escaping (URL) async -> Bool,
        onSaveLivePhoto: @escaping (UIImage, URL) async -> Bool
    ) {
        self.url = url
        self.stillImage = stillImage
        self.onSaveVideo = onSaveVideo
        self.onSaveLivePhoto = onSaveLivePhoto
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            PocketDismissBar(label: "CLOSE")
            VideoPlayer(player: player)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        PocketButton(title: "SAVE VIDEO", filled: true) {
                            save(asLivePhoto: false)
                        }
                        PocketButton(title: "SAVE AS LIVE PHOTO", filled: false) {
                            save(asLivePhoto: true)
                        }
                        .disabled(isSaving)
                    }
                    .padding(12)
                    .background(CameraTheme.background)
                    .overlay(alignment: .top) { Rectangle().fill(CameraTheme.line).frame(height: 1) }
                }
                .overlay {
                    if isSaving {
                        ProgressView().tint(CameraTheme.accent)
                    }
                }
                .onAppear { player.play() }
                .onDisappear { player.pause() }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay {
            PocketAlert(
                title: "POCKET MOMENT",
                message: saveMessage ?? "",
                isPresented: Binding(
                    get: { saveMessage != nil },
                    set: { if !$0 { saveMessage = nil } }
                )
            )
        }
    }

    private func save(asLivePhoto: Bool) {
        isSaving = true
        Task {
            let success = asLivePhoto
                ? await onSaveLivePhoto(stillImage, url)
                : await onSaveVideo(url)
            isSaving = false
            if success {
                saveMessage = asLivePhoto
                    ? String(localized: "Live Photo saved.")
                    : String(localized: "Video saved.")
            } else {
                saveMessage = String(localized: "Couldn’t save. Check Photos access and try again.")
            }
            if success { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }
}

private struct ResultFilmstrip: View {
    let frames: [CapturedFrame]
    @Binding var selectedIndex: Int
    let suggestedIndex: Int

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                    Button {
                        selectedIndex = index
                    } label: {
                        Image(uiImage: frame.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 76, height: 58)
                            .clipShape(.rect(cornerRadius: 3))
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(index == selectedIndex ? CameraTheme.accent : .clear, lineWidth: 2)
                            }
                            .overlay(alignment: .topTrailing) {
                                if index == suggestedIndex {
                                    Image(systemName: "sparkles")
                                        .font(.caption2)
                                        .padding(4)
                                        .background(CameraTheme.accent, in: Circle())
                                        .foregroundStyle(.black)
                                        .offset(x: 5, y: -5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(CameraTheme.paper)
    }
}

private struct ResultMetadata: View {
    let cameraName: String
    let modeName: LocalizedStringResource
    let frameRole: LocalizedStringResource
    let isSuggested: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(cameraName)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(CameraTheme.paperInk)
                HStack(spacing: 4) {
                    Text(modeName)
                    Text("•")
                    Text(frameRole)
                }
                .font(.caption2)
                .foregroundStyle(CameraTheme.paperMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if isSuggested {
                    Label("Pocket Pick", systemImage: "sparkles")
                        .foregroundStyle(CameraTheme.paperInk)
                }
            }
            .font(.caption2.monospacedDigit())
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .foregroundStyle(CameraTheme.paperInk)
        .background(CameraTheme.paper)
    }
}


// MARK: - Pocket interface kit

/// Content screens honour Dynamic Type; the camera chrome stays on its fixed
/// instrument grid so the shutter and lens controls never reflow.
struct PocketScaledFont: ViewModifier {
    let size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    var maxScale: CGFloat = 1.5
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(.system(size: size * min(scale, maxScale), weight: weight, design: design))
    }

    private var scale: CGFloat {
        switch dynamicTypeSize {
        case .xSmall: 0.9
        case .small: 0.95
        case .medium: 0.98
        case .large: 1.0
        case .xLarge: 1.06
        case .xxLarge: 1.12
        case .xxxLarge: 1.2
        case .accessibility1: 1.28
        case .accessibility2: 1.36
        case .accessibility3: 1.44
        case .accessibility4, .accessibility5: 1.5
        @unknown default: 1.12
        }
    }
}

extension View {
    func pocketFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(PocketScaledFont(size: size, weight: weight, design: design))
    }

    /// The camera HUD scales, but only up to 15%: the shutter, lens pill and
    /// top tool row use a fixed instrument grid and must not reflow.
    func pocketHUDFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(PocketScaledFont(size: size, weight: weight, design: design, maxScale: 1.15))
    }
}

enum PocketMetrics {
    static let edge: CGFloat = 14
    static let row: CGFloat = 50
}

struct PocketSectionLabel: View {
    let text: LocalizedStringResource
    init(_ text: LocalizedStringResource) { self.text = text }
    var body: some View {
        Text(text)
            .pocketFont(8, weight: .bold, design: .monospaced)
            .tracking(2)
            .foregroundStyle(CameraTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PocketPanel<Content: View>: View {
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) { content }
            .background(CameraTheme.cameraWell)
            .overlay { Rectangle().stroke(CameraTheme.line.opacity(0.7), lineWidth: 1) }
    }
}

struct PocketButton: View {
    let title: String
    var symbol: String?
    var filled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol {
                    Image(systemName: symbol).pocketFont(12, weight: .semibold)
                }
                Text(LocalizedStringKey(title))
                    .pocketFont(9, weight: .bold, design: .monospaced)
                    .tracking(1.6)
            }
            .foregroundStyle(filled ? Color.black : CameraTheme.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(filled ? CameraTheme.accent : Color.clear)
            .overlay {
                if !filled { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PocketFootnote: View {
    let text: LocalizedStringResource
    init(_ text: LocalizedStringResource) { self.text = text }
    var body: some View {
        Text(text)
            .pocketFont(11)
            .foregroundStyle(CameraTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PocketPageTitle: View {
    let title: LocalizedStringResource
    var subtitle: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .pocketFont(22, weight: .bold)
                .foregroundStyle(CameraTheme.ink)
            if let subtitle {
                Text(subtitle)
                    .pocketFont(12)
                    .foregroundStyle(CameraTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PocketGroup<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content
    init(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PocketSectionLabel(title)
            PocketPanel { content }
        }
    }
}

struct PocketLabeledRow: View {
    let title: LocalizedStringResource
    var detail: LocalizedStringResource?
    var value: String?
    var symbol: String?
    var showsChevron = false

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .pocketFont(12, weight: .semibold)
                    .foregroundStyle(CameraTheme.accent)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .pocketFont(12.5)
                    .foregroundStyle(CameraTheme.ink)
                if let detail {
                    Text(detail)
                        .pocketFont(10.5)
                        .foregroundStyle(CameraTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let value {
                Text(LocalizedStringKey(value))
                    .pocketFont(9, weight: .bold, design: .monospaced)
                    .tracking(1)
                    .foregroundStyle(CameraTheme.muted)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .pocketFont(9, weight: .bold)
                    .foregroundStyle(CameraTheme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(minHeight: 50, alignment: .leading)
    }
}


struct PocketBackBar: View {
    var label: LocalizedStringResource = "BACK"
    var onClose: (() -> Void)?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: onClose == nil ? "chevron.left" : "xmark")
                        .pocketFont(11, weight: .bold)
                    Text(label)
                        .pocketFont(8.5, weight: .bold, design: .monospaced)
                        .tracking(1.4)
                }
                .foregroundStyle(CameraTheme.ink)
                .padding(.horizontal, 4)
                .frame(height: CameraTheme.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .pocketFont(12, weight: .semibold)
                        .foregroundStyle(CameraTheme.muted)
                        .frame(width: CameraTheme.hit, height: CameraTheme.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .background(CameraTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(CameraTheme.line).frame(height: 1) }
    }
}


struct PocketDismissBar: View {
    var label: LocalizedStringResource = "BACK"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 6) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: label == "CLOSE" || label == "DONE" ? "xmark" : "chevron.left")
                        .pocketFont(11, weight: .bold)
                    Text(label)
                        .pocketFont(8.5, weight: .bold, design: .monospaced)
                        .tracking(1.4)
                }
                .foregroundStyle(CameraTheme.ink)
                .padding(.horizontal, 4)
                .frame(height: CameraTheme.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .background(CameraTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(CameraTheme.line).frame(height: 1) }
    }
}


struct PocketToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Rectangle()
                    .fill(isOn ? CameraTheme.accent : CameraTheme.line)
                    .frame(width: 42, height: 24)
                Rectangle()
                    .fill(isOn ? Color.black : CameraTheme.muted)
                    .frame(width: 18, height: 18)
                    .padding(3)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityValue(isOn ? String(localized: "On") : String(localized: "Off"))
    }
}

struct PocketActionRow: View {
    let title: LocalizedStringResource
    var symbol: String?
    var destructive = false
    var showsChevron = false
    /// Replaces the chevron while the row's work is running, so a slow export
    /// never looks like a dead tap.
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .pocketFont(12, weight: .semibold)
                        .foregroundStyle(destructive ? Color.red : CameraTheme.accent)
                        .frame(width: 18)
                }
                Text(title)
                    .pocketFont(12.5)
                    .foregroundStyle(destructive ? Color.red : CameraTheme.ink)
                Spacer(minLength: 8)
                if isBusy {
                    ProgressView().controlSize(.mini).tint(CameraTheme.muted)
                } else if showsChevron {
                    Image(systemName: "chevron.right")
                        .pocketFont(9, weight: .bold)
                        .foregroundStyle(CameraTheme.muted)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PocketSheetDivider: View {
    var body: some View {
        Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1).padding(.leading, 16)
    }
}

/// Four export presets, each named after where it gets posted. The ratio is the
/// second line, so nobody has to know what "9:16" means to make the right pick.
struct ExportPresetRows: View {
    var isExporting = false
    let action: (ExportPreset) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(ExportPreset.allCases) { preset in
                Button {
                    action(preset)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: preset.sheetSymbol)
                            .pocketFont(12, weight: .semibold)
                            .foregroundStyle(CameraTheme.accent)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.title)
                                .pocketFont(12.5)
                                .foregroundStyle(CameraTheme.ink)
                            Text(preset.hint)
                                .pocketFont(8.5, weight: .semibold, design: .monospaced)
                                .tracking(0.9)
                                .foregroundStyle(CameraTheme.muted)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isExporting)
                if preset != ExportPreset.allCases.last {
                    PocketSheetDivider()
                }
            }
        }
    }
}

struct PocketSheet<Content: View>: View {
    let title: LocalizedStringResource
    @Binding var isPresented: Bool
    @ViewBuilder let content: Content
    @State private var dragOffset: CGFloat = 0

    init(_ title: LocalizedStringResource, isPresented: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isPresented = isPresented
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                Color.black.opacity(0.62)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 0) {
                    Capsule()
                        .fill(CameraTheme.line)
                        .frame(width: 36, height: 4)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    HStack(spacing: 8) {
                        Text(title)
                            .pocketFont(8.5, weight: .bold, design: .monospaced)
                            .tracking(2)
                            .foregroundStyle(CameraTheme.muted)
                        Spacer(minLength: 0)
                        Button { close() } label: {
                            Image(systemName: "xmark")
                                .pocketFont(12, weight: .semibold)
                                .foregroundStyle(CameraTheme.muted)
                                .frame(width: CameraTheme.hit, height: CameraTheme.hit)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    content
                }
                .padding(.bottom, 24)
                .background(CameraTheme.panel)
                .overlay(alignment: .top) { Rectangle().fill(CameraTheme.line).frame(height: 1) }
                .offset(y: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            dragOffset = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            if value.translation.height > 80 { close() }
                            withAnimation(.easeOut(duration: 0.18)) { dragOffset = 0 }
                        }
                )
                .transition(.move(edge: .bottom))
                .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isPresented)
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) { isPresented = false }
    }
}


struct PocketAlert: View {
    let title: LocalizedStringResource
    let message: String
    @Binding var isPresented: Bool
    var confirmTitle: LocalizedStringResource = "OK"

    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .pocketFont(8.5, weight: .bold, design: .monospaced)
                        .tracking(2)
                        .foregroundStyle(CameraTheme.muted)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    Text(verbatim: message)
                        .pocketFont(12.5)
                        .foregroundStyle(CameraTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                    PocketSheetDivider()
                    PocketActionRow(title: confirmTitle) { isPresented = false }
                }
                .background(CameraTheme.panel)
                .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                .padding(.horizontal, 28)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isPresented)
    }
}


struct NavigationSwipeBackEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        DispatchQueue.main.async { install(on: controller, coordinator: context.coordinator) }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        install(on: uiViewController, coordinator: context.coordinator)
    }

    private func install(on controller: UIViewController, coordinator: Coordinator) {
        guard let nav = controller.navigationController else { return }
        coordinator.navigationController = nav
        nav.interactivePopGestureRecognizer?.isEnabled = true
        nav.interactivePopGestureRecognizer?.delegate = coordinator
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

extension View {
    func pocketSwipeBack() -> some View {
        background(NavigationSwipeBackEnabler().frame(width: 0, height: 0))
    }
}

/// Hosts a SwiftUI view inside a secure text field: the system screenshot and
/// screen recording of that area come out black. This is the only way to do it
/// on iOS (the same technique streaming apps use); the private subview lookup is
/// guarded, and if Apple changes the hierarchy the view still renders, just
/// without protection.
private struct SecurePreview<Content: View>: UIViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeUIView(context: Context) -> SecureHost {
        let host = SecureHost()
        host.install(AnyView(content()))
        return host
    }

    func updateUIView(_ uiView: SecureHost, context: Context) {}
}

final class SecureHost: UIView {
    private let field = UITextField()
    private var controller: UIHostingController<AnyView>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        field.backgroundColor = .clear
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func install(_ view: AnyView) {
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        let parent = field.subviews.first ?? field
        parent.isUserInteractionEnabled = true
        parent.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: parent.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
        controller = host
    }
}

/// The optional share frame: a warm paper margin and one line that says which
/// body took the picture and when. Only used on the share sheet — the saved
/// photo and the negative stay frame-free.
private enum ShareBorderRenderer {
    static func render(_ image: UIImage, camera: CCDLook, date: Date) -> UIImage {
        let margin = image.size.width * 0.055
        let footer = image.size.height * 0.085
        let size = CGSize(width: image.size.width + margin * 2,
                          height: image.size.height + margin + footer)
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(image.scale, 1)
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(white: 0.965, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(x: margin, y: margin,
                                  width: image.size.width, height: image.size.height))
            let label = "POCKETCCD  ·  \(camera.shortName)  ·  \(PocketDateStamp.text(for: date))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: max(10, image.size.width * 0.017),
                                                   weight: .semibold),
                .foregroundColor: UIColor(white: 0.28, alpha: 1),
                .kern: 0.6
            ]
            let textSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: margin,
                                   y: image.size.height + margin + (footer - textSize.height) / 2),
                       withAttributes: attributes)
        }
    }
}
