import AVFoundation
import Foundation

/// The three things a returning user expects the camera to still know: which
/// body, whether the flash is on, and which lens is fitted.
///
/// They are written on every change and read once at launch. Before this the
/// view held the body and flash in `@State`, so closing the app silently reset
/// the camera to Pocket A7 with automatic flash — the opposite of the “open it
/// and keep shooting” promise the product is built on.
enum ShootingIdentity {
    static let lookKey = "pocketCCD.identity.look"
    static let flashKey = "pocketCCD.identity.flash"
    static let lensKey = "pocketCCD.identity.lens"

    static let defaultLook = CCDLook.amber
    static let defaultFlash = AVCaptureDevice.FlashMode.auto
    static let defaultLens = CameraLens.wide

    // MARK: - Reading

    static func look(in defaults: UserDefaults = .standard) -> CCDLook {
        defaults.string(forKey: lookKey).flatMap(CCDLook.init(rawValue:)) ?? defaultLook
    }

    static func flash(in defaults: UserDefaults = .standard) -> AVCaptureDevice.FlashMode {
        // `integer(forKey:)` returns 0 for a missing key, which is a real value
        // (`.off`); the object check separates “never stored” from “stored off”.
        guard defaults.object(forKey: flashKey) != nil else { return defaultFlash }
        return AVCaptureDevice.FlashMode(rawValue: defaults.integer(forKey: flashKey)) ?? defaultFlash
    }

    static func lens(in defaults: UserDefaults = .standard) -> CameraLens {
        defaults.string(forKey: lensKey).flatMap(CameraLens.init(rawValue:)) ?? defaultLens
    }

    // MARK: - Writing

    static func remember(look: CCDLook, in defaults: UserDefaults = .standard) {
        defaults.set(look.rawValue, forKey: lookKey)
    }

    static func remember(flash: AVCaptureDevice.FlashMode, in defaults: UserDefaults = .standard) {
        defaults.set(flash.rawValue, forKey: flashKey)
    }

    static func remember(lens: CameraLens, in defaults: UserDefaults = .standard) {
        defaults.set(lens.rawValue, forKey: lensKey)
    }

    // MARK: - Presentation

    /// True while the stored identity still matches the factory arrangement.
    /// Someone who never touched the camera should not get a launch hint.
    static func isFactoryDefault(
        look: CCDLook,
        flash: AVCaptureDevice.FlashMode,
        lens: CameraLens
    ) -> Bool {
        look == defaultLook && flash == defaultFlash && lens == defaultLens
    }

    /// A short brand-token line for the resume hint, e.g. `A8 · FLASH · 1×`.
    /// The camera names and ratios are brand tokens and stay untranslated.
    static func summary(
        look: CCDLook,
        flash: AVCaptureDevice.FlashMode,
        lens: CameraLens
    ) -> String {
        "\(look.shortName) · \(flashToken(flash)) · \(lens.rawValue)"
    }

    /// Keep the compact camera control: one tap advances, no modal picker.
    static func nextFlash(after mode: AVCaptureDevice.FlashMode) -> AVCaptureDevice.FlashMode {
        switch mode {
        case .on: .off
        case .off: .auto
        default: .on
        }
    }

    static func flashToken(_ flash: AVCaptureDevice.FlashMode) -> String {
        switch flash {
        case .on: "FLASH"
        case .off: "NO FLASH"
        case .auto: "AUTO"
        @unknown default: "AUTO"
        }
    }
}
