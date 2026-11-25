import Foundation
import ImageIO
import UIKit

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case standard
    case flashParty
    case flashPair
    case flashSequence
    case moment

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .standard: "Standard"
        case .flashParty: "Flash Party"
        case .flashPair: "Flash Pair"
        case .flashSequence: "Flash Sequence"
        case .moment: "Pocket Moment"
        }
    }

    var shortTitle: String {
        switch self {
        case .standard: String(localized: "STD")
        case .flashParty: String(localized: "PARTY")
        case .flashPair: String(localized: "PAIR")
        case .flashSequence: String(localized: "SEQ")
        case .moment: String(localized: "2 SEC")
        }
    }

    var consistencyStrength: CGFloat {
        switch self {
        case .standard: 0
        case .flashParty: 0.8
        case .flashPair: 0.2
        case .flashSequence: 0.3
        case .moment: 0
        }
    }
}

enum FrameRole: String, Codable {
    case standard
    case ambient
    case flash
    case reaction

    var title: LocalizedStringResource {
        switch self {
        case .standard: "Photo"
        case .ambient: "Ambient"
        case .flash: "Flash"
        case .reaction: "Reaction"
        }
    }
}

struct CapturedFrame: Identifiable {
    let id = UUID()
    let image: UIImage
    let role: FrameRole
    let qualityScore: Double
    let eyeOpenness: Double
    let sharpness: Double
    let hasFaces: Bool
    let rescue: RescueDiagnosis
    let metadata: PhotoFrameMetadata?

    init(
        image: UIImage,
        role: FrameRole,
        qualityScore: Double,
        eyeOpenness: Double = 0.5,
        sharpness: Double = 0.5,
        hasFaces: Bool = false,
        rescue: RescueDiagnosis = .none,
        metadata: PhotoFrameMetadata? = nil
    ) {
        self.image = image
        self.role = role
        self.qualityScore = qualityScore
        self.eyeOpenness = eyeOpenness
        self.sharpness = sharpness
        self.hasFaces = hasFaces
        self.rescue = rescue
        self.metadata = metadata
    }

    init(image: UIImage, role: FrameRole, assessment: FrameAssessment, metadata: PhotoFrameMetadata? = nil) {
        self.init(
            image: image,
            role: role,
            qualityScore: assessment.overall,
            eyeOpenness: assessment.eyeOpenness,
            sharpness: assessment.sharpness,
            hasFaces: assessment.hasFaces,
            rescue: assessment.rescue,
            metadata: metadata
        )
    }

    func ranksBefore(_ other: CapturedFrame) -> Bool {
        FrameAssessment(
            overall: qualityScore,
            eyeOpenness: eyeOpenness,
            sharpness: sharpness,
            hasFaces: hasFaces,
            rescue: rescue
        ).ranksBefore(FrameAssessment(
            overall: other.qualityScore,
            eyeOpenness: other.eyeOpenness,
            sharpness: other.sharpness,
            hasFaces: other.hasFaces,
            rescue: other.rescue
        ))
    }
}

struct CaptureResult: Identifiable {
    let id = UUID()
    let mode: CaptureMode
    let camera: CCDLook
    let createdAt: Date
    let frames: [CapturedFrame]
    let suggestedIndex: Int
    var momentVideoURL: URL? = nil

    init(
        mode: CaptureMode,
        camera: CCDLook,
        createdAt: Date,
        frames: [CapturedFrame],
        suggestedIndex: Int,
        momentVideoURL: URL? = nil
    ) {
        // A result without frames used to crash later on `suggestedFrame`;
        // fail at the construction site where the missing capture is obvious.
        precondition(!frames.isEmpty, "CaptureResult requires at least one frame")
        self.mode = mode
        self.camera = camera
        self.createdAt = createdAt
        self.frames = frames
        self.suggestedIndex = suggestedIndex
        self.momentVideoURL = momentVideoURL
    }

