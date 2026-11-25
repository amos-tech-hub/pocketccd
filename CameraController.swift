@preconcurrency import AVFoundation
import CoreImage
import CoreLocation
import Observation
import Photos
import UIKit
import ImageIO
import UniformTypeIdentifiers

enum CameraIssue: LocalizedError {
    case permissionDenied
    case configurationFailed
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Camera access is required to take photos."
        case .configurationFailed: "The camera could not be configured."
        case .captureFailed: "The photo could not be captured."
        }
    }
}

/// Photo processing and capture completion are separate delegate events.
/// Configuration may be restored only after the whole capture finishes.
struct PhotoCaptureCompletion<Photo> {
    var processed: Result<Photo, Error>?
    var finished = false
    var terminalError: Error?

    var result: Result<Photo, Error>? {
        guard finished else { return nil }
        if let terminalError { return .failure(terminalError) }
        return processed
    }
}

/// One capture in both forms the app needs: the decoded image for the look
/// pipeline, and the camera's own encoded data for the negative archive.
///
/// The decode happens once, here. Before this, the flow was camera JPEG →
/// `UIImage(data:)` → look → JPEG 0.95, so every finished photo was encoded
/// twice and every shutter paid for a full-resolution decode it did not need.
struct CapturedPhoto {
    let image: UIImage
    let originalData: Data?
    let metadata: PhotoFrameMetadata
    var diagnostics: CaptureExposureDiagnostics? = nil
}

/// Archived alongside the original, never embedded in the user's photo UI.
struct CaptureExposureDiagnostics: Codable, Sendable, Equatable {
    static let policyRevision = "flash-clamp-45s-20261124-v6"
    let policyRevision: String
    let appVersion: String
    let appBuild: String
    let requestedFlash: String
    let prioritization: String
    let manualExposure: Bool
    let flashLimitApplied: Bool
    let requestedMaximumSeconds: Double?
    let before: ExposureState?
    let after: ExposureState?
    var exposureStrategy: String? = nil
    var requestedISO: Float? = nil
    var actualExposure: OriginalFrameExposure? = nil
    var requestedShutterHonored: Bool? = nil

    struct ExposureState: Codable, Sendable, Equatable {
        let mode: Int
        let maximumSeconds: Double?
        let shutterSeconds: Double?
        let iso: Float
    }
}

struct PhotoFrameMetadata: Sendable, Codable, Equatable {
    let exif: Data?
    let tiff: Data?
    let gps: Data?

    var imagingConditions: CaptureImagingConditions {
        guard let exif,
              let values = (try? PropertyListSerialization.propertyList(from: exif, format: nil)) as? [String: Any]
        else { return .init() }
        let iso = (values[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        let manualWhiteBalance = (values[kCGImagePropertyExifWhiteBalance as String] as? NSNumber)?.intValue == 1
        return CaptureImagingConditions(iso: iso, allowsSceneWhiteBalance: !manualWhiteBalance)
    }


    init(_ properties: [String: Any]) {
        func encode(_ key: CFString) -> Data? {
            guard let dictionary = properties[key as String] as? [String: Any] else { return nil }
            return try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        }
        exif = encode(kCGImagePropertyExifDictionary)
        tiff = encode(kCGImagePropertyTIFFDictionary)
        gps = encode(kCGImagePropertyGPSDictionary)
    }
}

enum CameraLens: String, CaseIterable, Identifiable, Equatable {
    case ultraWide = "0.5×"
    case wide = "1×"
    case telephoto = "3×"

    var id: Self { self }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: .builtInUltraWideCamera
        case .wide: .builtInWideAngleCamera
        case .telephoto: .builtInTelephotoCamera
        }
    }

    /// 35 mm equivalent for the fictional body. It is product flavour rather
    /// than a spec sheet: the whole point of these cameras is that they are
    /// not the phone's lenses.
    var focalLengthLabel: String {
        switch self {
        case .ultraWide: "13MM"
        case .wide: "35MM"
        case .telephoto: "77MM"
        }
    }
}

@MainActor
@Observable
final class CameraController: NSObject {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "app.pocketccd.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    let previewPipeline = LivePreviewPipeline()
    private nonisolated static let captureContext = ImagingColorPipeline.makeContext()
    private var activeInput: AVCaptureDeviceInput?
    private var highlightExposure = HighlightExposureState()
    private var captureContinuation: CheckedContinuation<CapturedPhoto, Error>?
    private var captureCompletion = PhotoCaptureCompletion<CapturedPhoto>()
    private var captureRequestID: Int64?
    private var captureWatchdog: Task<Void, Never>?
    private var sequenceContinuation: CheckedContinuation<[(offset: Int, photo: CapturedPhoto)], Error>?
    private var sequenceIDs: [Int64] = []
    private var sequenceResults: [Int64: CapturedPhoto] = [:]
    private var sequencePending: Set<Int64> = []
    private var sequenceLastError: Error?
    private var movieContinuation: CheckedContinuation<URL, Error>?
    private var movieCaptureWatchdog: Task<Void, Never>?
    private var activeAudioInput: AVCaptureDeviceInput?
    private var sessionObservers: [NSObjectProtocol] = []

    var isConfigured = false
    var isCapturing = false
    var isAEAFlocked = false
    var cameraPosition: AVCaptureDevice.Position = .back
    var flashMode: AVCaptureDevice.FlashMode = .auto
    var isFlashAvailable = false
    var zoomFactor: CGFloat = 1
    var exposureBias: Float = 0
    var availableLenses: [CameraLens] = [.wide]
    var selectedLens: CameraLens = .wide
    var proModeEnabled = false
    var manualISO: Float = 100
    var shutterSeconds: Double = 1.0 / 60.0
    var whiteBalanceKelvin: Float = 5200
    var imagingConditions: CaptureImagingConditions {
        guard let device = activeInput?.device else { return .init() }
        return CaptureImagingConditions(iso: Double(device.iso),
                                       allowsSceneWhiteBalance: device.whiteBalanceMode != .locked)
    }
    var issue: CameraIssue?
    var interruptionMessage: LocalizedStringResource?

