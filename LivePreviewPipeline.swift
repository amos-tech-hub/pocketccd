@preconcurrency import AVFoundation
@preconcurrency import CoreImage
import UIKit
import Vision

/// Configuration shared with the UI is protected by `lock`; frame timing and
/// gesture counters are confined to AVFoundation's single preview queue.
/// `@unchecked` is only the bridge for delegate APIs lacking Sendable metadata.
final class LivePreviewPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let context = ImagingColorPipeline.makeContext()
    private var sensor = SensorIdentity.current()
    private var look: CCDLook = .amber
    private var aspectRatio = CaptureAspectRatio.fourThree
    private var focalCrop: CGFloat = 1
    private var isFrontCamera = false
    private var frameHandler: (@MainActor @Sendable (CIImage, @escaping @Sendable (Int, Int) -> Void) -> Void)?
    private var frameDeliveryPending = false
    private var lastFrameTime: CFTimeInterval = 0
    private var gestureEnabled = false
    private var gestureHandler: (@MainActor @Sendable () -> Void)?
    private var lastGestureTime: CFTimeInterval = 0
    private var stableGestureFrames = 0
    /// Hand-pose inference runs on its own queue so a 12 MP Vision request can
    /// never stall the preview render queue. One request in flight at a time.
    private let visionQueue = DispatchQueue(label: "work.doublenine.pocketccd.handpose", qos: .utility)
    private var handPoseInFlight = false
    private var flashMode: AVCaptureDevice.FlashMode = .off
    private var colorAnchor: CaptureColorAnchor?
    private var consistencyStrength: CGFloat = 0
    /// Auto flash is only knowable after the frame is captured, so the preview
    /// estimates it from scene brightness. Hysteresis keeps the looker from
    /// flickering while the estimate sits on the threshold.
    private var autoFlashActive = false
    private var lastFlashSampleTime: CFTimeInterval = 0
    private var device: AVCaptureDevice?
    private var configurationRevision = 0
    // These are confined to the video delegate queue.
    private var renderedRevision = -1
    private var frameGeometry: PreviewFrameGeometry?

    var previewGeometry: PreviewFrameGeometry? {
        lock.withLock { frameGeometry }
    }
    private var balanceState = PreviewWhiteBalanceState()
    private var lastBalanceSampleTime: CFTimeInterval = 0
    private var lastMeteringTime: CFTimeInterval = 0
    private var meteringHandler: (@MainActor @Sendable (SceneMetering, String) -> Void)?

    override init() {
        super.init()
        // A 64³ red-guard table is 4 MB; eagerly building a dozen of them on
        // the main thread blocked the first camera frame. The caches are
        // lock-protected, so warming them off-main is safe.
        Task.detached(priority: .utility) {
            CCDLook.prewarmCubes()
            CCDLook.prewarmRedGuard(for: .amber)
        }
    }

    func update(device: AVCaptureDevice) {
        lock.withLock {
            self.device = device
            configurationRevision += 1
        }
    }

    func setMeteringHandler(_ handler: @escaping @MainActor @Sendable (SceneMetering, String) -> Void) {
        lock.withLock { meteringHandler = handler }
    }

    /// While the user is dragging exposure or tapping focus, the frame is
    /// rendered at a smaller long edge and restored once the gesture settles.
    /// A shorter frame during a gesture is a free win; a shorter frame at rest
    /// is the product.
    private var interactionActive = false
    private var interactionEndedAt: CFTimeInterval = 0
    private static let minimumFrameInterval: CFTimeInterval = 1.0 / 30.0 - 0.004
    private let autoFlashOnLuma = 0.16
    private let autoFlashOffLuma = 0.24

    func update(look: CCDLook) {
        let changed = lock.withLock { () -> Bool in
            guard self.look != look else { return false }
            configurationRevision += 1
            self.look = look
            return true
        }
        if changed {
            CCDLook.prewarmRedGuard(for: look)
        }
    }

    func update(aspectRatio: CaptureAspectRatio) {
        lock.withLock {
            if self.aspectRatio != aspectRatio { configurationRevision += 1 }
            self.aspectRatio = aspectRatio
        }
    }

    func update(focalCrop: CGFloat) {
        let factor = focalCrop.isFinite ? max(focalCrop, 1) : 1
        lock.withLock {
            if self.focalCrop != factor { configurationRevision += 1 }
            self.focalCrop = factor
        }
    }

    func update(cameraPosition: AVCaptureDevice.Position) {
        lock.withLock {
            isFrontCamera = cameraPosition == .front
            configurationRevision += 1
        }
    }

    func update(sensorFingerprintEnabled: Bool) {
        lock.withLock { sensor = sensorFingerprintEnabled ? .current() : .generic }
    }

    func update(flashMode: AVCaptureDevice.FlashMode) {
        lock.withLock {
            if self.flashMode != flashMode { configurationRevision += 1 }
            self.flashMode = flashMode
        }
    }

    /// The roll anchor is read-only here: `RollStore.colorAnchor(for:sample:)`
    /// writes on every call, so previewing with it would push the anchor around
    /// at preview frame rate and create the drift the anchor exists to prevent.
    func update(colorAnchor: CaptureColorAnchor?, consistencyStrength: CGFloat) {
        lock.withLock {
            self.colorAnchor = colorAnchor
            self.consistencyStrength = consistencyStrength
        }
    }

    func setFrameHandler(_ handler: (@MainActor @Sendable (CIImage, @escaping @Sendable (Int, Int) -> Void) -> Void)?) {
        lock.withLock { frameHandler = handler }
    }

    /// Marks the start and end of a direct-manipulation gesture. The preview
    /// drops to a smaller long edge while the gesture is live and returns to
    /// full preview resolution after a short settle window.
    func setInteraction(active: Bool) {
        lock.withLock {
            interactionActive = active
            if !active { interactionEndedAt = CACurrentMediaTime() }
        }
    }

    func setGestureDetection(enabled: Bool, handler: (@MainActor @Sendable () -> Void)?) {
        lock.withLock {
            gestureEnabled = enabled
            gestureHandler = handler
            if !enabled { stableGestureFrames = 0 }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        autoreleasepool {
            processFrame(sampleBuffer)
        }
    }

    private func processFrame(_ sampleBuffer: CMSampleBuffer) {
        #if DEBUG
        PreviewStats.shared.recordArrival()
        #endif
        let now = CACurrentMediaTime()
        // A hard 1/24 s gate on a 30 fps stream drops every other frame and lands
        // at 15 fps — measured on device as 214 frames / 15 s. The look costs
        // ~21 ms a frame, so the pipeline can afford the source rate; the small
        // tolerance keeps 30 fps sources from losing every other tick to jitter.
        guard now - lastFrameTime >= Self.minimumFrameInterval,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = now

        let state = lock.withLock { () -> FrameConfiguration? in
            guard !frameDeliveryPending else {
                #if DEBUG
                PreviewStats.shared.recordSkip()
                #endif
                return nil
            }
            frameDeliveryPending = true
            return FrameConfiguration(
                look: look,
                isFrontCamera: isFrontCamera,
                handler: frameHandler,
                sensor: sensor,
                aspectRatio: aspectRatio,
                focalCrop: focalCrop,
                flashMode: flashMode,
                colorAnchor: colorAnchor,
                consistencyStrength: consistencyStrength,
                interacting: interactionActive || (now - interactionEndedAt < 0.25),
                device: device,
                revision: configurationRevision,
                meteringHandler: meteringHandler
            )
        }
        guard let state else { return }
        guard let handler = state.handler else {
            lock.withLock { frameDeliveryPending = false }
            return
        }
        if renderedRevision != state.revision {
            renderedRevision = state.revision
            balanceState = PreviewWhiteBalanceState()
            lastBalanceSampleTime = 0
            lastMeteringTime = 0
            lastFlashSampleTime = 0
            autoFlashActive = false
        }
        let orientation: CGImagePropertyOrientation = state.isFrontCamera ? .leftMirrored : .right
        let orientedSource = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        // Match the saved photo's centered crop before applying the look.
        let source = orientedSource.cropped(to: state.aspectRatio.cropRect(in: orientedSource.extent, focalCrop: state.focalCrop))
        let longestSide = max(source.extent.width, source.extent.height)
        // A gesture is a transient state: 900 px keeps the drag responsive,
        // then the preview returns to 1280 px once it settles.
        let longEdge: CGFloat = state.interacting ? 900 : 1280
        let previewScale = min(1, longEdge / max(longestSide, 1))
        let previewSource = previewScale < 1
            ? source.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))
            : source
        detectOpenHand(in: previewSource, now: now)
        let t0 = CACurrentMediaTime()
        let flash = flashStrength(for: previewSource, now: now, mode: state.flashMode)
        let conditions = CaptureImagingConditions(
            iso: state.device.map { Double($0.iso) },
            allowsSceneWhiteBalance: state.device?.whiteBalanceMode != .locked
        )
        let stabilizedSource = CCDLook.stabilizedInput(previewSource, colorAnchor: state.colorAnchor,
                                                       consistencyStrength: state.consistencyStrength)
        if now - lastBalanceSampleTime >= 0.25 || balanceState.value == nil {
            lastBalanceSampleTime = now
            _ = balanceState.update(target: conditions.allowsSceneWhiteBalance
                ? CCDLook.sceneBlueGain(stabilizedSource) : 1, at: now)
        }
        if now - lastMeteringTime >= 0.5, let device = state.device,
           let callback = state.meteringHandler,
           let metering = measureScene(previewSource, flashExpected: flash > 0.5) {
            lastMeteringTime = now
            let id = device.uniqueID
            Task { @MainActor in callback(metering, id) }
        }
        let filtered = state.look.livePreview(
            stabilizedSource,
            sensor: state.sensor,
            flashStrength: flash,
            balanceGain: balanceState.value,
            conditions: conditions
        )
        let geometry = PreviewFrameGeometry(sourceSize: orientedSource.extent.size,
                                             aspectRatio: state.aspectRatio, focalCrop: state.focalCrop)
        lock.withLock { frameGeometry = geometry }
        let prepareMs = (CACurrentMediaTime() - t0) * 1000
        DispatchQueue.main.async { [weak self] in
            handler(filtered) { [weak self] width, height in
                let totalMs = (CACurrentMediaTime() - t0) * 1000
                guard let self else { return }
                self.lock.withLock { self.frameDeliveryPending = false }
                #if DEBUG
                PreviewStats.shared.record(renderMs: prepareMs,
                                           mainLatencyMs: totalMs,
                                           width: width,
                                           height: height)
                #endif
            }
        }
    }

    /// `.on` is certain; `.off` is certain; `.auto` is decided here because the
    /// real answer only arrives in the captured photo's EXIF.
    private func flashStrength(for image: CIImage, now: CFTimeInterval, mode: AVCaptureDevice.FlashMode) -> Double {
        switch mode {
        case .on:
            return 1
        case .off:
            return 0
        case .auto:
            // One 1×1 readback every 250 ms is enough for a slow-moving scene
            // cue and keeps the per-frame budget intact.
            if now - lastFlashSampleTime > 0.25 {
                lastFlashSampleTime = now
                let luma = meanLuma(of: image)
                if luma < autoFlashOnLuma {
                    autoFlashActive = true
                } else if luma > autoFlashOffLuma {
                    autoFlashActive = false
                }
            }
            return autoFlashActive ? 1 : 0
        @unknown default:
            return 0
        }
    }

    private func meanLuma(of image: CIImage) -> Double {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1,
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: image,
                  kCIInputExtentKey: CIVector(cgRect: extent)
              ]),
              let output = filter.outputImage else { return 1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = Double(pixel[0]) / 255
        let g = Double(pixel[1]) / 255
        let b = Double(pixel[2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func measureScene(_ input: CIImage, flashExpected: Bool) -> SceneMetering? {
        let extent = input.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = 32 / max(extent.width, extent.height)
        let proxy = input.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
        let width = max(1, Int(extent.width * scale))
        let height = max(1, Int(extent.height * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(proxy, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: ImagingColorPipeline.output)
        var luminance = 0.0, highlights = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            luminance += 0.2126 * r + 0.7152 * g + 0.0722 * b
            if min(r, g, b) > 0.985 { highlights += 1 }
        }
        let count = Double(width * height)
        return SceneMetering(luminance: luminance / count,
                             highlightFraction: highlights / count, flashExpected: flashExpected)
    }

    private struct FrameConfiguration {
        let look: CCDLook
        let isFrontCamera: Bool
        let handler: (@MainActor @Sendable (CIImage, @escaping @Sendable (Int, Int) -> Void) -> Void)?
        let sensor: SensorIdentity
        let aspectRatio: CaptureAspectRatio
        let focalCrop: CGFloat
        let flashMode: AVCaptureDevice.FlashMode
        let colorAnchor: CaptureColorAnchor?
        let consistencyStrength: CGFloat
        let interacting: Bool
        let device: AVCaptureDevice?
        let revision: Int
        let meteringHandler: (@MainActor @Sendable (SceneMetering, String) -> Void)?
    }

    /// A tiny immutable copy of the downscaled frame. `CGImage` has no
    /// Sendable annotation but this value is never mutated after init.
    private final class HandPoseFrame: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private func detectOpenHand(in image: CIImage, now: CFTimeInterval) {
        let enabled = lock.withLock { gestureEnabled }
        guard enabled, now - lastGestureTime > 0.22 else { return }
        // Do not spend a GPU→CPU readback only to discover that Vision is
        // still busy with the previous request. Only the preview queue enters
        // this function, so a pre-check followed by the flag write is safe.
        let busy = lock.withLock { handPoseInFlight }
        guard !busy else { return }
        lastGestureTime = now

        // Vision used to receive the full 4032×3024 sample buffer on the
        // preview queue. A 320 px proxy is plenty for a hand pose and keeps
        // the request around a millisecond.
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return }
        let scale = min(1, 320 / max(extent.width, extent.height))
        let proxy = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(proxy, from: proxy.extent) else { return }
        let frame = HandPoseFrame(cgImage)
        lock.withLock { handPoseInFlight = true }

        visionQueue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { self.handPoseInFlight = false } }
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 1
            try? VNImageRequestHandler(cgImage: frame.image, orientation: .up).perform([request])
            let visibleTips: Int
            if let hand = request.results?.first,
               let points = try? hand.recognizedPoints(.all) {
                let tips: [VNHumanHandPoseObservation.JointName] = [
                    .thumbTip, .indexTip, .middleTip, .ringTip, .littleTip
                ]
                visibleTips = tips.filter { (points[$0]?.confidence ?? 0) > 0.55 }.count
            } else {
                visibleTips = 0
            }
            let shouldFire = self.lock.withLock { () -> Bool in
                if visibleTips >= 4 {
                    self.stableGestureFrames += 1
                } else {
                    self.stableGestureFrames = 0
                }
                guard self.stableGestureFrames >= 3 else { return false }
                self.stableGestureFrames = 0
                return true
            }
            guard shouldFire,
                  let handler = self.lock.withLock({ self.gestureHandler }) else { return }
            DispatchQueue.main.async { handler() }
        }
    }
}