    var suggestedFrame: CapturedFrame {
        frames[min(max(suggestedIndex, 0), frames.count - 1)]
    }
}

struct SensorIdentity: Codable, Equatable {
    let seed: UInt64
    let serial: String

    static let generic = SensorIdentity(seed: 0x504F434B45544343, serial: "PC-GENERIC")

    static func current(defaults: UserDefaults = .standard) -> SensorIdentity {
        let key = "pocketCCD.sensorIdentity"
        if let data = defaults.data(forKey: key),
           let identity = try? JSONDecoder().decode(SensorIdentity.self, from: data) {
            return identity
        }

        let seed = UInt64.random(in: 1 ... UInt64.max)
        let identity = SensorIdentity(
            seed: seed,
            serial: String(format: "PC-%08X", UInt32(truncatingIfNeeded: seed))
        )
        if let data = try? JSONEncoder().encode(identity) {
            defaults.set(data, forKey: key)
        }
        return identity
    }
}



import CoreMotion

/// Which way the phone is physically held.
///
/// `UIDevice.orientation` was the obvious source and the wrong one: it stays
/// `.unknown` until notifications have been running for a while, so the first
/// capture after launch silently took the portrait branch. Gravity has no such
/// warm-up and no convention to get backwards — when the phone is on its side,
/// the dominant axis is x.
final class CaptureTilt: @unchecked Sendable {
    static let shared = CaptureTilt()

    private let motion = CMMotionManager()
    private let lock = NSLock()
    private var latest: CMAcceleration?

    private init() {}

    /// Call once the camera screen appears. No permission prompt: the
    /// accelerometer is not a protected sensor.
    func start() {
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        motion.accelerometerUpdateInterval = 0.1
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let acceleration = data?.acceleration else { return }
            self?.store(acceleration)
        }
    }

    var latestX: Double { sample()?.x ?? 0 }
    var latestY: Double { sample()?.y ?? -1 }

    private func sample() -> CMAcceleration? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private func store(_ acceleration: CMAcceleration) {
        lock.lock()
        latest = acceleration
        lock.unlock()
    }

    /// Half of a g of hysteresis keeps a hand-held shot from flipping branches
    /// between frames, and a missing sample falls back to portrait because that
    /// is the orientation the screen is locked to.
    var isLandscape: Bool {
        Self.isLandscape(x: latestX, y: latestY)
    }

    /// Which way round the landscape hold is. The two landscape holds are 180°
    /// apart in the sensor buffer: one is already upright, the other is upside
    /// down, so they cannot share one rule.
    var landscapeTurnsOver: Bool {
        latestX > 0
    }

    /// Pure decision so it can be tested without a device.
    static func isLandscape(x: Double, y: Double) -> Bool {
        abs(x) > abs(y) + 0.2
    }

    /// Target `AVCaptureConnection.videoRotationAngle` (iOS 17+) for the phone's
    /// physical orientation, accounting for front vs back sensor mounting.
    func videoRotationAngle(isFrontCamera: Bool) -> CGFloat {
        Self.videoRotationAngle(x: latestX, y: latestY, isFrontCamera: isFrontCamera)
    }

    static func videoRotationAngle(x: Double, y: Double, isFrontCamera: Bool) -> CGFloat {
        if isLandscape(x: x, y: y) {
            // x < 0: charging port on right (landscapeLeft); x > 0: charging port on left (landscapeRight).
            if x < 0 {
                return isFrontCamera ? 180 : 0
            } else {
                return isFrontCamera ? 0 : 180
            }
        }
        return y > 0.2 ? 270 : 90
    }
}

extension UIImage.Orientation {
    /// `true` when honouring this tag swaps width and height.
    var swapsAxes: Bool {
        switch self {
        case .left, .right, .leftMirrored, .rightMirrored: true
        default: false
        }
    }
}