    func prepare() async {
        if isConfigured {
            issue = nil
            await start()
            return
        }

        #if targetEnvironment(simulator)
        // Simulator exposes capture-device stubs but has no camera hardware.
        // Avoid requesting a permission that cannot unlock a usable preview.
        issue = .configurationFailed
        return
        #else

        guard await requestCameraAccess() else {
            issue = .permissionDenied
            return
        }

        let configured = await withCheckedContinuation { continuation in
            sessionQueue.async { [session, photoOutput, videoOutput, movieOutput, previewPipeline] in
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                session.sessionPreset = .photo

                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                            for: .video,
                                                            position: .back),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input),
                      session.canAddOutput(photoOutput),
                      session.canAddOutput(videoOutput),
                      session.canAddOutput(movieOutput) else {
                    continuation.resume(returning: false)
                    return
                }

                session.addInput(input)
                session.addOutput(photoOutput)
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                if #available(iOS 26.0, *) {
                    // The look only ever runs at 1280 px. Handing over the full
                    // 12 MP frame costs ~48 MB per frame at 30 fps for data the
                    // pipeline immediately throws away; preview-sized buffers
                    // keep the photo output at full resolution while the video
                    // path stays small. Older systems keep the full-size path.
                    videoOutput.automaticallyConfiguresOutputBufferDimensions = false
                    videoOutput.deliversPreviewSizedOutputBuffers = true
                }
                videoOutput.setSampleBufferDelegate(
                    previewPipeline,
                    queue: DispatchQueue(label: "app.pocketccd.camera.preview", qos: .userInteractive)
                )
                session.addOutput(videoOutput)
                session.addOutput(movieOutput)
                // Keep the full computational-photography pipeline: the CCD
                // render is applied afterwards, but Smart HDR / Deep Fusion has
                // to happen at capture time or highlights are unrecoverable.
                photoOutput.maxPhotoQualityPrioritization = .quality
                if photoOutput.isResponsiveCaptureSupported {
                    photoOutput.isResponsiveCaptureEnabled = true
                }
                if photoOutput.isFastCapturePrioritizationSupported {
                    photoOutput.isFastCapturePrioritizationEnabled = false
                }
                // Zero-shutter-lag can return a pre-roll frame whose exposure
                // predates a fast scene change (e.g. pointing down at a bright
                // floor), which showed up as a blown-out capture. Prefer a
                // freshly exposed frame.
                if photoOutput.isZeroShutterLagSupported {
                    photoOutput.isZeroShutterLagEnabled = false
                }
                continuation.resume(returning: true)
            }
        }

        guard configured else {
            issue = .configurationFailed
            return
        }
        activeInput = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first
        previewPipeline.update(cameraPosition: .back)
        refreshCapabilities()
        issue = nil
        isConfigured = true
        observeSessionEventsIfNeeded()
        await start()
        #endif
    }

    func start() async {
        guard isConfigured else { return }
        let didStart = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
                continuation.resume(returning: session.isRunning)
            }
        }
        if didStart {
            issue = nil
        } else {
            issue = .configurationFailed
        }
    }

    func stop() {
        sessionQueue.async { [session] in session.stopRunning() }
    }

    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }

    /// Restarts the session if a navigation push or a background transition
    /// stopped it, and waits briefly for `isRunning` to become true. Entry
    /// points that fire a shutter right after dismissing a sheet use this so
    /// they do not race the view's own restart.
    func ensureRunning() async {
        guard isConfigured else {
            await prepare()
            return
        }
        if await isSessionRunning() { return }
        await start()
        for _ in 0..<10 {
            if await isSessionRunning() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Uses the processed uncompressed buffer when available, avoiding a
    /// JPEG/HEIC decode. This is ISP output, not sensor RAW.
    private nonisolated static func decodedCapture(
        from buffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> UIImage? {
        let source = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        guard let cgImage = ImagingColorPipeline.displayImage(source, using: captureContext) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private nonisolated static func captureOrientation(from metadata: [String: Any]) -> CGImagePropertyOrientation {
        let raw = (metadata[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value
            ?? CGImagePropertyOrientation.right.rawValue
        return CGImagePropertyOrientation(rawValue: raw) ?? .right
    }

    func capture(flashMode overrideFlashMode: AVCaptureDevice.FlashMode? = nil) async throws -> CapturedPhoto {
        guard !isCapturing else { throw CameraIssue.captureFailed }
        isCapturing = true
        defer { isCapturing = false }

        return try await captureOne(flashMode: overrideFlashMode)
    }

    /// Called while the public capture transaction owns `isCapturing`.
    private func captureOne(flashMode overrideFlashMode: AVCaptureDevice.FlashMode?) async throws -> CapturedPhoto {
        // A stopped or interrupted session can silently skip the delegate
        // callback; fail fast instead of locking the shutter forever.
        guard await isSessionRunning() else { throw CameraIssue.captureFailed }

        let settings = AVCapturePhotoSettings()
        if cameraPosition == .back, let device = activeInput?.device, device.hasFlash {
            settings.flashMode = overrideFlashMode ?? flashMode
        }
        let expectsFlash = settings.flashMode == .on
            || (settings.flashMode == .auto && photoOutput.isFlashScene)
        settings.photoQualityPrioritization = Self.qualityPrioritization(manualExposure: proModeEnabled,
                                                                         hardwareFlash: expectsFlash,
                                                                         fastCapture: true)

        var flashLimitApplied = false
        var requestedMaxSeconds: Double? = nil
        var flashLimitedDevice: AVCaptureDevice?
        let targetMaxShutter = CMTime(value: 1, timescale: 45)
        // `activeMaxExposureDuration` is sticky hardware state. Restore it on
        // every exit path: the old inline restore was skipped when
        // `requestPhoto` timed out, was cancelled, or threw, leaving the camera
        // permanently capped at 1/45 s and every later frame underexposed.
        defer {
            if let flashLimitedDevice {
                do {
                    try flashLimitedDevice.lockForConfiguration()
                    flashLimitedDevice.activeMaxExposureDuration = .invalid
                    flashLimitedDevice.unlockForConfiguration()
                } catch { }
            }
        }

        if expectsFlash, !proModeEnabled, let device = activeInput?.device,
           device.isExposureModeSupported(.continuousAutoExposure) {
            do {
                try device.lockForConfiguration()
                if let limit = Self.flashExposureLimit(
                    formatMax: device.activeFormat.maxExposureDuration,
                    target: targetMaxShutter
                ) {
                    device.activeMaxExposureDuration = limit
                    flashLimitApplied = true
                    flashLimitedDevice = device
                    requestedMaxSeconds = CMTimeGetSeconds(limit)
                }
                device.unlockForConfiguration()
            } catch { }
        }

        try Task.checkCancellation()
        let collectDiagnostics = OriginalFrameArchive.isEnabled
        let before = collectDiagnostics ? await exposureState() : nil
        var result = try await requestPhoto(settings)
        let after = collectDiagnostics ? await exposureState() : nil

        if collectDiagnostics {
            let actual = result.originalData.flatMap(OriginalFrameExposure.read)
            let honored = actual.flatMap { exposure in
                exposure.shutterSeconds.flatMap { shutter in
                    requestedMaxSeconds.map { shutter <= ($0 * 1.08) }
                }
            }
            let prioritizationName: String = switch settings.photoQualityPrioritization {
            case .speed: "speed"
            case .balanced: "balanced"
            default: "quality"
            }
            result.diagnostics = CaptureExposureDiagnostics(
                policyRevision: CaptureExposureDiagnostics.policyRevision,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                requestedFlash: ShootingIdentity.flashToken(settings.flashMode),
                prioritization: prioritizationName,
                manualExposure: proModeEnabled, flashLimitApplied: flashLimitApplied, requestedMaximumSeconds: requestedMaxSeconds,
                before: before, after: after,
                exposureStrategy: proModeEnabled ? "user-manual" : (flashLimitApplied ? "flash-clamped-auto" : "system-auto"),
                requestedISO: proModeEnabled ? manualISO : nil, actualExposure: actual,
                requestedShutterHonored: honored)
        }
        return result
    }

    private func requestPhoto(_ settings: AVCapturePhotoSettings) async throws -> CapturedPhoto {

        return try await withCheckedThrowingContinuation { continuation in
            captureContinuation = continuation
            captureCompletion = PhotoCaptureCompletion()
            captureRequestID = settings.uniqueID
            captureWatchdog?.cancel()
            captureWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self, self.captureRequestID == settings.uniqueID else { return }
                self.finishCapture(.failure(CameraIssue.captureFailed))
            }
            let rotationAngle = CaptureTilt.shared.videoRotationAngle(isFrontCamera: cameraPosition == .front)
            sessionQueue.async { [photoOutput] in
                if let connection = photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private func finishCapture(_ result: Result<CapturedPhoto, Error>) {
        captureWatchdog?.cancel()
        captureWatchdog = nil
        captureRequestID = nil
        captureCompletion = PhotoCaptureCompletion()
        let pending = captureContinuation
        captureContinuation = nil
        pending?.resume(with: result)
    }

    /// Reads `session.isRunning` off the session queue.
    private func isSessionRunning() async -> Bool {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                continuation.resume(returning: session.isRunning)
            }
        }
    }

    func captureSequence(flashModes: [AVCaptureDevice.FlashMode?]) async throws -> [(offset: Int, photo: CapturedPhoto)] {
        guard flashModes.count > 1 else {
            return [(0, try await capture(flashMode: flashModes.first ?? nil))]
        }
        guard !isCapturing else { throw CameraIssue.captureFailed }
        isCapturing = true
        defer { isCapturing = false }
        guard await isSessionRunning() else { throw CameraIssue.captureFailed }

        // Complete each ambient/flash member before requesting the next one;
        // the hardware flash sequence must finish before metering another frame.
        if flashModes.contains(where: { $0 == .on }) {
            var completed: [(offset: Int, photo: CapturedPhoto)] = []
            var lastError: Error = CameraIssue.captureFailed
            for (index, mode) in flashModes.enumerated() {
                try Task.checkCancellation()
                if index > 0 { try await Task.sleep(for: .milliseconds(380)) }
                do {
                    completed.append((index, try await captureOne(flashMode: mode)))
                } catch is CancellationError {
                    throw CancellationError()
                } catch { lastError = error }
            }
            guard !completed.isEmpty else { throw lastError }
            return completed
        }

        let settings: [AVCapturePhotoSettings] = flashModes.map { mode in
            let setting = AVCapturePhotoSettings()
            if cameraPosition == .back, let device = activeInput?.device, device.hasFlash, let mode {
                setting.flashMode = mode
            }
            setting.photoQualityPrioritization = Self.qualityPrioritization(manualExposure: proModeEnabled)
            return setting
        }
        sequenceIDs = settings.map(\.uniqueID)
        sequenceResults = [:]
        sequencePending = Set(sequenceIDs)
        sequenceLastError = nil

        return try await withCheckedThrowingContinuation { continuation in
            sequenceContinuation = continuation
            captureWatchdog?.cancel()
            captureWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, self.sequenceContinuation != nil else { return }
                self.finishSequenceWithAvailableFrames()
            }
            let rotationAngle = CaptureTilt.shared.videoRotationAngle(isFrontCamera: cameraPosition == .front)
            sessionQueue.async { [photoOutput] in
                if let connection = photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(rotationAngle) {
                    connection.videoRotationAngle = rotationAngle
                }
                var delay = 0.0
                for (index, setting) in settings.enumerated() {
                    if index > 0 {
                        let previous = flashModes[index - 1]
                        let current = flashModes[index]
                        // Only flash needs a recharge window. AVFoundation can
                        // queue ambient exposures immediately and pace hardware.
                        if previous == .on || current == .on {
                            delay += 0.38
                        }
                    }
                    let when = DispatchTime.now() + delay
                    self.sessionQueue.asyncAfter(deadline: when) {
                        photoOutput.capturePhoto(with: setting, delegate: self)
                    }
                }
            }
        }
    }

    /// Salvages whatever frames already arrived instead of discarding the whole
    /// burst when one exposure fails.
    private func finishSequenceWithAvailableFrames() {
        let ordered = sequenceIDs.enumerated().compactMap { offset, id in
            sequenceResults[id].map { (offset: offset, photo: $0) }
        }
        if ordered.isEmpty {
            finishSequence(.failure(sequenceLastError ?? CameraIssue.captureFailed))
        } else {
            finishSequence(.success(ordered))
        }
    }

    private func finishSequence(_ result: Result<[(offset: Int, photo: CapturedPhoto)], Error>) {
        captureWatchdog?.cancel()
        captureWatchdog = nil
        sequenceIDs = []
        sequenceResults = [:]
        sequencePending = []
        sequenceLastError = nil
        let pending = sequenceContinuation
        sequenceContinuation = nil
        pending?.resume(with: result)
    }

    func recordMoment(duration: Duration = .seconds(2)) async throws -> URL {
        guard !isCapturing, !movieOutput.isRecording else { throw CameraIssue.captureFailed }
        isCapturing = true
        defer { isCapturing = false }

        await addMomentAudioIfAuthorized()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketMoment-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let durationComponents = duration.components
        let delaySeconds = max(
            Double(durationComponents.seconds)
                + Double(durationComponents.attoseconds) / 1_000_000_000_000_000_000,
            0
        )

        return try await withCheckedThrowingContinuation { continuation in
            movieContinuation = continuation
            movieCaptureWatchdog?.cancel()
            movieCaptureWatchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self, let pending = movieContinuation else { return }
                movieContinuation = nil
                movieCaptureWatchdog = nil
                sessionQueue.async { [movieOutput] in
                    if movieOutput.isRecording { movieOutput.stopRecording() }
                }
                pending.resume(throwing: CameraIssue.captureFailed)
                await releaseMomentAudioIfNeeded()
            }
            sessionQueue.async { [movieOutput, sessionQueue] in
                movieOutput.startRecording(to: url, recordingDelegate: self)
                sessionQueue.asyncAfter(deadline: .now() + delaySeconds) {
                    if movieOutput.isRecording { movieOutput.stopRecording() }
                }
            }
        }
    }

    func switchCamera() async {
        let newPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
        let result: AVCaptureDeviceInput? = await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                            for: .video,
                                                            position: newPosition),
                      let newInput = try? AVCaptureDeviceInput(device: device) else {
                    continuation.resume(returning: nil)
                    return
                }

                // Read the session's inputs, not a value captured before the
                // await: two quick taps used to remove an already-removed input
                // and then add a second video input, leaving the session black.
                let previousInputs = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
                    .filter { $0.device.hasMediaType(.video) }
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                for input in previousInputs { session.removeInput(input) }
                guard session.canAddInput(newInput) else {
                    for input in previousInputs where session.canAddInput(input) {
                        session.addInput(input)
                    }
                    continuation.resume(returning: nil)
                    return
                }
                session.addInput(newInput)
                continuation.resume(returning: newInput)
            }
        }

        if let result {
            activeInput = result
            cameraPosition = newPosition
            previewPipeline.update(cameraPosition: newPosition)
            selectedLens = .wide
            zoomFactor = 1
            exposureBias = 0
            isAEAFlocked = false
            proModeEnabled = false
            refreshCapabilities()
        }
    }

    func switchLens(to lens: CameraLens) async {
        guard cameraPosition == .back, availableLenses.contains(lens), lens != selectedLens else { return }
        let result = await replaceInput(
            device: AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
            position: .back
        )
        if let result {
            activeInput = result
            previewPipeline.update(cameraPosition: .back)
            selectedLens = lens
            zoomFactor = 1
            exposureBias = 0
            isAEAFlocked = false
            proModeEnabled = false
            refreshCapabilities()
        }
    }

    func focus(at point: CGPoint) {
        guard !isCapturing else { return }
        guard let device = activeInput?.device else { return }
        isAEAFlocked = false
        let keepManualExposure = proModeEnabled
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                // Do not move the exposure point with focus. Tapping a dark
                // subject under the reticle used to re-meter for it and blow
                // out the rest of the scene; matrix AE protects highlights.
                if !keepManualExposure,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func lockFocusAndExposure(at point: CGPoint) {
        guard !isCapturing else { return }
        guard let device = activeInput?.device else { return }
        isAEAFlocked = true
        let keepManualExposure = proModeEnabled
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if !keepManualExposure {
                    if device.isExposurePointOfInterestSupported,
                       device.isExposureModeSupported(.autoExpose) {
                        device.exposurePointOfInterest = point
                        device.exposureMode = .autoExpose
                    } else if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                    }
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func adjustZoom(by scale: CGFloat) {
        guard let device = activeInput?.device else { return }
        let maximum = min(device.activeFormat.videoMaxZoomFactor, 5)
        let target = min(max(zoomFactor * scale, 1), maximum)
        zoomFactor = target
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = target
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func setExposureBias(_ value: Float) {
        guard let device = activeInput?.device else { return }
        let target = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
        exposureBias = target
        highlightExposure = HighlightExposureState()
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(target)
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func setProMode(_ enabled: Bool) {
        proModeEnabled = enabled
        highlightExposure = HighlightExposureState()
        guard let device = activeInput?.device else { return }
        let requestedISO = manualISO
        let requestedShutter = shutterSeconds
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(min(max(0, device.minExposureTargetBias), device.maxExposureTargetBias))
                if enabled, device.isExposureModeSupported(.custom) {
                    let iso = min(max(requestedISO, device.activeFormat.minISO), device.activeFormat.maxISO)
                    let duration = self.clampedDuration(seconds: requestedShutter, device: device)
                    device.setExposureModeCustom(duration: duration, iso: iso)
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func setManualISO(_ value: Float) {
        manualISO = value
        applyManualExposure()
    }

    func setShutterSeconds(_ value: Double) {
        shutterSeconds = value
        applyManualExposure()
    }

    func setWhiteBalanceKelvin(_ value: Float) {
        whiteBalanceKelvin = value
        guard let device = activeInput?.device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                guard device.isWhiteBalanceModeSupported(.locked) else {
                    device.unlockForConfiguration()
                    return
                }
                let temperature = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: value,
                    tint: 0
                )
                var gains = device.deviceWhiteBalanceGains(for: temperature)
                gains.redGain = min(max(gains.redGain, 1), device.maxWhiteBalanceGain)
                gains.greenGain = min(max(gains.greenGain, 1), device.maxWhiteBalanceGain)
                gains.blueGain = min(max(gains.blueGain, 1), device.maxWhiteBalanceGain)
                device.setWhiteBalanceModeLocked(with: gains)
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func setAutoWhiteBalance() {
        guard let device = activeInput?.device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
            } catch { }
        }
    }

    func save(_ image: UIImage, capturedAt: Date = .now, metadata: PhotoFrameMetadata? = nil) async -> Bool {
        await Self.saveToLibrary(image, capturedAt: capturedAt, metadata: metadata,
                                 location: LocationTagger.shared.captureLocation())
    }

    static func saveToLibrary(_ image: UIImage, capturedAt: Date,
                              metadata: PhotoFrameMetadata? = nil, location: CLLocation? = nil) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        let encoded = await Task.detached(priority: .userInitiated) { [image] in
            Self.encodedPhoto(
                image,
                capturedAt: capturedAt,
                location: location,
                exifData: metadata?.exif,
                tiffData: metadata?.tiff,
                sourceGpsData: metadata?.gps
            )
        }.value
        guard let encoded else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = capturedAt
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = encoded.type.identifier
                request.addResource(with: .photo, data: encoded.data, options: options)
            }
            return true
        } catch {
            return false
        }
    }

    /// Encodes the finished photo once, as HEIC when the device can (about 60%
    /// of the JPEG size at the same visible quality), JPEG otherwise. The
    /// capture-time metadata goes in either way.
    nonisolated static func encodedPhoto(
        _ image: UIImage,
        capturedAt: Date,
        location: CLLocation?,
        exifData: Data?,
        tiffData: Data?,
        sourceGpsData: Data?
    ) -> (data: Data, type: UTType)? {
        guard let image = ImagingColorPipeline.exportImage(image),
              let cgImage = image.cgImage else { return nil }
        let base = photoProperties(
            image: image, cgImage: cgImage, capturedAt: capturedAt,
            location: location, exifData: exifData, tiffData: tiffData,
            sourceGpsData: sourceGpsData
        )
        for (type, quality) in [(UTType.heic, 0.92), (UTType.jpeg, 0.95)] {
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                buffer, type.identifier as CFString, 1, nil
            ) else { continue }
            var properties = base
            properties[kCGImageDestinationLossyCompressionQuality] = quality
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            if CGImageDestinationFinalize(destination) { return (buffer as Data, type) }
        }
        return nil
    }

    private nonisolated static func photoProperties(
        image: UIImage,
        cgImage: CGImage,
        capturedAt: Date,
        location: CLLocation?,
        exifData: Data?,
        tiffData: Data?,
        sourceGpsData: Data?
    ) -> [CFString: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let timestamp = formatter.string(from: capturedAt)
        var exifProperties = propertyListDictionary(exifData) ?? [:]
        exifProperties[kCGImagePropertyExifDateTimeOriginal as String] = timestamp
        exifProperties[kCGImagePropertyExifDateTimeDigitized as String] = timestamp
        exifProperties[kCGImagePropertyExifPixelXDimension as String] = cgImage.width
        exifProperties[kCGImagePropertyExifPixelYDimension as String] = cgImage.height
        exifProperties[kCGImagePropertyExifColorSpace as String] = 1

        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exifProperties,
            kCGImagePropertyOrientation: exifOrientation(image.imageOrientation),
            kCGImageDestinationLossyCompressionQuality: 0.95
        ]
        if var tiff = propertyListDictionary(tiffData) {
            tiff[kCGImagePropertyTIFFOrientation as String] = exifOrientation(image.imageOrientation)
            tiff[kCGImagePropertyTIFFDateTime as String] = timestamp
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if let location {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: location.timestamp)
            let gps: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(location.coordinate.latitude),
                kCGImagePropertyGPSLatitudeRef: location.coordinate.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(location.coordinate.longitude),
                kCGImagePropertyGPSLongitudeRef: location.coordinate.longitude >= 0 ? "E" : "W",
                kCGImagePropertyGPSAltitude: location.altitude,
                kCGImagePropertyGPSAltitudeRef: location.altitude < 0 ? 1 : 0,
                kCGImagePropertyGPSDateStamp: String(
                    format: "%04d:%02d:%02d",
                    parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
                ),
                kCGImagePropertyGPSTimeStamp: String(
                    format: "%02d:%02d:%02d",
                    parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
                )
            ]
            properties[kCGImagePropertyGPSDictionary] = gps
        } else if let sourceGps = propertyListDictionary(sourceGpsData) {
            properties[kCGImagePropertyGPSDictionary] = sourceGps
        }
        return properties
    }

    private nonisolated static func propertyListDictionary(_ data: Data?) -> [String: Any]? {
        guard
            let data,
            let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = value as? [String: Any]
        else { return nil }
        return dictionary
    }

    private nonisolated static func exifOrientation(_ orientation: UIImage.Orientation) -> Int {
        switch orientation {
        case .up: 1
        case .down: 3
        case .left: 8
        case .right: 6
        case .upMirrored: 2
        case .downMirrored: 4
        case .leftMirrored: 5
        case .rightMirrored: 7
        @unknown default: 1
        }
    }

    func saveVideo(at url: URL, capturedAt: Date = .now) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                request?.creationDate = capturedAt
            }
            return true
        } catch {
            return false
        }
    }

    func saveLivePhoto(image: UIImage, videoURL: URL, capturedAt: Date = .now) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            let resources = try await LivePhotoResourceBuilder.make(image: image, videoURL: videoURL)
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = capturedAt
                request.addResource(with: .photo, fileURL: resources.photoURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: resources.videoURL, options: nil)
            }
            try? FileManager.default.removeItem(at: resources.photoURL)
            try? FileManager.default.removeItem(at: resources.videoURL)
            return true
        } catch {
            return false
        }
    }

    private func addMomentAudioIfAuthorized() async {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: authorized = false
        @unknown default: authorized = false
        }
        guard authorized, activeAudioInput == nil else { return }

        // Recording needs a category that allows input; the shutter-sound engine
        // otherwise leaves the shared session on .ambient.
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord, mode: .videoRecording,
            options: [.allowBluetoothHFP, .defaultToSpeaker, .mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)

        let input: AVCaptureDeviceInput? = await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                guard let device = AVCaptureDevice.default(for: .audio),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else {
                    continuation.resume(returning: nil)
                    return
                }
                session.beginConfiguration()
                session.addInput(input)
                session.commitConfiguration()
                continuation.resume(returning: input)
            }
        }
        activeAudioInput = input
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted: false
        @unknown default: false
        }
    }

    private func observeSessionEventsIfNeeded() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            Task { @MainActor in
                self?.interruptionMessage = rawReason == AVCaptureSession.InterruptionReason.videoDeviceInUseByAnotherClient.rawValue
                    ? "Camera is being used by another app."
                    : "Camera paused by the system."
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.interruptionMessage = nil
                await self?.start()
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            Task { @MainActor in
                if error?.code == .mediaServicesWereReset {
                    self?.interruptionMessage = "Restarting camera…"
                    await self?.rebuildSession()
                    await self?.prepare()
                    self?.interruptionMessage = nil
                } else {
                    self?.interruptionMessage = "Camera stopped unexpectedly."
                }
            }
        })
    }

    /// Rebuilds inputs/outputs after `mediaServicesWereReset`; merely calling
    /// `startRunning()` leaves the session permanently dead.
    private func rebuildSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                for output in session.outputs { session.removeOutput(output) }
                session.commitConfiguration()
                continuation.resume()
            }
        }
        if sequenceContinuation != nil {
            finishSequence(.failure(CameraIssue.captureFailed))
        } else {
            finishCapture(.failure(CameraIssue.captureFailed))
        }
        activeInput = nil
        activeAudioInput = nil
        isConfigured = false
        cameraPosition = .back
        proModeEnabled = false
        zoomFactor = 1
        exposureBias = 0
        availableLenses = [.wide]
        selectedLens = .wide
    }

    /// Removes the microphone input added for a Pocket Moment and releases the
    /// shared audio session so other apps and the system indicator return to normal.
    private func releaseMomentAudioIfNeeded() async {
        guard let audioInput = activeAudioInput else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [session] in
                session.beginConfiguration()
                if session.inputs.contains(where: { $0 === audioInput }) {
                    session.removeInput(audioInput)
                }
                session.commitConfiguration()
                continuation.resume()
            }
        }
        activeAudioInput = nil
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        // Returning to `.ambient` matters: the shutter-sound engine keeps
        // running and would otherwise stay on the recording route, ducking
        // other apps and changing how the shutter sounds.
        try? audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
    }

    nonisolated static func qualityPrioritization(
        manualExposure: Bool,
        hardwareFlash: Bool = false,
        fastCapture: Bool = false
    ) -> AVCapturePhotoOutput.QualityPrioritization {
        // Computational fusion may override custom ISO/shutter unless speed is
        // requested. Standard captures use `.balanced` to avoid multi-frame
        // Deep Fusion shutter stalls while preserving 12 MP detail.
        if manualExposure || hardwareFlash { return .speed }
        return fastCapture ? .balanced : .quality
    }

    private func exposureState() async -> CaptureExposureDiagnostics.ExposureState? {
        guard let device = activeInput?.device else { return nil }
        return await withCheckedContinuation { continuation in
            sessionQueue.async {
                func seconds(_ time: CMTime) -> Double? {
                    let value = CMTimeGetSeconds(time)
                    return value.isFinite && value > 0 ? value : nil
                }
                continuation.resume(returning: .init(
                    mode: device.exposureMode.rawValue,
                    maximumSeconds: seconds(device.activeMaxExposureDuration),
                    shutterSeconds: seconds(device.exposureDuration), iso: device.iso))
            }
        }
    }

    private func applySceneMetering(_ scene: SceneMetering, deviceID: String) {
        guard let device = activeInput?.device, device.uniqueID == deviceID,
              !proModeEnabled, !isCapturing, !movieOutput.isRecording,
              abs(exposureBias) < 0.01 else { return }
        let oldBias = highlightExposure.bias
        let bias = highlightExposure.update(scene)
        guard abs(bias - oldBias) > 0.005 else { return }
        sessionQueue.async {
            guard device.exposureMode == .continuousAutoExposure else { return }
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias))
                device.unlockForConfiguration()
            } catch { }
        }
    }

    private func refreshCapabilities() {
        highlightExposure = HighlightExposureState()
        previewPipeline.setMeteringHandler { [weak self] scene, deviceID in
            self?.applySceneMetering(scene, deviceID: deviceID)
        }
        if let device = activeInput?.device {
            previewPipeline.update(device: device)
            sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    device.setExposureTargetBias(min(max(0, device.minExposureTargetBias), device.maxExposureTargetBias))
                    device.unlockForConfiguration()
                } catch { }
            }
        }
        isFlashAvailable = activeInput?.device.hasFlash == true
        if cameraPosition == .front {
            availableLenses = [.wide]
            return
        }
        availableLenses = CameraLens.allCases.filter { lens in
            AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) != nil
        }
    }

    private func replaceInput(
        device: AVCaptureDevice?,
        position: AVCaptureDevice.Position
    ) async -> AVCaptureDeviceInput? {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                guard let device,
                      let newInput = try? AVCaptureDeviceInput(device: device) else {
                    continuation.resume(returning: nil)
                    return
                }
                let previousInputs = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
                    .filter { $0.device.hasMediaType(.video) }
                session.beginConfiguration()
                defer { session.commitConfiguration() }
                for input in previousInputs { session.removeInput(input) }
                guard session.canAddInput(newInput) else {
                    for input in previousInputs where session.canAddInput(input) {
                        session.addInput(input)
                    }
                    continuation.resume(returning: nil)
                    return
                }
                session.addInput(newInput)
                continuation.resume(returning: newInput)
            }
        }
    }

    private func applyManualExposure() {
        guard proModeEnabled, let device = activeInput?.device else { return }
        let iso = manualISO
        let seconds = shutterSeconds
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                guard device.isExposureModeSupported(.custom) else {
                    device.unlockForConfiguration()
                    return
                }
                let clampedISO = min(max(iso, device.activeFormat.minISO), device.activeFormat.maxISO)
                device.setExposureModeCustom(
                    duration: self.clampedDuration(seconds: seconds, device: device),
                    iso: clampedISO
                )
                device.unlockForConfiguration()
            } catch { }
        }
    }

    /// The flash path caps auto exposure at 1/45 s to protect the tube and
    /// avoid motion smear. Pure so the rule is testable without a device.
    nonisolated static func flashExposureLimit(
        formatMax: CMTime,
        target: CMTime = CMTime(value: 1, timescale: 45)
    ) -> CMTime? {
        formatMax >= target ? target : nil
    }

    nonisolated private func clampedDuration(seconds: Double, device: AVCaptureDevice) -> CMTime {
        let requested = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
        return CMTimeMaximum(device.activeFormat.minExposureDuration,
                             CMTimeMinimum(requested, device.activeFormat.maxExposureDuration))
    }
}