#if DEBUG
/// DEBUG-only preview cost probe. Aggregates per-frame render time and main
/// delivery latency, then writes `Documents/preview-stats.json` so the numbers
/// can be pulled off a real device with `devicectl device copy from`.
final class PreviewStats: @unchecked Sendable {
    static let shared = PreviewStats()

    private let lock = NSLock()
    private var arrivals = 0
    private var frames = 0
    private var skipped = 0
    private var renderTotal = 0.0
    private var renderMax = 0.0
    private var latencyTotal = 0.0
    private var latencyMax = 0.0
    private var size = CGSize.zero
    private var lastFlush = CACurrentMediaTime()
    private var wroteFirst = false

    func recordArrival() {
        lock.withLock { arrivals += 1 }
    }

    func recordSkip() {
        lock.withLock { skipped += 1 }
    }

    func record(renderMs: Double, mainLatencyMs: Double, width: Int, height: Int) {
        var snapshot: [String: Any]?
        lock.withLock {
            frames += 1
            renderTotal += renderMs
            renderMax = max(renderMax, renderMs)
            latencyTotal += mainLatencyMs
            latencyMax = max(latencyMax, mainLatencyMs)
            size = CGSize(width: width, height: height)
            if !wroteFirst || CACurrentMediaTime() - lastFlush > 2 {
                wroteFirst = true
                lastFlush = CACurrentMediaTime()
                snapshot = payloadLocked()
            }
        }
        if let snapshot { write(snapshot) }
    }

    private func payloadLocked() -> [String: Any] {
        [
            "arrivals": arrivals,
            "frames": frames,
            "skipped": skipped,
            "renderAvgMs": frames > 0 ? renderTotal / Double(frames) : 0,
            "renderMaxMs": renderMax,
            "mainLatencyAvgMs": frames > 0 ? latencyTotal / Double(frames) : 0,
            "mainLatencyMaxMs": latencyMax,
            "width": Int(size.width),
            "height": Int(size.height),
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
    }

    private func write(_ payload: [String: Any]) {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                      in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        else { return }
        try? data.write(to: documents.appendingPathComponent("preview-stats.json"))
    }
}
#endif