extension UIImage {
    /// Pixels redrawn so the picture still looks the way it looked before, but
    /// no longer depends on the orientation tag to do it.
    func withOrientationBakedIn() -> UIImage {
        guard imageOrientation != .up, let cgImage else { return self }
        let swapped = imageOrientation.swapsAxes
        let pixels = CGSize(
            width: swapped ? CGFloat(cgImage.height) : CGFloat(cgImage.width),
            height: swapped ? CGFloat(cgImage.width) : CGFloat(cgImage.height)
        )
        let points = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: points, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: points))
        }
    }

    /// The same picture, turned over. Used for the landscape hold whose sensor
    /// buffer comes out upside down.
    func rotated180() -> UIImage {
        guard let cgImage else { return self }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(
            size: CGSize(width: width / scale, height: height / scale), format: format
        ).image { context in
            let cg = context.cgContext
            cg.translateBy(x: width / scale, y: height / scale)
            cg.rotate(by: .pi)
            UIImage(cgImage: cgImage, scale: scale, orientation: .up)
                .draw(in: CGRect(x: 0, y: 0, width: width / scale, height: height / scale))
        }
    }

    /// Pixels untouched, orientation tag dropped.
    func withoutOrientationTag() -> UIImage {
        guard let cgImage else { return self }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    /// The single geometry decision every export shares: landscape keeps the
    /// pixels the sensor already had upright, portrait bakes its tag in.
    ///
    /// AVFoundation hands back a sensor-oriented buffer plus a tag. Keeping both
    /// means every consumer has to agree on the same metadata, and it puts the
    /// date stamp in pixel space, so a tagged image gets its stamp rotated with
    /// the picture. Baking leaves one interpretation: the pixels are the photo.
    ///
    /// `UIImage.jpegData` and the EXIF writer then record orientation 1, so the
    /// app, Photos, Messages and Instagram all show the same thing.
    func exportReady() -> UIImage {
        let landscape = CaptureTilt.shared.isLandscape
        let turnsOver = CaptureTilt.shared.landscapeTurnsOver
        #if DEBUG
        // Written so a device test can be read back without a console: the
        // orientation rule depends on one physical convention we cannot see
        // from a JPEG.
        UserDefaults.standard.set(
            String(
                format: "x=%.2f y=%.2f landscape=%@ turns=%@",
                CaptureTilt.shared.latestX,
                CaptureTilt.shared.latestY,
                landscape ? "Y" : "N",
                turnsOver ? "Y" : "N"
            ),
            forKey: "debug.lastOrientation"
        )
        #endif
        return exportReady(landscape: landscape, turnsOver: turnsOver)
    }

    /// Injectable form, so the geometry rule can be tested without a device.
    func exportReady(landscape: Bool, turnsOver: Bool = false) -> UIImage {
        guard landscape else { return withOrientationBakedIn() }
        return (turnsOver ? rotated180() : self).withoutOrientationTag()
    }

    /// Shared mapping used by Vision and Core Image so both work in the same
    /// upright coordinate space.
    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}


/// Where the photo actually lands inside the camera screen.
///
/// The preview used to be centred on the whole screen while the corner brackets
/// were laid out by the chrome's `VStack`, so the two disagreed by tens of
/// points and the brackets sat inside the photo at the top and outside it at the
/// bottom. Both sides now derive their rect from this one function.
enum ViewfinderGeometry {
    /// Largest rect with the camera's portrait aspect (`width / height`) that
    /// fits inside `slot`, pinned to its top. The leftover height is filled
    /// with panel colour underneath, so the photo meets the status bar instead
    /// of leaving a black gap above it.
    static func fittedRect(in slot: CGRect, aspect: CGFloat) -> CGRect {
        guard slot.width > 1, slot.height > 1, aspect > 0 else { return slot }
        let height = min(slot.height, slot.width / aspect)
        let width = height * aspect
        return CGRect(
            x: slot.midX - width / 2,
            y: slot.minY,
            width: width,
            height: height
        )
    }
}