/// Optional location tagging. The switch lives in Camera Setup and only then
/// asks for When-In-Use permission; captures without a fresh fix carry no GPS.
@MainActor
final class LocationTagger: NSObject, CLLocationManagerDelegate {
    static let shared = LocationTagger()
    static let enabledKey = "locationTaggingEnabled"

    private let manager = CLLocationManager()
    private(set) var lastLocation: CLLocation?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
            lastLocation = nil
        }
    }

    func resumeIfEnabledAndAuthorized() {
        guard isEnabled else { return }
        if manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    /// Never prompts; returns a recent fix only when the user opted in.
    func captureLocation() -> CLLocation? {
        guard isEnabled,
              manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways,
              let lastLocation,
              abs(lastLocation.timestamp.timeIntervalSinceNow) < 600 else { return nil }
        return lastLocation
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.lastLocation = location }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                if self.isEnabled { self.manager.startUpdatingLocation() }
            default:
                self.manager.stopUpdatingLocation()
                self.lastLocation = nil
                // A denied request must not leave the switch on with no effect.
                UserDefaults.standard.set(false, forKey: Self.enabledKey)
            }
        }
    }
}

enum LivePhotoResourceBuilder {
    struct Resources { let photoURL: URL; let videoURL: URL }

    /// AVAssetReader/Writer objects are deliberately confined to their two
    /// serial media queues and joined before completion. AVFoundation does not
    /// annotate these reference types Sendable, so this holder documents the
    /// bounded executor contract at the GCD bridge.
    private final class MediaBridge: @unchecked Sendable {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let videoOutput: AVAssetReaderTrackOutput
        let audioInput: AVAssetWriterInput?
        let audioOutput: AVAssetReaderTrackOutput?

        init(
            writer: AVAssetWriter,
            videoInput: AVAssetWriterInput,
            videoOutput: AVAssetReaderTrackOutput,
            audioInput: AVAssetWriterInput?,
            audioOutput: AVAssetReaderTrackOutput?
        ) {
            self.writer = writer
            self.videoInput = videoInput
            self.videoOutput = videoOutput
            self.audioInput = audioInput
            self.audioOutput = audioOutput
        }
    }

    static func make(image: UIImage, videoURL: URL) async throws -> Resources {
        let identifier = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
        let photoURL = directory.appendingPathComponent("PocketMoment-\(identifier).jpg")
        let pairedURL = directory.appendingPathComponent("PocketMoment-Live-\(identifier).mov")
        try writeJPEG(image, identifier: identifier, to: photoURL)
        try await writePairedVideo(sourceURL: videoURL, identifier: identifier, to: pairedURL)
        return Resources(photoURL: photoURL, videoURL: pairedURL)
    }

    private static func writeJPEG(_ image: UIImage, identifier: String, to url: URL) throws {
        guard let cgImage = image.cgImage,
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              ) else { throw CameraIssue.captureFailed }
        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImageDestinationLossyCompressionQuality: 0.94
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CameraIssue.captureFailed }
    }

    private static func writePairedVideo(sourceURL: URL, identifier: String, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CameraIssue.captureFailed
        }
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        guard reader.canAdd(videoOutput) else { throw CameraIssue.captureFailed }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let formatDescription = try await videoTrack.load(.formatDescriptions).first
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatDescription)
        videoInput.transform = try await videoTrack.load(.preferredTransform)
        guard writer.canAdd(videoInput) else { throw CameraIssue.captureFailed }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            let audioFormat = try await audioTrack.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output); writer.add(input)
                audioOutput = output; audioInput = input
            }
        }

        let metadataSpec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8 as String
        ]
        var metadataDescription: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [metadataSpec] as CFArray,
            formatDescriptionOut: &metadataDescription
        )
        guard let metadataDescription else { throw CameraIssue.captureFailed }
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                               sourceFormatHint: metadataDescription)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        guard writer.canAdd(metadataInput) else { throw CameraIssue.captureFailed }
        writer.add(metadataInput)

        let contentIdentifier = AVMutableMetadataItem()
        contentIdentifier.keySpace = .quickTimeMetadata
        contentIdentifier.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier as NSString
        contentIdentifier.value = identifier as NSString
        writer.metadata = [contentIdentifier]

        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? CameraIssue.captureFailed
        }
        writer.startSession(atSourceTime: .zero)
        let stillItem = AVMutableMetadataItem()
        stillItem.keySpace = .quickTimeMetadata
        stillItem.key = "com.apple.quicktime.still-image-time" as NSString
        stillItem.value = 0 as NSNumber
        stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
        metadataAdaptor.append(AVTimedMetadataGroup(
            items: [stillItem],
            timeRange: CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), duration: CMTime(value: 1, timescale: 30))
        ))
        metadataInput.markAsFinished()

        let bridge = MediaBridge(
            writer: writer,
            videoInput: videoInput,
            videoOutput: videoOutput,
            audioInput: audioInput,
            audioOutput: audioOutput
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            group.enter()
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "app.pocketccd.livephoto.video")) {
                while bridge.videoInput.isReadyForMoreMediaData {
                    guard let sample = bridge.videoOutput.copyNextSampleBuffer() else {
                        bridge.videoInput.markAsFinished(); group.leave(); break
                    }
                    if !bridge.videoInput.append(sample) { bridge.videoInput.markAsFinished(); group.leave(); break }
                }
            }
            if let audioInput = bridge.audioInput, bridge.audioOutput != nil {
                group.enter()
                audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "app.pocketccd.livephoto.audio")) {
                    while bridge.audioInput?.isReadyForMoreMediaData == true {
                        guard let sample = bridge.audioOutput?.copyNextSampleBuffer() else {
                            bridge.audioInput?.markAsFinished(); group.leave(); break
                        }
                        if bridge.audioInput?.append(sample) != true {
                            bridge.audioInput?.markAsFinished(); group.leave(); break
                        }
                    }
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                bridge.writer.finishWriting {
                    if bridge.writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: bridge.writer.error ?? CameraIssue.captureFailed) }
                }
            }
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let encoded = photo.fileDataRepresentation()
        let decoded = photo.pixelBuffer.flatMap {
            Self.decodedCapture(from: $0, orientation: Self.captureOrientation(from: photo.metadata))
        }
        let captured = (decoded ?? encoded.flatMap { UIImage(data: $0)?.withOrientationBakedIn() }).map {
            CapturedPhoto(image: $0, originalData: encoded, metadata: PhotoFrameMetadata(photo.metadata))
        }
        let uniqueID = photo.resolvedSettings.uniqueID
        Task { @MainActor in
            if sequencePending.remove(uniqueID) != nil {
                if let error {
                    sequenceLastError = error
                } else if let captured {
                    sequenceResults[uniqueID] = captured
                } else {
                    sequenceLastError = CameraIssue.captureFailed
                }
                if sequencePending.isEmpty {
                    finishSequenceWithAvailableFrames()
                }
                return
            }
            guard captureRequestID == uniqueID else { return }
            if let error {
                captureCompletion.processed = .failure(error)
            } else if let captured {
                captureCompletion.processed = .success(captured)
            } else {
                captureCompletion.processed = .failure(CameraIssue.captureFailed)
            }
            if let result = captureCompletion.result { finishCapture(result) }
        }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        let uniqueID = resolvedSettings.uniqueID
        Task { @MainActor in
            guard captureRequestID == uniqueID else { return }
            captureCompletion.finished = true
            captureCompletion.terminalError = error
            if let result = captureCompletion.result { finishCapture(result) }
        }
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            movieCaptureWatchdog?.cancel()
            movieCaptureWatchdog = nil
            let pending = movieContinuation
            if let error, let pending {
                pending.resume(throwing: error)
                try? FileManager.default.removeItem(at: outputFileURL)
            } else if let pending {
                pending.resume(returning: outputFileURL)
            } else {
                // A watchdog already completed the request; this late delegate
                // result has no owner and must not leak a temporary movie.
                try? FileManager.default.removeItem(at: outputFileURL)
            }
            movieContinuation = nil
            // The microphone must not stay attached after the Moment ends:
            // otherwise the system mic indicator stays lit while the camera runs.
            await releaseMomentAudioIfNeeded()
        }
    }
}

/// Synthesised mechanical shutter. Each fictional camera gets its own weight so
/// A7 sounds soft, A8 a hard click, C1 crisp and N2 dull, without shipping audio assets.
@MainActor
final class ShutterSoundPlayer {
    static let shared = ShutterSoundPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [CCDLook: AVAudioPCMBuffer] = [:]
    private var flashBuffers: [CCDLook: AVAudioPCMBuffer] = [:]
    private var prepared = false

    func play(for look: CCDLook, flashed: Bool = false) {
        let enabled = UserDefaults.standard.object(forKey: "shutterSoundEnabled") as? Bool ?? true
        guard enabled else { return }
        prepareIfNeeded()
        let buffer = flashed ? (flashBuffers[look] ?? buffers[look]) : buffers[look]
        guard let buffer else { return }
        if !engine.isRunning {
            // A Pocket Moment may have deactivated the shared session.
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func prepareIfNeeded() {
        guard !prepared else { return }
        prepared = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try? engine.start()
        for look in CCDLook.allCases {
            buffers[look] = Self.makeBuffer(for: look, format: format)
            flashBuffers[look] = Self.makeFlushedBuffer(for: look, format: format)
        }
    }

    private static func makeFlushedBuffer(for look: CCDLook, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let base = makeBuffer(for: look, format: format) else { return nil }
        let sampleRate = format.sampleRate
        let whineDuration = 0.28
        let totalDuration = Double(base.frameLength) / sampleRate + whineDuration
        let frameCount = AVAudioFrameCount(totalDuration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let outChannel = buffer.floatChannelData?[0],
              let baseChannel = base.floatChannelData?[0] else { return base }
        buffer.frameLength = frameCount
        let baseCount = Int(base.frameLength)
        for i in 0..<baseCount {
            outChannel[i] = baseChannel[i]
        }
        // Synthesise retro capacitor charge whine rising in pitch from 2400 Hz to 7200 Hz
        for i in baseCount..<Int(frameCount) {
            let t = Double(i - baseCount) / sampleRate
            let normalized = t / whineDuration
            let freq = 2400.0 + 4800.0 * (normalized * normalized)
            let envelope = sin(normalized * .pi) * 0.14
            let whine = Float(sin(2 * .pi * freq * t) * envelope)
            outChannel[i] = whine
        }
        return buffer
    }

    private static func makeBuffer(for look: CCDLook, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let (frequency, duration, decay): (Double, Double, Double)
        switch look {
        case .amber: (frequency, duration, decay) = (208, 0.105, 34)
        // A8 is the hard flash body: a shorter, higher click with almost no tail.
        case .party: (frequency, duration, decay) = (286, 0.062, 58)
        case .chrome: (frequency, duration, decay) = (332, 0.078, 46)
        case .night: (frequency, duration, decay) = (154, 0.135, 26)
        case .negative: (frequency, duration, decay) = (220, 0.095, 38)
        case .mono: (frequency, duration, decay) = (246, 0.085, 42)
        }
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount
        var generator = SystemRandomNumberGenerator()
        for index in 0..<Int(frameCount) {
            let time = Double(index) / sampleRate
            let click = Double.random(in: -1...1, using: &generator) * exp(-time * 120) * 0.55
            let thump = sin(2 * .pi * frequency * time) * exp(-time * decay) * 0.5
            let tail = sin(2 * .pi * frequency * 0.5 * time) * exp(-time * decay * 0.55) * 0.18
            channel[index] = Float((click + thump + tail) * 0.6)
        }
        return buffer
    }
}
