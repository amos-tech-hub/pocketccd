import CoreMedia
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import PocketCCD

/// Fixture paths used by the render checks. Derived from this file so the
/// suite works on any checkout, not just /Users/adam/...
private let pocketCCDRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

private func isolatedRollDefaults(for root: URL) -> UserDefaults {
    UserDefaults(suiteName: "PocketCCD.RollTests." + root.lastPathComponent)!
}

@Suite("Product access")
struct ProductAccessTests {
    @Test("Free cameras stay available without a purchase", arguments: [CCDLook.amber, .party])
    func freeCameraIsAvailable(look: CCDLook) {
        #expect(ProductAccess.canUse(look, isFullUnlocked: false))
    }

    @Test("Paid cameras are locked before Full purchase", arguments: [CCDLook.chrome, .night, .mono, .negative])
    func paidCamerasAreLocked(look: CCDLook) {
        #expect(!ProductAccess.canUse(look, isFullUnlocked: false))
    }

    @Test("Full purchase unlocks every camera", arguments: CCDLook.allCases)
    func fullUnlockIncludesEveryCamera(look: CCDLook) {
        #expect(ProductAccess.canUse(look, isFullUnlocked: true))
    }

}

@Suite("Entitlement policy")
struct EntitlementPolicyTests {
    @Test("A verified purchase unlocks regardless of cache")
    func activeUnlocks() {
        #expect(EntitlementPolicy.isUnlocked(evidence: .active, availability: .unreachable, cached: false))
        #expect(EntitlementPolicy.isUnlocked(evidence: .active, availability: .reachable, cached: false))
    }

    @Test("An explicit revocation wins over a warm cache")
    func revokedLocks() {
        #expect(!EntitlementPolicy.isUnlocked(evidence: .revoked, availability: .unreachable, cached: true))
        #expect(!EntitlementPolicy.isUnlocked(evidence: .revoked, availability: .reachable, cached: true))
    }

    @Test("An unreachable store keeps the last known state")
    func unreachableKeepsCache() {
        #expect(EntitlementPolicy.isUnlocked(evidence: .none, availability: .unreachable, cached: true))
        #expect(!EntitlementPolicy.isUnlocked(evidence: .none, availability: .unreachable, cached: false))
    }

    @Test("A reachable store with no purchase record locks")
    func reachableNoRecordLocks() {
        #expect(!EntitlementPolicy.isUnlocked(evidence: .none, availability: .reachable, cached: true))
    }
}

@Suite("Imaging Quality Gates")
struct ImagingQualityGateTests {
    @Test("Every look produces monotonic tone progression without clipping dips", arguments: CCDLook.allCases)
    func toneProgressionIsMonotonic(look: CCDLook) throws {
        var previousLuma = -0.001
        for step in 0...20 {
            let value = CGFloat(step) / 20.0
            let patch = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                UIColor(white: value, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            let rendered = try #require(look.render(patch, dateStamp: false, sensor: .generic))
            guard let cg = rendered.cgImage,
                  let provider = cg.dataProvider,
                  let data = provider.data as Data? else { continue }
            let r = Double(data[0]) / 255.0
            let g = Double(data[1]) / 255.0
            let b = Double(data[2]) / 255.0
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            #expect(luma >= previousLuma - 0.005, "Luma non-monotonic on \(look.shortName) at input \(value)")
            #expect(luma <= Double(look.whiteClamp) + 0.04, "White clamp breached on \(look.shortName)")
            previousLuma = luma
        }
    }

    @Test("Near-black tinted shadows never explode into neon purple/blue blotches", arguments: CCDLook.allCases)
    func noShadowChromaExplosion(look: CCDLook) throws {
        // Simulates a noisy dark shadow pixel (tiny blue/red bias near black)
        let patch = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor(red: 0.015, green: 0.008, blue: 0.045, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let rendered = try #require(look.render(patch, dateStamp: false, sensor: .generic))
        let cg = try #require(rendered.cgImage)
        let data = try #require(cg.dataProvider?.data as Data?)
        let centerOffset = (cg.height / 2) * cg.bytesPerRow + (cg.width / 2) * 4
        let r = Double(data[centerOffset]) / 255.0
        let g = Double(data[centerOffset + 1]) / 255.0
        let b = Double(data[centerOffset + 2]) / 255.0
        let chroma = max(r, max(g, b)) - min(r, min(g, b))
        #expect(chroma < 0.08, "Shadow chroma exploded on \(look.shortName): rgb=(\(r), \(g), \(b))")
    }

    @Test("Flash shutter clamp caps only formats that can reach 1/45s")
    func flashShutterClampEnforcesMinimum() {
        let target = CMTime(value: 1, timescale: 45)
        // The production rule, not a copy of `min` computed inside the test.
        #expect(CameraController.flashExposureLimit(formatMax: CMTime(value: 1, timescale: 30)) == target)
        #expect(CameraController.flashExposureLimit(formatMax: target) == target)
        // A format whose longest exposure is shorter than 1/45 s cannot be capped there.
        #expect(CameraController.flashExposureLimit(formatMax: CMTime(value: 1, timescale: 60)) == nil)
    }

    @Test("Every camera body has valid persona and unique shortName", arguments: CCDLook.allCases)
    func cameraBodyInvariants(look: CCDLook) {
        #expect(!look.shortName.isEmpty)
        #expect(look.stripCaption.count <= 12)
        #expect(look.personality.key.split(separator: " ").count == 2)
        #expect(look.personality.key.count <= 12)
    }
}

@Suite("Camera copy")
struct CameraCopyTests {
    @Test("N2 is sold as the no-flash night camera, not a second party camera")
    func nightIsNotParty() {
        // `key` is the source English string, so this guards the copy without
        // depending on the simulator's language.
        let copy = [CCDLook.night.summary.key, CCDLook.night.proofMark].joined(separator: " ")
        #expect(!copy.lowercased().contains("party"), "N2 still reads as a party camera: \(copy)")
        #expect(copy.lowercased().contains("no flash"), "N2 should name the no-flash night look: \(copy)")
    }

    @Test("A8 stays the only camera that sells the party light")
    func partyLightBelongsToA8() {
        #expect(CCDLook.party.summary.key.lowercased().contains("flash"))
        #expect(CCDLook.party.shortName == "A8")
        #expect(CCDLook.party.isFree)
    }

    @Test("Strip captions are unique and short enough for four cards")
    func stripCaptionsFit() {
        let captions = CCDLook.allCases.map(\.stripCaption)
        #expect(Set(captions).count == captions.count, "duplicate caption: \(captions)")
        #expect(captions.allSatisfy { $0.count <= 12 }, "caption too long for the four-card strip: \(captions)")
    }

    @Test("Each camera carries a two-word name next to its model code")
    func personalitiesAreShortAndDistinct() {
        // `key` is the source English string, so this is locale-independent.
        let names = CCDLook.allCases.map(\.personality.key)
        #expect(names == ["Warm 2003", "Party Flash", "Cold Sharp", "Green Grain", "Silver Mono", "Color Film"])
        #expect(Set(names).count == names.count, "duplicate camera name: \(names)")
        #expect(names.allSatisfy { $0.count <= 12 }, "name too long for one strip card: \(names)")
    }
}

@Suite("Imported photo dates")
struct CaptureDateTests {
    @Test("The date stamp uses the photo's EXIF capture date")
    func usesExifDate() throws {
        let data = try Self.jpegData(exifDate: "2019:07:04 21:15:00")
        let date = CameraScreen.captureDate(in: data)
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute], from: date
        )
        #expect(parts.year == 2019)
        #expect(parts.month == 7)
        #expect(parts.day == 4)
        #expect(parts.hour == 21)
        #expect(parts.minute == 15)
    }

    @Test("Missing EXIF data falls back to now")
    func fallsBackToNow() throws {
        let data = try Self.jpegData(exifDate: nil)
        let date = CameraScreen.captureDate(in: data)
        #expect(abs(date.timeIntervalSinceNow) < 5)
    }

    @Test("EXIF distinguishes fired and suppressed automatic flash")
    func detectsActualFlash() throws {
        #expect(CameraScreen.flashFired(in: try Self.jpegData(exifDate: nil, flash: 0x19)))
        #expect(!CameraScreen.flashFired(in: try Self.jpegData(exifDate: nil, flash: 0x18)))
        #expect(!CameraScreen.flashFired(in: try Self.jpegData(exifDate: nil)))
    }

    private static func jpegData(exifDate: String?, flash: Int? = nil) throws -> Data {
        struct EncodingFailed: Error {}
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        guard let cgImage = image.cgImage else { throw EncodingFailed() }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw EncodingFailed() }
        var properties: [CFString: Any] = [:]
        var exif: [CFString: Any] = [:]
        if let exifDate {
            exif[kCGImagePropertyExifDateTimeOriginal] = exifDate
        }
        if let flash {
            exif[kCGImagePropertyExifFlash] = flash
        }
        if !exif.isEmpty {
            properties[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EncodingFailed() }
        return buffer as Data
    }
}

@Suite("Localization coverage")
struct LocalizationCoverageTests {
    @Test("Simplified Chinese covers every English string")
    func zhHansCoversEveryString() throws {
        try expectFullCoverage(for: "zh-Hans")
    }

    @Test("Traditional Chinese covers every English string")
    func zhHantCoversEveryString() throws {
        try expectFullCoverage(for: "zh-Hant")
    }

    private func expectFullCoverage(for localization: String) throws {
        let base = try Self.strings(for: "en")
        let translated = try Self.strings(for: localization)
        let missing = base.keys
            .filter { (translated[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted()
        #expect(base.count > 100, "English table looks empty")
        #expect(missing.isEmpty, "Missing \(localization): \(missing.prefix(8))")
    }

    private static func strings(for localization: String) throws -> [String: String] {
        struct MissingTable: Error { let localization: String }
        guard let path = Bundle.main.path(
            forResource: "Localizable", ofType: "strings",
            inDirectory: nil, forLocalization: localization
        ), let table = NSDictionary(contentsOfFile: path) as? [String: String] else {
            throw MissingTable(localization: localization)
        }
        return table
    }
}

@Suite("Pocket Roll exports")
struct PocketRollExportTests {
    @Test("Square contact sheet renders five photos")
    @MainActor
    func squareContactSheetRendersFivePhotos() throws {
        let colors: [UIColor] = [.red, .green, .blue, .yellow, .magenta]
        let images = colors.map { color in
            UIGraphicsImageRenderer(size: CGSize(width: 120, height: 90)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
            }
        }

        let result = try #require(ContactSheetRenderer.render(
            images: images,
            entries: [],
            format: .square
        ))

        #expect(result.size == CGSize(width: 2160, height: 2160))
        #expect((result.pngData()?.count ?? 0) > 10_000)
    }

    @Test("Five-photo export fills every corner without overlapping")
    func fivePhotoLayoutIsComplete() throws {
        let rects = ContactSheetRenderer.layoutRects(count: 5, format: .square)
        #expect(rects.count == 5)

        let content = CGRect(x: 54, y: 150, width: 2160 - 108, height: 2160 - 150 - 54)
        #expect(abs(rects.map(\.minX).min()! - content.minX) < 0.01)
        #expect(abs(rects.map(\.maxX).max()! - content.maxX) < 0.01)
        #expect(abs(rects.map(\.minY).min()! - content.minY) < 0.01)
        #expect(abs(rects.map(\.maxY).max()! - content.maxY) < 0.01)

        for leftIndex in rects.indices {
            for rightIndex in rects.indices where leftIndex < rightIndex {
                #expect(!rects[leftIndex].intersects(rects[rightIndex]))
            }
        }
    }

    @Test("Every preset renders at its platform size", arguments: ExportPreset.allCases)
    @MainActor
    func presetSizes(preset: ExportPreset) throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 90)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        }
        let sheet = try #require(ContactSheetRenderer.render(images: [image], entries: [], format: preset))
        #expect(sheet.size == preset.size)
    }

    @Test("Export presets keep content inside each platform's safe area")
    func presetSafeAreas() {
        #expect(ExportPreset.feed.size == CGSize(width: 1080, height: 1350))

        let story = ContactSheetRenderer.layoutRects(count: 9, format: .story)
        #expect((story.map(\.minY).min() ?? 0) >= 250, "IG Story header sits under the account row")
        #expect((story.map(\.maxY).max() ?? 0) <= 1920 - 340, "IG Story grid sits under the reply bar")

        let tiktok = ContactSheetRenderer.layoutRects(count: 9, format: .tiktok)
        #expect((tiktok.map(\.minY).min() ?? 0) >= 180)
        #expect((tiktok.map(\.maxY).max() ?? 0) <= 1920 - 400, "TikTok caption bar covers the last row")

        let feed = ContactSheetRenderer.layoutRects(count: 9, format: .feed)
        #expect((feed.map(\.maxY).max() ?? 0) <= 1350 - 34)
    }
}

@Suite("Capture framing")
struct CaptureFramingTests {
    @Test("Four by three becomes three by four for portrait input")
    func portraitFourThreeCrop() {
        let crop = CaptureAspectRatio.fourThree.cropRect(
            in: CGRect(x: 0, y: 0, width: 3024, height: 4032)
        )
        #expect(abs((crop.width / crop.height) - 0.75) < 0.001)
        #expect(crop == CGRect(x: 0, y: 0, width: 3024, height: 4032))
    }

    @Test("Four by three stays four by three for landscape input")
    func landscapeFourThreeCrop() {
        let crop = CaptureAspectRatio.fourThree.cropRect(
            in: CGRect(x: 0, y: 0, width: 4032, height: 3024)
        )
        #expect(abs((crop.width / crop.height) - (4.0 / 3.0)) < 0.001)
        #expect(crop == CGRect(x: 0, y: 0, width: 4032, height: 3024))
    }
}

@Suite("CCD rendering")
struct CCDRenderingTests {
    @Test("Every aspect ratio exports at the selected geometry", arguments: CaptureAspectRatio.allCases)
    @MainActor
    func exportsSelectedGeometry(aspectRatio: CaptureAspectRatio) throws {
        let source = Self.testCard(size: CGSize(width: 480, height: 640))
        let result = try #require(CCDLook.amber.render(
            source,
            dateStamp: false,
            aspectRatio: aspectRatio,
            sensor: .generic
        ))

        let ratio = result.size.width / result.size.height
        #expect(abs(ratio - aspectRatio.portraitValue) < 0.002)
        #expect((result.jpegData(compressionQuality: 0.9)?.count ?? 0) > 5_000)
    }

    @Test("Every CCD camera produces a distinct JPEG recipe")
    @MainActor
    func cameraRecipesAreDistinct() throws {
        let source = Self.testCard(size: CGSize(width: 360, height: 480))
        let outputs = try CCDLook.allCases.map { look in
            let image = try #require(look.render(
                source,
                dateStamp: false,
                aspectRatio: .fourThree,
                sensor: .generic
            ))
            return try #require(image.jpegData(compressionQuality: 0.92))
        }

        #expect(Set(outputs.map(\.hashValue)).count == CCDLook.allCases.count)
    }

    @MainActor
    private static func testCard(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor(red: 0.12, green: 0.18, blue: 0.22, alpha: 1).setFill()
            context.fill(bounds)
            UIColor(red: 0.96, green: 0.72, blue: 0.48, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width * 0.5, height: size.height * 0.5))
            UIColor.white.setFill()
            context.fill(CGRect(x: size.width * 0.5, y: 0, width: size.width * 0.5, height: size.height * 0.25))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.75, width: size.width, height: size.height * 0.25))
        }
    }
}

@Suite("Date stamp rendering")
struct DateStampRenderingTests {
    @Test("The burned date stamp keeps the photo's pixel dimensions")
    @MainActor
    func dateStampKeepsPixelDimensions() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 400, height: 300), format: format
        ).image { context in
            UIColor(red: 0.65, green: 0.45, blue: 0.3, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let input = try #require(source.cgImage.map { UIImage(cgImage: $0, scale: 1, orientation: .up) })

        let plain = try #require(CCDLook.amber.render(
            input, dateStamp: false, aspectRatio: .fourThree, sensor: .generic
        ))
        let stamped = try #require(CCDLook.amber.render(
            input, dateStamp: true, aspectRatio: .fourThree, sensor: .generic
        ))

        #expect(plain.cgImage?.width == 400)
        #expect(stamped.cgImage?.width == 400, "date stamp upscaled the photo to \(stamped.cgImage?.width ?? -1) px")
        #expect(stamped.cgImage?.height == 300)
    }

    @Test("Date stamp uses the Gregorian calendar")
    func dateStampIsGregorian() {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 5
        components.hour = 12
        let date = Calendar(identifier: .gregorian).date(from: components)!
        #expect(PocketDateStamp.text(for: date) == "05 11 ’26")
    }
}

@Suite("Highlight protection")
struct HighlightProtectionTests {
    @Test("A white card never reaches clipping", arguments: CCDLook.allCases)
    @MainActor
    func whiteCardDoesNotClip(look: CCDLook) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let white = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        }
        let rendered = try #require(look.render(
            white, dateStamp: false, aspectRatio: .fourThree, sensor: .generic
        ))
        let cgImage = try #require(rendered.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let bitmap = CGContext(
            data: &pixels,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let context = try #require(bitmap)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        // Ignore the alpha channel; the JPEG path drops it anyway.
        let rgbIndices = stride(from: 0, to: pixels.count, by: 4).flatMap { [$0, $0 + 1, $0 + 2] }
        let peak = rgbIndices.map { Int(pixels[$0]) }.max() ?? 255
        let center = (cgImage.height / 2) * cgImage.width * 4 + (cgImage.width / 2) * 4
        print("PEAK \(look.shortName) \(peak) center=\(pixels[center]),\(pixels[center+1]),\(pixels[center+2]) size=\(cgImage.width)x\(cgImage.height)")
        #expect(peak <= 252, "\(look.shortName) produced \(peak) on a white card")
    }
}

@Suite("Daylight cast")
struct DaylightCastTests {
    /// The A7 recipe was tuned on night flash frames. Daylight samples on
    /// 2026-11-15 measured midtone R/B 2.0–3.1 (native camera: 1.08), which read
    /// as a yellow filter and clipped skin in red. A neutral card through the
    /// recipe must stay warm but inside a photographable range.
    @Test("Amber keeps a neutral card's midtones warm, not jaundiced")
    @MainActor
    func amberCastStaysPlausible() throws {
        let rgb = try Self.renderNeutralCard(tone: 0.5, look: .amber)
        let ratio = Double(rgb.0) / max(Double(rgb.2), 1)
        // In the app's CIContext (extended linear working space) a 50% card
        // renders R/B 1.23; the old 4700/+18 recipe rendered 1.44. Keep a
        // window tight enough to catch a regression back to jaundice.
        #expect(ratio > 1.15, "cast drifted neutral: R/B \(ratio)")
        #expect(ratio < 1.35, "cast too strong for daylight: R/B \(ratio)")
    }

    @Test("Amber does not lift a midtone card into highlight clipping")
    @MainActor
    func amberDoesNotInflateMidtones() throws {
        let rgb = try Self.renderNeutralCard(tone: 0.5, look: .amber)
        let luma = 0.299 * rgb.0 + 0.587 * rgb.1 + 0.114 * rgb.2
        #expect(luma < 0.55 * 255, "midtone card pushed to \(luma) luma")
        #expect(luma > 0.42 * 255, "midtone card crushed to \(luma) luma")
    }

    @MainActor
    private static func renderNeutralCard(tone: CGFloat, look: CCDLook) throws -> (Double, Double, Double) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let card = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 640), format: format).image { context in
            UIColor(white: tone, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
        }
        let rendered = try #require(look.render(
            card, dateStamp: false, aspectRatio: .square, sensor: .generic
        ))
        let cgImage = try #require(rendered.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let bitmap = try #require(CGContext(
            data: &pixels,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        // Sample a 32 px block at the center: the vignette-free middle is what
        // carries skin and clothing tone.
        var sums = (0.0, 0.0, 0.0)
        var count = 0.0
        let cx = cgImage.width / 2, cy = cgImage.height / 2
        for y in (cy - 16)..<(cy + 16) {
            for x in (cx - 16)..<(cx + 16) {
                let i = (y * cgImage.width + x) * 4
                sums.0 += Double(pixels[i])
                sums.1 += Double(pixels[i + 1])
                sums.2 += Double(pixels[i + 2])
                count += 1
            }
        }
        return (sums.0 / count, sums.1 / count, sums.2 / count)
    }
}


import Testing
import CoreImage

@Suite("Shooting identity")
struct ShootingIdentityTests {
    /// A private suite so a real install's remembered camera is never read or
    /// written by the test run.
    private func store() -> UserDefaults {
        let name = "ShootingIdentityTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test("An untouched install starts at the factory camera")
    func factoryDefaults() {
        let defaults = store()
        #expect(ShootingIdentity.look(in: defaults) == .amber)
        #expect(ShootingIdentity.flash(in: defaults) == .auto)
        #expect(ShootingIdentity.lens(in: defaults) == .wide)
        #expect(ShootingIdentity.isFactoryDefault(look: .amber, flash: .auto, lens: .wide))
    }

    @Test("A stored body, flash state and lens survive a relaunch")
    func roundTrip() {
        let defaults = store()
        ShootingIdentity.remember(look: .party, in: defaults)
        ShootingIdentity.remember(flash: .off, in: defaults)
        ShootingIdentity.remember(lens: .telephoto, in: defaults)

        #expect(ShootingIdentity.look(in: defaults) == .party)
        #expect(ShootingIdentity.flash(in: defaults) == .off)
        #expect(ShootingIdentity.lens(in: defaults) == .telephoto)
        #expect(!ShootingIdentity.isFactoryDefault(look: .party, flash: .off, lens: .telephoto))
    }

    @Test("A deliberately stored off flash is not mistaken for never stored")
    func storedOffFlash() {
        let defaults = store()
        ShootingIdentity.remember(flash: .off, in: defaults)
        #expect(ShootingIdentity.flash(in: defaults) == .off)
    }

    @Test("All three standard flash choices survive relaunch")
    func threeFlashChoices() {
        let defaults = store()
        for mode in [AVCaptureDevice.FlashMode.on, .off, .auto] {
            ShootingIdentity.remember(flash: mode, in: defaults)
            #expect(ShootingIdentity.flash(in: defaults) == mode)
        }
    }

    @Test("An unknown stored value falls back to the factory setting")
    func corruptValue() {
        let defaults = store()
        defaults.set("POCKET Z9", forKey: ShootingIdentity.lookKey)
        #expect(ShootingIdentity.look(in: defaults) == .amber)
    }

    @Test("The resume summary keeps camera tokens untranslated")
    func summary() {
        #expect(ShootingIdentity.summary(look: .party, flash: .on, lens: .wide) == "A8 · FLASH · 1×")
        #expect(ShootingIdentity.summary(look: .chrome, flash: .off, lens: .telephoto) == "C1 · NO FLASH · 3×")
    }
}

@Suite("Original frame archive")
struct OriginalFrameArchiveTests {
    @Test("Nothing is deleted while the archive is under both caps")
    func keepsShortArchive() {
        let refs = [OriginalCaptureRef(name: "a", bytes: 10), OriginalCaptureRef(name: "b", bytes: 10)]
        #expect(OriginalFrameArchive.capturesToDelete(refs, maxBytes: 100, maxCaptures: 10).isEmpty)
    }

    @Test("The oldest captures go first when the count cap is exceeded")
    func dropsOldestForCount() {
        let refs = (1...5).map { OriginalCaptureRef(name: "c\($0)", bytes: 10) }
        #expect(OriginalFrameArchive.capturesToDelete(refs, maxBytes: 1_000, maxCaptures: 3) == ["c1", "c2"])
    }

    @Test("Byte pressure deletes until the archive fits, but never the newest capture")
    func dropsForBytes() {
        let refs = (1...4).map { OriginalCaptureRef(name: "c\($0)", bytes: 100) }
        #expect(OriginalFrameArchive.capturesToDelete(refs, maxBytes: 250, maxCaptures: 10) == ["c1", "c2"])

        let single = [OriginalCaptureRef(name: "only", bytes: 1_000)]
        #expect(OriginalFrameArchive.capturesToDelete(single, maxBytes: 10, maxCaptures: 10).isEmpty)
    }

    @MainActor
    @Test("A JPEG frame is stored with a jpg extension and its real pixel size")
    func jpegPayload() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let data = image.jpegData(compressionQuality: 0.8)!
        #expect(OriginalFrameArchive.fileExtension(for: data) == "jpg")
        // The renderer works in points at the screen scale, so the expectation
        // has to come from the rendered bitmap, not the requested point size.
        let pixelWidth = image.cgImage?.width ?? 0
        let pixelHeight = image.cgImage?.height ?? 0
        #expect(pixelWidth > 0)
        #expect(OriginalFrameArchive.pixelSize(of: data)?.width == pixelWidth)
        #expect(OriginalFrameArchive.pixelSize(of: data)?.height == pixelHeight)
    }
}

import AVFoundation

@Suite("Original frame writing")
struct OriginalFrameWritingTests {
    @MainActor
    private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 12)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        }.jpegData(compressionQuality: 0.7)!
    }

    private func makeArchive() -> (OriginalFrameArchive, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OriginalFrameWritingTests-\(UUID().uuidString)", isDirectory: true)
        return (OriginalFrameArchive(root: root), root)
    }

    @MainActor
    @Test("One shutter press becomes one folder with a manifest and its frames")
    func writesCaptureFolder() async throws {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = OriginalCaptureSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_760_000_000),
            camera: "POCKET A8",
            cameraPosition: "back",
            mode: "flashParty",
            lens: "1×",
            exposureBias: -0.5,
            iso: 100,
            shutterSeconds: 1.0 / 60.0,
            whiteBalanceKelvin: 5_150,
            flashMode: "FLASH"
        )
        let data = jpeg()
        await archive.archive(
            [OriginalCaptureFrame(role: "flash", data: data), OriginalCaptureFrame(role: "flash", data: data)],
            snapshot: snapshot
        )

        let folders = try #require(try? FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(folders.count == 1)

        let folder = root.appendingPathComponent(try #require(folders.first), isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["capture.json", "frame-0-flash.jpg", "frame-1-flash.jpg"])

        let stats = await archive.stats()
        #expect(stats.captures == 1)
        #expect(stats.bytes > Int64(data.count))

        let manifest = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: folder.appendingPathComponent("capture.json"))
            ) as? [String: Any]
        )
        #expect(manifest["camera"] as? String == "POCKET A8")
        #expect(manifest["flashMode"] as? String == "FLASH")
        #expect((manifest["frames"] as? [[String: Any]])?.count == 2)
    }

    @MainActor
    @Test("Clearing removes every stored capture")
    func clearRemovesEverything() async throws {
        let (archive, root) = makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = OriginalCaptureSnapshot(
            capturedAt: .now, camera: "POCKET A7", cameraPosition: "back", mode: "standard",
            lens: "1×", exposureBias: 0, iso: 100, shutterSeconds: 1.0 / 60.0,
            whiteBalanceKelvin: 5_200, flashMode: "AUTO"
        )
        await archive.archive([OriginalCaptureFrame(role: "standard", data: jpeg())], snapshot: snapshot)
        let written = await archive.stats()
        #expect(written.captures == 1)

        await archive.removeAll()
        let cleared = await archive.stats()
        #expect(cleared.captures == 0)
    }
}

@Suite("Storage guard")
struct StorageGuardTests {
    @Test("An unknown volume never blocks the shutter")
    func unknownIsFine() {
        #expect(StorageGuard.level(availableBytes: nil) == .ok)
    }

    @Test("Thresholds separate ok, low and critical")
    func levels() {
        #expect(StorageGuard.level(availableBytes: StorageGuard.criticalBytes - 1) == .critical)
        #expect(StorageGuard.level(availableBytes: StorageGuard.criticalBytes) == .low)
        #expect(StorageGuard.level(availableBytes: StorageGuard.lowBytes - 1) == .low)
        #expect(StorageGuard.level(availableBytes: StorageGuard.lowBytes) == .ok)
    }
}

// MARK: - Real capture fixtures

/// Reads capture folders written by `OriginalFrameArchive`: a `capture.json`
/// plus the untouched frames it lists.
///
/// Real photos are never committed. The reader points at a test-only directory
/// and the suites that need samples are *disabled*, not failed, when it is
/// empty — the synthetic-card suites keep running either way.
enum OriginalsFixtureReader {
    /// Optional per-capture regions in the same folder, normalized to the
    /// frame's own size with a top-left origin. The tuning log's numbers only
    /// mean something measured on the same regions, so a whole-frame p05 can
    /// never stand in for the background.
    struct RegionOfInterest: Decodable, Equatable {
        struct NormalizedRect: Decodable, Equatable {
            let x: Double
            let y: Double
            let width: Double
            let height: Double

            var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
        }

        let background: NormalizedRect?
        let faceLit: NormalizedRect?
    }

    struct Frame {
        let role: String
        let url: URL
        let pixelWidth: Int
        let pixelHeight: Int
    }

    struct Capture {
        let folder: URL
        let capturedAt: Date?
        let camera: String
        let cameraPosition: String
        let mode: String
        let flashMode: String
        let lens: String
        let frames: [Frame]
        /// `nil` when the folder has no `roi.json`: measurements then stay
        /// whole-frame and are reported as such.
        let roi: RegionOfInterest?

        /// The frame that best represents the capture: the flash exposure when
        /// there is one, otherwise the first written frame.
        var primaryFrame: Frame? {
            frames.first { $0.role == "flash" } ?? frames.first
        }
    }

    struct LoadResult {
        let captures: [Capture]
        /// Folders that had a `capture.json` which could not be decoded. These
        /// are reported instead of silently dropped, so a moved or truncated
        /// corpus shows up as a fixture problem rather than a passing run.
        let skipped: [URL]
    }

    enum ReaderError: Error {
        case missingRoot(URL)
    }

    private struct Manifest: Decodable {
        struct Frame: Decodable {
            let role: String
            let fileName: String
            let pixelWidth: Int?
            let pixelHeight: Int?
        }

        let version: Int?
        let capturedAt: Date?
        let camera: String
        let cameraPosition: String?
        let mode: String?
        let lens: String?
        let flashMode: String?
        let frames: [Frame]?
    }

    /// `POCKETCCD_ORIGINALS_DIR` points at a container downloaded out of Xcode;
    /// otherwise the checkout the tests were compiled from.
    static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["POCKETCCD_ORIGINALS_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Research/Samples/Originals", isDirectory: true)
    }

    /// Drives `.enabled(if:)`: an empty directory skips the real-sample suites.
    static var hasSamples: Bool {
        ((try? load(from: defaultRoot).captures.isEmpty) == false)
    }

    static var hasFlashSamples: Bool {
        guard let loaded = try? load(from: defaultRoot) else { return false }
        return !filter(loaded.captures, flashMode: "FLASH").isEmpty
    }

    static func load(from root: URL) throws -> LoadResult {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else {
            throw ReaderError.missingRoot(root)
        }

        // Any depth: users copy either the archive root or the whole
        // "PocketCCD Originals" folder out of the device container.
        var manifests: [URL] = []
        if let walker = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in walker where url.lastPathComponent == "capture.json" {
                manifests.append(url)
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var captures: [Capture] = []
        var skipped: [URL] = []
        for manifestURL in manifests.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(Manifest.self, from: data) else {
                skipped.append(manifestURL)
                continue
            }
            let folder = manifestURL.deletingLastPathComponent()
            var roi: RegionOfInterest?
            let roiURL = folder.appendingPathComponent("roi.json")
            if manager.fileExists(atPath: roiURL.path) {
                guard let roiData = try? Data(contentsOf: roiURL),
                      let decoded = try? JSONDecoder().decode(RegionOfInterest.self, from: roiData) else {
                    // A hand-written ROI that cannot be parsed would silently
                    // downgrade the sample to whole-frame statistics.
                    skipped.append(manifestURL)
                    continue
                }
                roi = decoded
            }
            let frames = (manifest.frames ?? []).compactMap { frame -> Frame? in
                let url = folder.appendingPathComponent(frame.fileName)
                guard manager.fileExists(atPath: url.path) else { return nil }
                return Frame(
                    role: frame.role,
                    url: url,
                    pixelWidth: frame.pixelWidth ?? 0,
                    pixelHeight: frame.pixelHeight ?? 0
                )
            }
            guard !frames.isEmpty else {
                skipped.append(manifestURL)
                continue
            }
            captures.append(Capture(
                folder: folder,
                capturedAt: manifest.capturedAt,
                camera: manifest.camera,
                cameraPosition: manifest.cameraPosition ?? "back",
                mode: manifest.mode ?? "standard",
                flashMode: manifest.flashMode ?? "AUTO",
                lens: manifest.lens ?? "1×",
                frames: frames,
                roi: roi
            ))
        }
        return LoadResult(captures: captures, skipped: skipped)
    }

    /// Exact token match. Brand tokens stay untranslated by design, so
    /// `camera: "POCKET A8"`, `flashMode: "FLASH"`, `mode: "flashParty"`.
    static func filter(
        _ captures: [Capture],
        camera: String? = nil,
        flashMode: String? = nil,
        mode: String? = nil
    ) -> [Capture] {
        captures.filter { capture in
            (camera == nil || capture.camera == camera)
                && (flashMode == nil || capture.flashMode == flashMode)
                && (mode == nil || capture.mode == mode)
        }
    }
}

/// Statistics for a region of a rendered frame. Two uses, deliberately kept
/// apart:
///
/// - whole-frame (`region == nil`) is a sanity signal only. Its p05 is **not**
///   the flash background that `NIGHT_FLASH_TUNING_2026-11-15.md` measures, and
///   must not be compared with that document's "background ≤ 8";
/// - a normalized region (from `roi.json`) is the only form that may be compared
///   with the tuning log: background p05 and lit-cheek R/G are region
///   measurements, and each body needs its own gate.
struct FrameStatistics {
    let meanR: Double
    let meanG: Double
    let meanB: Double
    /// 5th percentile of luma, 0–255, inside the measured region.
    let p05: Int
    let medianLuma: Int
    /// R/G over the brightest decile of the region.
    let litRG: Double
    /// Share of region pixels above `greyFloor`. A p05 alone can be satisfied by
    /// one truly-black corner while the rest of the background sits at a washed
    /// grey; the share is what exposes that.
    let brightShare: Double

    /// Luma above which a pixel counts as "not black". The tuning log's
    /// backgrounds landed at 1–22, so 40 separates a real black from grey wash.
    static let greyFloor: Double = 40

    static func measure(
        _ image: UIImage,
        region: CGRect? = nil,
        maxEdge: CGFloat = 256
    ) -> FrameStatistics? {
        let longest = max(image.size.width, image.size.height)
        guard longest >= 1 else { return nil }
        let scale = min(1, maxEdge / longest)
        let target = CGSize(
            width: max(1, (image.size.width * scale).rounded()),
            height: max(1, (image.size.height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let proxy = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let cgImage = proxy.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // No CTM flip: image rows are top-down, so bitmap row 0 is the frame's
        // top row — the same top-left coordinates `roi.json` is written in.
        // `regionMapping` fails if this ever drifts.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var x0 = 0
        var y0 = 0
        var x1 = width
        var y1 = height
        if let region {
            x0 = min(max(Int((region.minX * CGFloat(width)).rounded(.down)), 0), width - 1)
            y0 = min(max(Int((region.minY * CGFloat(height)).rounded(.down)), 0), height - 1)
            x1 = min(max(Int((region.maxX * CGFloat(width)).rounded(.up)), x0 + 1), width)
            y1 = min(max(Int((region.maxY * CGFloat(height)).rounded(.up)), y0 + 1), height)
        }

        let count = (x1 - x0) * (y1 - y0)
        guard count > 0 else { return nil }

        var lumas = [Double]()
        lumas.reserveCapacity(count)
        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let offset = (y * width + x) * 4
                let r = Double(pixels[offset])
                let g = Double(pixels[offset + 1])
                let b = Double(pixels[offset + 2])
                sumR += r
                sumG += g
                sumB += b
                lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
        }
        let sorted = lumas.sorted()
        func percentile(_ fraction: Double) -> Int {
            let position = min(max(Int(Double(count - 1) * fraction), 0), count - 1)
            return Int(sorted[position].rounded())
        }
        let litIndex = min(max(Int(Double(count - 1) * 0.9), 0), count - 1)
        let litCutoff = sorted[litIndex]

        var litR = 0.0
        var litG = 0.0
        var litCount = 0
        var brightCount = 0
        var regionIndex = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let luma = lumas[regionIndex]
                regionIndex += 1
                if luma > Self.greyFloor { brightCount += 1 }
                guard luma >= litCutoff else { continue }
                let offset = (y * width + x) * 4
                litR += Double(pixels[offset])
                litG += Double(pixels[offset + 1])
                litCount += 1
            }
        }

        return FrameStatistics(
            meanR: sumR / Double(count) / 255,
            meanG: sumG / Double(count) / 255,
            meanB: sumB / Double(count) / 255,
            p05: percentile(0.05),
            medianLuma: percentile(0.5),
            litRG: litCount > 0 ? litR / max(litG, 1) : 0,
            brightShare: Double(brightCount) / Double(count)
        )
    }

    func maxChannelDelta(_ other: FrameStatistics) -> Double {
        max(abs(meanR - other.meanR), abs(meanG - other.meanG), abs(meanB - other.meanB))
    }
}

@Suite("Originals fixture reader")
struct OriginalsFixtureTests {
    private struct Manifest: Encodable {
        struct Frame: Encodable {
            let role: String
            let fileName: String
            let byteCount: Int
            let pixelWidth: Int
            let pixelHeight: Int
        }
        let version: Int
        let capturedAt: Date
        let camera: String
        let cameraPosition: String
        let mode: String
        let lens: String
        let exposureBias: Float
        let iso: Float
        let shutterSeconds: Double
        let whiteBalanceKelvin: Float
        let flashMode: String
        let frames: [Frame]
    }

    private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor(red: 0.7, green: 0.45, blue: 0.35, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }.jpegData(compressionQuality: 0.8)!
    }

    @discardableResult
    private func writeCapture(
        into root: URL,
        name: String,
        camera: String,
        flashMode: String,
        mode: String,
        roles: [String] = ["flash"]
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var frames: [Manifest.Frame] = []
        for (index, role) in roles.enumerated() {
            let fileName = "frame-\(index)-\(role).jpg"
            let data = jpeg()
            try data.write(to: folder.appendingPathComponent(fileName))
            frames.append(Manifest.Frame(
                role: role, fileName: fileName, byteCount: data.count,
                pixelWidth: 40, pixelHeight: 30
            ))
        }
        let manifest = Manifest(
            version: 1,
            capturedAt: Date(timeIntervalSince1970: 1_760_000_000),
            camera: camera,
            cameraPosition: "back",
            mode: mode,
            lens: "1×",
            exposureBias: 0,
            iso: 100,
            shutterSeconds: 1.0 / 60.0,
            whiteBalanceKelvin: 5_150,
            flashMode: flashMode,
            frames: frames
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("capture.json"))
        return folder
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OriginalsFixtureTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("A capture folder becomes one fixture with its frames")
    func readsCapture() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCapture(
            into: root, name: "20261116-210000-abcdef",
            camera: "POCKET A8", flashMode: "FLASH", mode: "flashParty", roles: ["flash", "flash"]
        )

        let result = try OriginalsFixtureReader.load(from: root)
        #expect(result.skipped.isEmpty)
        let capture = try #require(result.captures.first)
        #expect(result.captures.count == 1)
        #expect(capture.camera == "POCKET A8")
        #expect(capture.flashMode == "FLASH")
        #expect(capture.mode == "flashParty")
        #expect(capture.frames.count == 2)
        #expect(capture.primaryFrame?.role == "flash")
        #expect(capture.frames.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @Test("Samples filter by body, flash state and mode")
    func filters() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCapture(into: root, name: "a8-flash", camera: "POCKET A8", flashMode: "FLASH", mode: "flashParty")
        try writeCapture(into: root, name: "a7-nf", camera: "POCKET A7", flashMode: "NO FLASH", mode: "standard")
        try writeCapture(into: root, name: "a8-auto", camera: "POCKET A8", flashMode: "AUTO", mode: "flashPair")

        let captures = try OriginalsFixtureReader.load(from: root).captures
        #expect(captures.count == 3)
        #expect(OriginalsFixtureReader.filter(captures, camera: "POCKET A8").count == 2)
        #expect(OriginalsFixtureReader.filter(captures, flashMode: "FLASH").count == 1)
        #expect(OriginalsFixtureReader.filter(captures, mode: "standard").count == 1)
        #expect(OriginalsFixtureReader.filter(
            captures, camera: "POCKET A8", flashMode: "AUTO"
        ).count == 1)
        #expect(OriginalsFixtureReader.filter(captures, camera: "POCKET C1").isEmpty)
    }

    @Test("A truncated manifest is reported, a stray image is ignored")
    func reportsBadManifests() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeCapture(into: root, name: "good", camera: "POCKET A8", flashMode: "FLASH", mode: "flashParty")

        let broken = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent("capture.json"))

        let stray = root.appendingPathComponent("stray", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try jpeg().write(to: stray.appendingPathComponent("frame-0-flash.jpg"))

        let result = try OriginalsFixtureReader.load(from: root)
        #expect(result.captures.count == 1)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.lastPathComponent == "capture.json")
    }

    @Test("The device container layout is discovered at any depth")
    func findsNestedContainer() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root
            .appendingPathComponent("PocketCCD Originals", isDirectory: true)
            .appendingPathComponent("20261116-210000-abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try writeCapture(
            into: container.deletingLastPathComponent(), name: "20261116-210000-abcdef",
            camera: "POCKET A8", flashMode: "FLASH", mode: "flashParty"
        )

        let captures = try OriginalsFixtureReader.load(from: root).captures
        #expect(captures.count == 1)
    }

    @Test("An empty directory yields no samples instead of an error")
    func emptyDirectory() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try OriginalsFixtureReader.load(from: root)
        #expect(result.captures.isEmpty)
        #expect(result.skipped.isEmpty)
    }

    @Test("A capture can carry background and lit-face regions")
    func readsRegions() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeCapture(
            into: root, name: "with-roi", camera: "POCKET A8", flashMode: "FLASH", mode: "flashParty"
        )
        let roi = """
        {"background":{"x":0.6,"y":0.1,"width":0.3,"height":0.4},
         "faceLit":{"x":0.3,"y":0.25,"width":0.2,"height":0.3}}
        """
        try Data(roi.utf8).write(to: folder.appendingPathComponent("roi.json"))

        let capture = try #require(try OriginalsFixtureReader.load(from: root).captures.first)
        #expect(capture.roi?.background?.cgRect.width == 0.3)
        #expect(capture.roi?.faceLit?.cgRect.minY == 0.25)
    }

    @Test("An unreadable roi.json fails the folder instead of downgrading it")
    func unreadableRoi() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeCapture(
            into: root, name: "bad-roi", camera: "POCKET A8", flashMode: "FLASH", mode: "flashParty"
        )
        try Data("{ nope".utf8).write(to: folder.appendingPathComponent("roi.json"))

        let result = try OriginalsFixtureReader.load(from: root)
        #expect(result.captures.isEmpty)
        #expect(result.skipped.count == 1)
    }

    @Test("A normalized region maps to the same corner of the frame")
    func regionMapping() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        }
        // A wrong vertical flip would swap these two.
        let top = try #require(FrameStatistics.measure(image, region: CGRect(x: 0, y: 0, width: 1, height: 0.5)))
        let bottom = try #require(FrameStatistics.measure(image, region: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)))
        #expect(top.meanR > 0.9)
        #expect(bottom.meanR < 0.1)
    }

    @Test("A small black patch cannot stand in for a grey background")
    func greyBackgroundIsNotMasked() throws {
        // 10% truly black, 90% washed grey. p05 stays near zero — which is
        // exactly why the background needs its median and bright share too.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor(white: 60.0 / 255.0, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 100))
        }
        let stats = try #require(FrameStatistics.measure(image))
        #expect(stats.p05 < 8)
        #expect(stats.medianLuma > 40)
        #expect(stats.brightShare > 0.8)
    }

    @Test("Statistics separate a lit frame from a black one")
    func statistics() throws {
        func frame(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
        }
        let dark = try #require(FrameStatistics.measure(frame(.black)))
        let warm = try #require(FrameStatistics.measure(frame(
            UIColor(red: 0.63, green: 0.24, blue: 0.10, alpha: 1)
        )))
        #expect(dark.p05 <= 2)
        #expect(warm.litRG > 1.5)
        #expect(warm.p05 > dark.p05)
    }
}

/// Runs only when real captures exist. Import the device container's
/// `Application Support/PocketCCD Originals/` into
/// `Research/Samples/Originals/`, or point `POCKETCCD_ORIGINALS_DIR` at it.
@Suite("Real capture parity", .enabled(if: OriginalsFixtureReader.hasSamples))
struct RealCaptureParityTests {
    private func downscaled(_ image: UIImage, maxEdge: CGFloat = 1600) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge else { return image }
        let scale = maxEdge / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func frameImage(_ capture: OriginalsFixtureReader.Capture) throws -> UIImage {
        let frame = try #require(capture.primaryFrame)
        let data = try Data(contentsOf: frame.url)
        return try #require(UIImage(data: data))
    }

    private func uiImage(_ image: CIImage) -> UIImage? {
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Provisional budget: the synthetic suite proves the two paths agree, this
    /// one proves they still agree on real captures. It is deliberately looser
    /// than the synthetic gate because preview and export run at different
    /// resolutions; tighten it once the corpus stops growing.
    @Test("Preview and saved frame agree on real captures")
    func parityOnRealCaptures() throws {
        let root = OriginalsFixtureReader.defaultRoot
        let result = try OriginalsFixtureReader.load(from: root)
        #expect(result.skipped.isEmpty, "unreadable fixtures: \(result.skipped.map(\.path))")
        #expect(!result.captures.isEmpty)

        var worst = 0.0
        for capture in result.captures {
            let image = downscaled(try frameImage(capture))
            let flash = capture.flashMode == "FLASH" ? 1.0 : 0.0
            let look = try #require(CCDLook(rawValue: capture.camera), "unknown body \(capture.camera)")
            let rendered = try #require(look.render(
                image, dateStamp: false, aspectRatio: .fourThree, sensor: .generic, flash: flash
            ))
            // The live pipeline crops to the capture ratio before the look runs;
            // comparing an uncropped frame against a cropped export would
            // measure the crop, not the recipe.
            let fullCI = try #require(CIImage(image: image))
            let cropped = fullCI.cropped(to: CaptureAspectRatio.fourThree.cropRect(in: fullCI.extent))
            let previewCI = look.livePreview(cropped, sensor: .generic, flashStrength: flash)
            let previewUIImage = try #require(uiImage(previewCI))
            let previewed = try #require(FrameStatistics.measure(previewUIImage))
            let saved = try #require(FrameStatistics.measure(rendered))
            let delta = previewed.maxChannelDelta(saved)
            worst = max(worst, delta)
            print("REAL PARITY \(capture.camera) \(capture.flashMode) \(capture.mode) delta=\(delta)")
        }
        #expect(worst < 0.03, "worst real-capture parity delta \(worst)")
    }

    /// Measurements only. Night-flash skin ratio and black-floor thresholds are
    /// pinned after the corpus exists; until then this prints the numbers they
    /// will be chosen from and asserts only that the pipeline is not degenerate.
    @Test("Night-flash samples are measured", .enabled(if: OriginalsFixtureReader.hasFlashSamples))
    func nightFlashMeasurements() throws {
        let result = try OriginalsFixtureReader.load(from: OriginalsFixtureReader.defaultRoot)
        let night = OriginalsFixtureReader.filter(result.captures, flashMode: "FLASH")
        let samples = night
        #expect(!samples.isEmpty)

        // Bodies are grouped because no threshold is shared between them: the
        // tuning log already showed A7 and A8 land in different places.
        let bodies = Dictionary(grouping: samples, by: \.camera)
        for camera in bodies.keys.sorted() {
            let captures = bodies[camera] ?? []
            print("REAL BODY \(camera) n=\(captures.count)")
            for capture in captures {
                let image = downscaled(try frameImage(capture))
                let whole = try #require(FrameStatistics.measure(image))
                #expect(whole.meanG > 0 && whole.meanG < 1, "degenerate frame in \(capture.folder.lastPathComponent)")
                #expect(whole.litRG.isFinite)

                guard let roi = capture.roi else {
                    // Whole-frame numbers are a sanity signal, not the tuning
                    // log's background: label them so nobody compares them.
                    print(String(
                        format: "REAL FLASH %@ %@ frameP05=%d frameRG=%.2f p50=%d (whole-frame, no roi.json)",
                        capture.camera, capture.mode, whole.p05, whole.litRG, whole.medianLuma
                    ))
                    continue
                }
                let background = roi.background.flatMap {
                    FrameStatistics.measure(image, region: $0.cgRect)
                }
                let face = roi.faceLit.flatMap {
                    FrameStatistics.measure(image, region: $0.cgRect)
                }
                // p05 alone can be met by one black corner; the median and the
                // share above the grey floor are what show a washed background.
                print(String(
                    format: "REAL FLASH %@ %@ bgP05=%@ bgP50=%@ bgBright=%@ faceRG=%@ faceP50=%@ (roi)",
                    capture.camera,
                    capture.mode,
                    background.map { String($0.p05) } ?? "n/a",
                    background.map { String($0.medianLuma) } ?? "n/a",
                    background.map { String(format: "%.0f%%", $0.brightShare * 100) } ?? "n/a",
                    face.map { String(format: "%.2f", $0.litRG) } ?? "n/a",
                    face.map { String($0.medianLuma) } ?? "n/a"
                ))
            }
        }
    }
}

@Suite("Preview parity")
struct PreviewParityTests {
    /// A cheap two-tone card: warm skin-ish left, near-black right. Synthetic
    /// pixels are useless for judging a look, but this suite only compares two
    /// code paths against each other, so the same input on both sides is enough.
    private func card() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900)).image { context in
            UIColor(red: 0.76, green: 0.50, blue: 0.38, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
            UIColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1).setFill()
            context.fill(CGRect(x: 600, y: 0, width: 600, height: 900))
        }
    }

    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { context in
            UIColor(red: r, green: g, blue: b, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        }
    }

    /// A flat patch in an explicit colour space, so the same visual colour can
    /// be fed as sRGB and as Display P3.
    private func patch(_ color: CGColor, space: CGColorSpace, size: Int = 96) -> UIImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return UIImage(cgImage: context.makeImage()!)
    }

    /// Mean, standard deviation and skewness of luma over the centre of a
    /// rendered frame. The centre avoids the vignette, which is a spatial
    /// effect and would read as noise.
    private func lumaStatistics(_ image: UIImage, centre: CGFloat = 0.5) -> (mean: Double, sd: Double, skew: Double) {
        guard let cgImage = image.cgImage else { return (0, 0, 0) }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x0 = Int(CGFloat(width) * (1 - centre) / 2), x1 = width - x0
        let y0 = Int(CGFloat(height) * (1 - centre) / 2), y1 = height - y0
        var values: [Double] = []
        values.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                values.append(0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2]))
            }
        }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let sd = variance.squareRoot()
        let skew = sd > 0 ? values.reduce(0) { $0 + pow(($1 - mean) / sd, 3) } / n : 0
        return (mean, sd, skew)
    }

    /// Float output, not 8-bit: the two paths differ by fractions of a code
    /// value on a flat card, and rounding to UInt8 would report 0 for both.
    private func mean(_ image: CIImage) -> (r: Double, g: Double, b: Double) {
        var pixel = [Float](repeating: 0, count: 4)
        let average = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: image.extent)
        ])!.outputImage!
        CIContext().render(
            average, toBitmap: &pixel, rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf, colorSpace: nil
        )
        return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }

    private func mean(_ image: UIImage) -> (r: Double, g: Double, b: Double) {
        mean(CIImage(image: image)!)
    }

    private func maxDelta(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    @Test("The preview actually runs the flash branch")
    func previewHonoursFlash() {
        let input = CIImage(image: card())!
        let look = CCDLook.party
        let ambient = mean(look.livePreview(input, sensor: .generic, flashStrength: 0))
        let flashed = mean(look.livePreview(input, sensor: .generic, flashStrength: 1))
        print("FLASH effect=\(maxDelta(ambient, flashed))")
        #expect(maxDelta(ambient, flashed) > 0.01)
    }

    @Test("Preview and saved frame agree within the resolution difference")
    func previewMatchesRender() throws {
        let source = card()
        let input = try #require(CIImage(image: source))
        let look = CCDLook.amber
        // Baseline: no flash, no anchor — the case that already matched.
        let basePreview = mean(look.livePreview(input, sensor: .generic))
        let baseRender = mean(try #require(look.render(
            source, dateStamp: false, aspectRatio: .fourThree, sensor: .generic
        )))
        let baseDelta = maxDelta(basePreview, baseRender)

        // Flash on: same two paths, so the gap must stay at the baseline level.
        // A hard-coded `flashStrength: 0` in `livePreview` used to open a wide
        // gap exactly here.
        let flashPreview = mean(look.livePreview(input, sensor: .generic, flashStrength: 1))
        let flashRender = mean(try #require(look.render(
            source, dateStamp: false, aspectRatio: .fourThree, sensor: .generic, flash: 1
        )))
        let flashDelta = maxDelta(flashPreview, flashRender)

        // Measured: base 0.0002 and flash 0.00003 (float16 quantisation), while
        // skipping the flash branch moves the mean by 0.2. 0.01 is far above
        // the noise and far below the regression.
        print("PARITY base=\(baseDelta) flash=\(flashDelta)")
        #expect(flashDelta < 0.01, "flash gap \(flashDelta) vs base \(baseDelta)")
    }

    @Test("The preview respects the roll anchor")
    func previewHonoursAnchor() {
        let input = CIImage(image: card())!
        let look = CCDLook.amber
        let anchor = CaptureColorAnchor(red: 0.15, green: 0.55, blue: 0.55)
        let plain = mean(look.livePreview(input, sensor: .generic))
        let anchored = mean(look.livePreview(
            input, sensor: .generic, colorAnchor: anchor, consistencyStrength: 1
        ))
        // Channel-aware: the anchor's correction can land mostly on green or
        // blue depending on the card, so checking red alone is brittle. The
        // gains are intentionally capped at ±6%, and the skin guard now
        // absorbs part of the warm correction, so the gate is loose: this
        // test exists to catch the anchor becoming a no-op, not to measure it.
        let delta = max(abs(plain.r - anchored.r),
                        max(abs(plain.g - anchored.g), abs(plain.b - anchored.b)))
        #expect(delta > 0.005, "anchor changed nothing: delta \(delta)")
    }

    /// The preview caches its white-balance gain for half a second; a still
    /// render must not. This is the regression that shipped once: a shot taken
    /// right after framing a warm wall inherited that wall's blue lift and the
    /// whole frame came out warm. It was fixed by measuring every still on its
    /// own image; this test is what keeps a future cache from being re-added.
    @Test("A still render measures its own white balance instead of reusing the preview's")
    func stillRenderMeasuresItsOwnWhiteBalance() throws {
        let look = CCDLook.amber
        let cool = solid(0.30, 0.55, 0.88)
        let warm = solid(0.95, 0.66, 0.30)

        let alone = mean(try #require(look.render(
            cool, dateStamp: false, aspectRatio: .fourThree, sensor: .generic
        )))
        // Fill the preview's gain cache with a warm frame, then render the cool
        // one again. If the still path read that cache, the second render would
        // carry the warm frame's blue lift.
        _ = look.livePreview(CIImage(image: warm)!, sensor: .generic, flashStrength: 0)
        let afterWarm = mean(try #require(look.render(
            cool, dateStamp: false, aspectRatio: .fourThree, sensor: .generic
        )))

        let delta = maxDelta(alone, afterWarm)
        print("WHITE BALANCE carry-over delta=\(delta)")
        #expect(delta < 0.02, "still render inherited the preview's gain: \(delta)")
    }

    /// The same visual colour, passed as sRGB and as Display P3, must render
    /// to the same print. A look that reads pixels without honouring their
    /// colour space passes every single-space test and fails exactly here.
    @Test("The same colour renders the same whether it arrives as sRGB or Display P3")
    func colourSpaceInvariance() throws {
        let look = CCDLook.amber
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let base = CGColor(srgbRed: 0.62, green: 0.45, blue: 0.34, alpha: 1)
        let converted = try #require(base.converted(to: p3, intent: .relativeColorimetric, options: nil))

        let fromSRGB = mean(try #require(look.render(
            patch(base, space: srgb), dateStamp: false, aspectRatio: .fourThree, sensor: .generic
        )))
        let fromP3 = mean(try #require(look.render(
            patch(converted, space: p3), dateStamp: false, aspectRatio: .fourThree, sensor: .generic
        )))
        let delta = maxDelta(fromSRGB, fromP3)
        print("COLOUR SPACE delta=\(delta)")
        #expect(delta < 0.02, "sRGB and Display P3 disagree by \(delta)")
    }

    /// Grain must stay a skewed distribution. Matching mean and variance with
    /// symmetric noise is exactly the failure this catches: it looks like film
    /// at a glance and stops behaving like it in the shadows.
    @Test("Grain keeps a skewed, non-uniform distribution")
    func grainKeepsSkew() throws {
        let rendered = try #require(CCDLook.amber.render(
            solid(0.5, 0.5, 0.5), dateStamp: false, aspectRatio: .fourThree, sensor: .generic
        ))
        let stats = lumaStatistics(rendered, centre: 0.4)
        print("GRAIN mean=\(stats.mean) sd=\(stats.sd) skew=\(stats.skew)")
        #expect(stats.sd > 0.004, "no grain at all: sd \(stats.sd)")
        #expect(abs(stats.skew) > 0.05, "grain flattened to symmetric noise: skew \(stats.skew)")
    }
}

@Suite("Pocket Roll index")
struct PocketRollIndexTests {
    @MainActor
    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 18)).image { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 18))
        }
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketRollIndexTests-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    @Test("A frame the index never listed is adopted at the next launch")
    func adoptsOrphanFrame() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // The image write succeeded but the manifest write did not: exactly the
        // state a kill between the two leaves behind.
        let orphan = root.appendingPathComponent("orphan-frame.jpg")
        try #require(image().jpegData(compressionQuality: 0.8)).write(to: orphan)

        let reopened = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        #expect(reopened.entries.count == 1)
        #expect(reopened.entries.first?.fileName == "orphan-frame.jpg")
        #expect(reopened.indexHealth.adopted == 1)
        // The adopted frame must not claim a body the index never recorded.
        #expect(reopened.entries.first?.cameraRawValue == "POCKET ?")
        #expect(reopened.indexHealth.message != nil)

        // Adoption persists, so the next launch is clean and the frame is not
        // adopted twice.
        let third = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        #expect(third.entries.count == 1)
        #expect(third.indexHealth.adopted == 0)
    }

    @MainActor
    @Test("A failed index write keeps the captured frame recoverable")
    func failedManifestWrite() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A directory where the manifest should be makes the write fail while
        // the image file still lands on disk.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manifest.json"),
            withIntermediateDirectories: true
        )

        let store = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        let id = await store.add(
            image(), camera: .amber, mode: .standard,
            createdAt: Date(timeIntervalSince1970: 1_760_000_000), qualityScore: 0.5
        )
        #expect(id != nil)
        #expect(store.entries.count == 1)
        #expect(store.indexHealth.writeFailed)

        try FileManager.default.removeItem(at: root.appendingPathComponent("manifest.json"))
        let reopened = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        #expect(reopened.entries.count == 1)
        #expect(reopened.indexHealth.adopted == 1)
    }

    @MainActor
    @Test("Archived frames are not adopted back into the current roll")
    func archivesAreNotAdopted() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        _ = await store.add(
            image(), camera: .party, mode: .standard,
            createdAt: .now, qualityScore: 0.4
        )
        store.startNewRoll()
        #expect(store.entries.isEmpty)
        #expect(store.archives.count == 1)

        let reopened = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        #expect(reopened.entries.isEmpty)
        #expect(reopened.indexHealth.adopted == 0)
        #expect(reopened.archives.first?.entries.count == 1)
    }

    @MainActor
    @Test("A frame whose file vanished is reported instead of silently dropped")
    func missingFileIsReported() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        _ = await store.add(
            image(), camera: .chrome, mode: .standard,
            createdAt: .now, qualityScore: 0.6
        )
        let fileName = try #require(store.entries.first?.fileName)
        try FileManager.default.removeItem(at: root.appendingPathComponent(fileName))

        let reopened = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        #expect(reopened.entries.isEmpty)
        #expect(reopened.indexHealth.missing == 1)
        #expect(reopened.indexHealth.adopted == 0)
    }

    @MainActor
    @Test("A full roll refuses the frame before the shutter, not after")
    func fullRollRefusesFrames() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        for _ in 0..<store.capacity {
            let id = await store.add(
                image(), camera: .amber, mode: .standard,
                createdAt: .now, qualityScore: 0.5
            )
            #expect(id != nil)
        }
        #expect(store.isFull)
        // The camera screen asks `isFull` first, so the shutter never fires on
        // a full roll; `add` staying nil is the second line of defence.
        let refused = await store.add(
            image(), camera: .amber, mode: .standard,
            createdAt: .now, qualityScore: 0.5
        )
        #expect(refused == nil)
        #expect(store.entries.count == store.capacity)
    }

    @MainActor
    @Test("Peeking the roll anchor does not move it")
    func peekDoesNotDrift() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        #expect(store.peekColorAnchor(for: .amber) == nil)

        let sample = CaptureColorAnchor(red: 0.9, green: 0.5, blue: 0.4)
        _ = store.colorAnchor(for: .amber, sample: sample)
        let first = try #require(store.peekColorAnchor(for: .amber))
        // The live preview reads this 24 times a second; it must not write.
        _ = store.peekColorAnchor(for: .amber)
        let second = try #require(store.peekColorAnchor(for: .amber))
        #expect(first.red == second.red)
        #expect(first.green == second.green)
        #expect(first.blue == second.blue)
    }
}

@Suite("Export orientation")
struct ExportOrientationTests {
    private func tagged(_ orientation: UIImage.Orientation) -> UIImage {
        let cg = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return UIImage(cgImage: cg.cgImage!, scale: 1, orientation: orientation)
    }

    private func pixels(_ image: UIImage) -> CGSize {
        CGSize(width: image.cgImage?.width ?? 0, height: image.cgImage?.height ?? 0)
    }

    @Test("A landscape hold keeps the sensor's upright pixels and drops the portrait tag")
    func landscapeKeepsPixels() {
        let source = tagged(.right)
        let original = pixels(source)
        let exported = source.exportReady(landscape: true)
        #expect(exported.imageOrientation == .up)
        #expect(pixels(exported) == original)
        #expect(exported.size == original)
    }

    @Test("A portrait hold bakes its tag into the pixels")
    func portraitBakesTag() {
        let source = tagged(.right)
        let original = pixels(source)
        let exported = source.exportReady(landscape: false)
        #expect(exported.imageOrientation == .up)
        #expect(exported.size == CGSize(width: original.height, height: original.width))
    }

    @Test("Gravity decides the hold without a warm-up or a convention to flip")
    func gravityDecidesTheHold() {
        // On its side: gravity runs along x.
        #expect(CaptureTilt.isLandscape(x: -0.95, y: 0.2))
        #expect(CaptureTilt.isLandscape(x: 0.9, y: -0.3))
        // Upright: gravity runs along y, and a hand-held wobble must not flip it.
        #expect(!CaptureTilt.isLandscape(x: 0.1, y: -0.99))
        #expect(!CaptureTilt.isLandscape(x: 0.25, y: -0.9))
    }

    @Test("The upside-down landscape hold turns the pixels over")
    func landscapeHalfTurn() {
        // Left half white, right half black: a 180° turn must swap them.
        let source = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
            UIColor.black.setFill()
            context.fill(CGRect(x: 20, y: 0, width: 20, height: 30))
        }
        let turned = source.exportReady(landscape: true, turnsOver: true)
        let kept = source.exportReady(landscape: true, turnsOver: false)
        #expect(turned.size == source.size)
        #expect(kept.size == source.size)
        #expect(luma(turned, atX: 4) < 40, "left side should be the old black half")
        #expect(luma(kept, atX: 4) > 215, "the other hold keeps the old white half")
    }

    private func luma(_ image: UIImage, atX x: CGFloat) -> Int {
        guard let cg = image.cgImage,
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return -1 }
        let y = cg.height / 2
        let offset = y * cg.bytesPerRow + Int(x) * (cg.bitsPerPixel / 8)
        return Int(bytes[offset])
    }

    @Test("An already-upright image is returned untouched, with no redraw")
    func uprightIsANoOp() {
        let source = tagged(.up)
        #expect(source.exportReady(landscape: false) === source)
        #expect(pixels(source.exportReady(landscape: true)) == pixels(source))
    }

    @Test("CaptureTilt computes exact videoRotationAngle for back and front cameras")
    func videoRotationAngleForBothCameras() {
        // Portrait upright (gravity along -y)
        #expect(CaptureTilt.videoRotationAngle(x: 0.05, y: -0.98, isFrontCamera: false) == 90)
        #expect(CaptureTilt.videoRotationAngle(x: 0.05, y: -0.98, isFrontCamera: true) == 90)
        // Portrait upside-down (gravity along +y)
        #expect(CaptureTilt.videoRotationAngle(x: 0.0, y: 0.98, isFrontCamera: false) == 270)
        #expect(CaptureTilt.videoRotationAngle(x: 0.0, y: 0.98, isFrontCamera: true) == 270)
        // Landscape-left (charging port on right, gravity along -x)
        #expect(CaptureTilt.videoRotationAngle(x: -0.95, y: 0.1, isFrontCamera: false) == 0)
        #expect(CaptureTilt.videoRotationAngle(x: -0.95, y: 0.1, isFrontCamera: true) == 180)
        // Landscape-right (charging port on left, gravity along +x)
        #expect(CaptureTilt.videoRotationAngle(x: 0.95, y: -0.1, isFrontCamera: false) == 180)
        #expect(CaptureTilt.videoRotationAngle(x: 0.95, y: -0.1, isFrontCamera: true) == 0)
    }
}

@Suite("Viewfinder geometry")
struct ViewfinderGeometryTests {
    @Test("A tall slot keeps the photo full width and pinned to the top")
    func fullWidthInTallSlot() {
        // iPhone 16 Plus: 430 pt wide, ~585 pt of chrome-free height.
        let rect = ViewfinderGeometry.fittedRect(
            in: CGRect(x: 0, y: 150, width: 430, height: 585),
            aspect: 0.75
        )
        #expect(abs(rect.width - 430) < 0.01)
        #expect(abs(rect.height - 573.33) < 0.01)
        #expect(abs(rect.minY - 150) < 0.01, "the photo starts at the top of the slot")
    }

    @Test("A short slot shrinks the photo instead of letting it slide under the panel")
    func fitsShortSlot() {
        let rect = ViewfinderGeometry.fittedRect(
            in: CGRect(x: 0, y: 100, width: 430, height: 400),
            aspect: 0.75
        )
        #expect(abs(rect.height - 400) < 0.01)
        #expect(abs(rect.width - 300) < 0.01)
        #expect(rect.minY >= 100 && rect.maxY <= 500)
    }

    @Test("An empty slot falls back to the slot itself")
    func emptySlot() {
        let slot = CGRect(x: 0, y: 0, width: 0, height: 0)
        #expect(ViewfinderGeometry.fittedRect(in: slot, aspect: 0.75) == slot)
    }
}

@Suite("A7 red guard")
struct A7RedGuardTests {
    private func patch(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor(red: r, green: g, blue: b, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    private func mean(_ image: UIImage) -> (Double, Double, Double) {
        guard let cg = image.cgImage,
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return (0, 0, 0) }
        var r = 0.0, g = 0.0, b = 0.0
        let count = Double(cg.width * cg.height)
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let o = y * cg.bytesPerRow + x * 4
                r += Double(bytes[o]); g += Double(bytes[o + 1]); b += Double(bytes[o + 2])
            }
        }
        return (r / count, g / count, b / count)
    }

    private func rendered(_ rgb: (CGFloat, CGFloat, CGFloat), look: CCDLook = .amber) -> (Double, Double, Double) {
        guard let out = look.render(patch(rgb.0, rgb.1, rgb.2), dateStamp: false, sensor: .generic) else {
            return (0, 0, 0)
        }
        return mean(out)
    }

    @Test("Flash-lit skin stops at a believable red instead of clipping into orange")
    func flashSkinIsTamed() {
        // The capture a 2003 compact produces for a face 50 cm from the flash.
        let m = rendered((200/255.0, 122/255.0, 108/255.0))
        let ratio = m.0 / max(m.1, 1)
        #expect(ratio < 1.85, "A7 flash skin still reads as orange: R/G \(ratio)")
        #expect(ratio > 1.30, "A7 flash skin lost its warmth: R/G \(ratio)")
    }

    @Test("Indoor and midtone skin stay inside a believable red")
    func indoorSkinStaysBelievable() {
        // The probe that caught the regression: the guard's gate was tuned for
        // linear highlights, so only flash-bright skin was protected and every
        // indoor face rendered at R/G 1.9–2.3. Dark skin in shade still keeps a
        // little more red than a lit cheek, so it gets its own ceiling.
        let samples: [(rgb: (CGFloat, CGFloat, CGFloat), ceiling: Double)] = [
            ((150/255.0, 92/255.0, 78/255.0), 2.10),
            ((140/255.0, 80/255.0, 64/255.0), 2.50),
            ((110/255.0, 62/255.0, 52/255.0), 2.70)
        ]
        for sample in samples {
            for look in [CCDLook.amber, .chrome, .party] {
                let m = rendered(sample.rgb, look: look)
                let ratio = m.0 / max(m.1, 1)
                print(String(format: "SKINVAL \(look) %.0f: R/G %.2f L %.0f", sample.rgb.0*255, ratio, 0.2126*m.0+0.7152*m.1+0.0722*m.2))
                #expect(ratio < sample.ceiling, "\(look) indoor skin still reads as orange: R/G \(ratio)")
                #expect(ratio > 1.15, "\(look) indoor skin lost its warmth: R/G \(ratio)")
            }
        }
    }

    @Test("A sodium lamp keeps most of its yellow")
    func lampKeepsItsColour() {
        let m = rendered((245/255.0, 170/255.0, 60/255.0))
        #expect(m.0 / max(m.1, 1) > 1.20, "the guard bleached a street lamp")
    }

    @Test("Neutral surfaces stay neutral")
    func neutralStaysNeutral() {
        let m = rendered((200/255.0, 200/255.0, 200/255.0))
        #expect(abs(m.0 / max(m.1, 1) - 1.0) < 0.08)
    }

    @Test("A8 stays harsher than A7, but shares the red guard")
    func flashCamerasShareTheGuard() {
        // The guard is no longer A7-only: A8 pushed cheeks orange on flash, so
        // both are guarded — A8 just keeps a higher ceiling.
        let party = rendered((200/255.0, 122/255.0, 108/255.0), look: .party)
        let amber = rendered((200/255.0, 122/255.0, 108/255.0), look: .amber)
        let partyRatio = party.0 / max(party.1, 1)
        let amberRatio = amber.0 / max(amber.1, 1)
        for ratio in [partyRatio, amberRatio] {
            #expect(ratio < 1.85, "flash skin still reads orange: R/G \(ratio)")
            #expect(ratio > 1.20, "flash skin lost its warmth: R/G \(ratio)")
        }
    }
}

@Suite("Scene white balance")
struct SceneWhiteBalanceTests {
    @Test("A red cast lifts blue, capped at 8%")
    func redCastLiftsBlue() {
        let gain = CCDLook.blueGain(red: 0.90, blue: 0.35)
        #expect(gain > 1.0)
        #expect(gain <= 1.08)
    }

    @Test("A blue cast holds blue back, capped at 8%")
    func blueCastHoldsBlue() {
        let gain = CCDLook.blueGain(red: 0.40, blue: 0.80)
        #expect(gain < 1.0)
        #expect(gain >= 0.92)
    }

    @Test("A balanced scene is left alone")
    func balancedSceneIsUntouched() {
        let gain = CCDLook.blueGain(red: 0.62, blue: 0.55)
        #expect(gain == 1.0)
    }

    @Test("Small scene changes do not jump white balance at either threshold",
          arguments: [1.05, 1.60])
    func correctionIsContinuous(threshold: Double) {
        let below = CCDLook.blueGain(red: threshold - 0.0001, blue: 1)
        let above = CCDLook.blueGain(red: threshold + 0.0001, blue: 1)
        #expect(abs(above - below) < 0.001)
    }

    @Test("White balance remains bounded and monotonic across scene casts")
    func correctionIsMonotonic() {
        var previous = 0.92
        for step in 0...400 {
            let gain = CCDLook.blueGain(red: Double(step) / 100, blue: 1)
            #expect(gain.isFinite && gain >= 0.92 && gain <= 1.08)
            #expect(gain >= previous)
            previous = gain
        }
        #expect(CCDLook.blueGain(red: .nan, blue: 1) == 1)
    }

    @Test("A7 stays inside its warm identity after correction")
    func amberIdentitySurvives() {
        let patch = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor(red: 200/255.0, green: 200/255.0, blue: 200/255.0, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        guard let out = CCDLook.amber.render(patch, dateStamp: false, sensor: .generic),
              let cg = out.cgImage,
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return }
        var r = 0.0, b = 0.0
        let n = Double(cg.width * cg.height)
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let o = y * cg.bytesPerRow + x * 4
                r += Double(bytes[o]); b += Double(bytes[o + 2])
            }
        }
        let ratio = (r / n) / max(b / n, 1)
        #expect(ratio > 0.95 && ratio < 1.35, "A7 neutral drifted to R/B \(ratio)")
    }
}

@Suite("Instagram Story handoff")
struct InstagramStoryTests {
    @Test("The handoff URL carries the Meta app ID Instagram now requires")
    func shareURLCarriesAppID() throws {
        let url = try #require(InstagramStoriesSharer.shareURL(appID: "1234567890"))
        #expect(url.absoluteString == "instagram-stories://share?source_application=1234567890")
    }

    @Test("A missing app ID does not blame a missing Instagram")
    func failureCopyIsSpecific() {
        let missingID = InstagramStoriesSharer.Failure.notConfigured.title.key
        let missingApp = InstagramStoriesSharer.Failure.instagramUnavailable.title.key
        #expect(missingID != missingApp)
        #expect(missingID.uppercased().contains("ENABLED"))
        #expect(InstagramStoriesSharer.Failure.imageEncodingFailed.title.key != missingApp)
    }
}

@Suite("Look calibration")
struct LookCalibrationTests {
    private func patch(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: CGFloat = 512) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            UIColor(red: r, green: g, blue: b, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    private func stats(_ image: UIImage) -> (r: Double, g: Double, b: Double, clipped: Double) {
        guard let cg = image.cgImage,
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return (0, 0, 0, 0) }
        var r = 0.0, g = 0.0, b = 0.0, clipped = 0.0
        let n = Double(cg.width * cg.height)
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let o = y * cg.bytesPerRow + x * 4
                let rr = Double(bytes[o]), gg = Double(bytes[o + 1]), bb = Double(bytes[o + 2])
                r += rr; g += gg; b += bb
                if max(rr, max(gg, bb)) >= 250 { clipped += 1 }
            }
        }
        return (r / n, g / n, b / n, clipped / n * 100)
    }

    @Test("C1 keeps a white shirt under its white point instead of clipping it")
    func chromeHoldsHighlights() throws {
        let out = try #require(CCDLook.chrome.render(patch(0.98, 0.98, 0.98),
                                                     dateStamp: false, sensor: .generic))
        let s = stats(out)
        // The shoulder compresses into the look's own white point, so a 0.98
        // patch lands at the asymptote (~245 in sRGB) instead of being clipped.
        // What matters is that nothing is pinned at 255.
        #expect(max(s.r, max(s.g, s.b)) <= 248, "C1 clipped a white shirt: \(s)")
        #expect(s.clipped < 0.5, "C1 pinned highlight pixels: \(s.clipped)%")
        #expect(s.clipped < 0.5)
    }

    @Test("C1 skin no longer leans as far into magenta")
    func chromeSkinIsLessRed() throws {
        let out = try #require(CCDLook.chrome.render(patch(0.78, 0.48, 0.42),
                                                     dateStamp: false, sensor: .generic))
        let s = stats(out)
        let ratio = s.r / max(s.g, 1)
        #expect(ratio < 1.95, "C1 skin still reads as magenta: R/G \(ratio)")
        #expect(ratio > 1.40, "C1 lost its cool-skin identity: R/G \(ratio)")
    }

    @Test("A8's shadow knee actually moves with the strength that names it")
    func partyKneeFollowsStrength() {
        // At the old 1.18 the knee drove anything below linear 0.0245 to black;
        // 1.12 keeps a sliver of shadow detail there.
        #expect(CCDLook.lumaTarget(luminance: 0.02, strength: 1.18) == 0)
        #expect(CCDLook.lumaTarget(luminance: 0.02, strength: 1.12) > 0.0005)
    }

    @Test("A8 midtones are not flattened by the softer knee")
    func partyMidtonesSurvive() {
        let mid = CCDLook.lumaTarget(luminance: 0.5, strength: 1.12)
        #expect(abs(mid - 0.5384) < 0.01)
        #expect(CCDLook.lumaTarget(luminance: 1.0, strength: 1.12) == 1.0)
    }
}

/// Renders the staged real photos through each look and drops the results into
/// the app's tmp directory, so a tuning change can be looked at instead of
/// guessed at. Skipped when `.tmp/render-in` is empty.
@Suite("Look render check")
struct LookRenderCheck {
    @Test("Render every staged sample with every look")
    func renderStagedSamples() async throws {
        let dir = pocketCCDRoot.appendingPathComponent(".tmp/render-in")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              !files.isEmpty else { return }
        let out = FileManager.default.temporaryDirectory
        for file in files where file.pathExtension.lowercased() == "jpg" {
            guard let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { continue }
            for look in CCDLook.allCases {
                guard let rendered = look.render(image, dateStamp: false, sensor: .generic) else { continue }
                // A real assertion, not a render-only tool: the default export
                // crops to 4:3 and must stay a non-empty 4:3 image.
                #expect(rendered.size.width > 0 && rendered.size.height > 0)
                let aspect = rendered.size.width / max(rendered.size.height, 1)
                #expect(abs(aspect - 4.0 / 3.0) < 0.02)
                let url = out.appendingPathComponent("\(look.shortName)-\(file.deletingPathExtension().lastPathComponent).png")
                try? rendered.pngData()?.write(to: url)
                print("RENDERED \(url.path)")
            }
        }
    }

    @Test("Render calibration ColorChecker with every look")
    func renderColorCheckerCalibration() async throws {
        let inputURL = pocketCCDRoot.appendingPathComponent("calibration/previews/colorchecker-ref.png")
        guard let data = try? Data(contentsOf: inputURL), let image = UIImage(data: data) else { return }
        let outDir = pocketCCDRoot.appendingPathComponent("calibration/previews/rendered")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for look in CCDLook.allCases {
            guard let rendered = look.render(image, dateStamp: false, sensor: .generic) else {
                Issue.record("ColorChecker render failed for \(look.shortName)")
                continue
            }
            #expect(rendered.size.width > 0 && rendered.size.height > 0)
            let url = outDir.appendingPathComponent("\(look.shortName)-colorchecker-ref.png")
            try rendered.pngData()?.write(to: url)
            print("CALIBRATION_RENDERED \(url.path)")
        }
    }
}

@Suite("N2 skin calibration")
struct N2SkinCalibration {
    private func patch(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
            UIColor(red: r, green: g, blue: b, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        }
    }
    private func mean(_ image: UIImage) -> (Double, Double, Double) {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return (0, 0, 0) }
        var r = 0.0, g = 0.0, b = 0.0
        let n = Double(cg.width * cg.height)
        for y in 0..<cg.height { for x in 0..<cg.width {
            let o = y * cg.bytesPerRow + x * 4
            r += Double(bytes[o]); g += Double(bytes[o+1]); b += Double(bytes[o+2])
        } }
        return (r/n, g/n, b/n)
    }
    @Test("N2 keeps warm skin at night instead of turning it red")
    func nightSkinStaysBelievable() {
        guard let out = CCDLook.night.render(patch(0.62, 0.42, 0.35), dateStamp: false, sensor: .generic) else { return }
        let m = mean(out)
        let ratio = m.0 / max(m.1, 1)
        // Per-channel contrast used to push this to 3.4, so a face lit by a
        // warm lamp read as red light. Luminance contrast brought it to ~1.7.
        #expect(ratio < 2.0, "N2 turned warm skin red: R/G \(ratio)")
        #expect(ratio > 1.2, "N2 flattened skin to grey: R/G \(ratio)")
    }

    @Test("N2 still renders a sodium lamp as warm, not white")
    func nightKeepsSodiumWarm() {
        guard let out = CCDLook.night.render(patch(0.96, 0.67, 0.24), dateStamp: false, sensor: .generic) else { return }
        let m = mean(out)
        #expect(m.0 / max(m.2, 1) > 2.2, "sodium light lost its warmth")
    }
}

@Suite("Skin across all looks")
struct SkinAcrossLooksTests {
    private func patch() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
            UIColor(red: 0.62, green: 0.42, blue: 0.35, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        }
    }
    private func ratio(_ look: CCDLook) -> Double? {
        guard let out = look.render(patch(), dateStamp: false, sensor: .generic),
              let cg = out.cgImage, let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        var r = 0.0, g = 0.0
        let n = Double(cg.width * cg.height)
        for y in 0..<cg.height { for x in 0..<cg.width {
            let o = y * cg.bytesPerRow + x * 4
            r += Double(bytes[o]); g += Double(bytes[o+1])
        } }
        return (r / n) / max(g / n, 1)
    }
    @Test("No camera turns warm skin into red light")
    func everyLookKeepsSkin() {
        for look in CCDLook.allCases {
            guard let value = ratio(look) else { continue }
            print(String(format: "SKIN %@ R/G=%.2f", look.shortName, value))
            #expect(value < 2.0, "\(look.shortName) turns warm skin red: R/G \(value)")
        }
    }
}

@Suite("Imaging stage calibration")
struct ImagingStageCalibrationTests {
    @Test("Render identical originals with individual effects disabled")
    func renderAblations() throws {
        let input = pocketCCDRoot.appendingPathComponent(".tmp/render-in")
        let variants: [(String, CCDLook.RenderEffects)] = [
            ("all", .all),
            ("no-red-guard", .all.subtracting(.redGuard)),
            ("no-halation", .all.subtracting(.halation)),
            ("no-diffusion", .all.subtracting(.diffusion)),
            ("no-bloom", .all.subtracting(.bloom)),
            ("no-shoulder", .all.subtracting(.shoulder)),
            ("no-temperature", .all.subtracting(.temperature)),
            ("no-saturation", .all.subtracting(.saturation))
        ]
        for name in ["orig-face", "orig-a7-flash", "new1121-6319", "new1121-6320", "new1121-6325", "sun1121-6285"] {
            let file = input.appendingPathComponent(name + ".jpg")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let image = try #require(UIImage(contentsOfFile: file.path))
            let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            let conditions = PhotoFrameMetadata(properties).imagingConditions
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let scale = 1000 / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let proxy = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            for look in CCDLook.allCases {
                for (variant, effects) in variants {
                    let rendered = try #require(look.render(proxy, dateStamp: false,
                                                           sensor: .generic, effects: effects, conditions: conditions))
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("calibration-\(name)-\(look.shortName)-\(variant).png")
                    try #require(rendered.pngData()).write(to: url)
                    print("CALIBRATION \(url.path)")
                }
            }
        }
    }
}

@Suite("Warm hue and highlight energy")
struct WarmHueAndHighlightTests {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private func sample(_ image: CIImage) -> [Float] {
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: linear])
        context.render(image, toBitmap: &pixel, rowBytes: MemoryLayout<Float>.size * 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: linear)
        return pixel
    }

    private func patch(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("Red protection reduces chroma without rotating warm skin towards yellow")
    func warmHueSurvives() {
        let samples: [[CGFloat]] = [[0.20, 0.12, 0.06], [0.55, 0.35, 0.20], [0.78, 0.48, 0.30]]
        for rgb in samples {
            let result = sample(patch(rgb[0], rgb[1], rgb[2]).applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": CCDLook.redGuardDimension,
                "inputCubeData": CCDLook.redGuardCube(strength: 0.75)
            ]))
            let before = Float((rgb[0] - rgb[1]) / (rgb[1] - rgb[2]))
            let after = (result[0] - result[1]) / (result[1] - result[2])
            #expect(abs(before - after) < 0.08, "warm hue rotated: \(before) → \(after)")
            #expect(result[0] < Float(rgb[0]))
            #expect(result[2] > Float(rgb[2]))
        }
    }

    @Test("Neutral surfaces and blue-free warm lights retain their colour")
    func nonSkinColoursSurvive() {
        let samples: [[CGFloat]] = [[0.5, 0.5, 0.5], [0.7, 0.15, 0.005], [0.1, 0.3, 0.6]]
        for rgb in samples {
            let result = sample(patch(rgb[0], rgb[1], rgb[2]).applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": CCDLook.redGuardDimension,
                "inputCubeData": CCDLook.redGuardCube(strength: 0.75)
            ]))
            for channel in 0..<3 {
                #expect(abs(result[channel] - Float(rgb[channel])) < 0.005)
            }
        }
    }

    @Test("Highlight energy grows continuously from dark through threshold to white",
          arguments: [CGFloat(0.68), CGFloat(0.72)])
    func highlightEnergyIsContinuous(threshold: CGFloat) {
        var previous: Float = 0
        for level in [CGFloat(0), threshold - 0.001, threshold, threshold + 0.001,
                      threshold + 0.01, (threshold + 1) / 2, 1] {
            let energy = sample(CCDLook.highlightSignal(patch(level, level, level), threshold: threshold))[0]
            #expect(energy.isFinite && energy >= -0.0001 && energy <= 1.0001)
            #expect(energy >= previous - 0.0001)
            if level <= threshold + 0.001 { #expect(energy < 0.001) }
            previous = energy
        }
        #expect(abs(previous - 1) < 0.001)
    }
    @Test("Warm saturation protection restrains skin while retaining blue, green and yellow scene colour")
    func warmSaturationDoesNotFlattenTheScene() {
        let skin = patch(0.3, 0.15, 0.07)
        let protected = sample(CCDLook.warmSafeSaturation(skin, amount: 1.30))
        #expect(protected[0] - protected[2] < (0.3 - 0.07) * 1.15)
        let sceneColours: [(CGFloat, CGFloat, CGFloat)] = [(0.1, 0.3, 0.7), (0.12, 0.4, 0.1), (0.7, 0.65, 0.05)]
        for rgb in sceneColours {
            let source = patch(rgb.0, rgb.1, rgb.2)
            let actual = sample(CCDLook.warmSafeSaturation(source, amount: 1.30))
            let reference = sample(source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.30]))
            for channel in 0..<3 { #expect(abs(actual[channel] - reference[channel]) < 0.002) }
        }
    }

}

@Suite("Capture quality pipeline")
struct CaptureQualityPipelineTests {
    @Test("Automatic stills prioritize quality while manual ISO and shutter are honored")
    func captureQualityPolicy() {
        #expect(CameraController.qualityPrioritization(manualExposure: false) == .quality)
        #expect(CameraController.qualityPrioritization(manualExposure: true) == .speed)
    }

    @Test("Texture follows ISO without adding sharpening to noisy captures")
    func isoTexturePolicy() {
        let daylight = CaptureImagingConditions(iso: 50)
        let night = CaptureImagingConditions(iso: 1600)
        #expect(daylight.grainScale < night.grainScale)
        #expect(daylight.denoiseScale < night.denoiseScale)
        #expect(daylight.sharpeningScale > night.sharpeningScale)
        for iso in [Double.nan, .infinity, -1, 0] {
            let invalid = CaptureImagingConditions(iso: iso)
            #expect(invalid.iso == nil)
            #expect(invalid.grainScale == 1)
        }
    }

    @Test("Metadata supplies real ISO and disables automatic correction for manual white balance")
    func captureMetadataPolicy() {
        let properties: [String: Any] = [kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifISOSpeedRatings as String: [800],
            kCGImagePropertyExifWhiteBalance as String: 1
        ]]
        let conditions = PhotoFrameMetadata(properties).imagingConditions
        #expect(conditions.iso == 800)
        #expect(!conditions.allowsSceneWhiteBalance)
        #expect(PhotoFrameMetadata([:]).imagingConditions.iso == nil)
    }

    @Test("Highlight feedback ignores small lamps and releases immediately for dark or flash scenes")
    func exposureProtection() {
        var policy = HighlightExposureState()
        let lamp = SceneMetering(luminance: 0.5, highlightFraction: 0.01, flashExpected: false)
        #expect(policy.update(lamp) == 0)
        for _ in 0..<20 {
            let bias = policy.update(.init(luminance: 0.7, highlightFraction: 0.1, flashExpected: false))
            #expect(bias >= -0.35 && bias <= 0)
        }
        #expect(policy.bias < 0)
        #expect(policy.update(.init(luminance: 0.1, highlightFraction: 0, flashExpected: false)) == 0)
        _ = policy.update(.init(luminance: 0.8, highlightFraction: 0.2, flashExpected: false))
        #expect(policy.update(.init(luminance: 0.8, highlightFraction: 0.2, flashExpected: true)) == 0)
    }

    @Test("White balance settles smoothly and separate preview streams cannot contaminate one another")
    func independentWhiteBalance() {
        var warm = PreviewWhiteBalanceState()
        var cool = PreviewWhiteBalanceState()
        #expect(warm.update(target: 1.08, at: 1) == 1.08)
        #expect(cool.update(target: 0.92, at: 1) == 0.92)
        let transition = warm.update(target: 0.92, at: 1.1)
        #expect(transition > 0.92 && transition < 1.08)
        #expect(cool.value == 0.92)
        #expect(abs(warm.update(target: 0.92, at: 3) - 0.92) < 0.001)
        warm = PreviewWhiteBalanceState()
        #expect(warm.update(target: 1, at: 4) == 1)
    }

    private func mean(_ cg: CGImage) -> [Double] {
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = CGContext(data: &bytes, width: cg.width, height: cg.height,
                                bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                space: ImagingColorPipeline.output,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var sums = [Double](repeating: 0, count: 3)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 { sums[channel] += Double(bytes[i + channel]) }
        }
        return sums.map { $0 / Double(cg.width * cg.height) }
    }

    @Test("Preview and saved colours agree with identical input and ISO", arguments: CCDLook.allCases)
    func isoPreviewParity(look: CCDLook) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 128), format: format).image { ctx in
            UIColor(red: 0.62, green: 0.42, blue: 0.35, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 128))
        }
        let conditions = CaptureImagingConditions(iso: 400)
        let source = try #require(CIImage(image: image))
        let preview = look.livePreview(source, sensor: .generic, conditions: conditions)
        let cgPreview = try #require(ImagingColorPipeline.displayImage(preview, using: ImagingColorPipeline.makeContext()))
        let capture = try #require(look.render(image, dateStamp: false, sensor: .generic, conditions: conditions)?.cgImage)
        for pair in zip(mean(cgPreview), mean(capture)) { #expect(abs(pair.0 - pair.1) < 1.5) }
    }

    @Test("The 1121 indoor portrait does not gain excessive skin saturation",
          .enabled(if: FileManager.default.fileExists(atPath: pocketCCDRoot.appendingPathComponent(".tmp/render-in/new1121-6319.jpg").path)))
    func realPortraitWarmProtection() throws {
        let url = pocketCCDRoot.appendingPathComponent(".tmp/render-in/new1121-6319.jpg")
        let image = try #require(UIImage(contentsOfFile: url.path))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scale = 1000 / max(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let proxy = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        let regions = [CGRect(x: 0.58, y: 0.26, width: 0.10, height: 0.10),
                       CGRect(x: 0.65, y: 0.36, width: 0.10, height: 0.10)]
        for look in [CCDLook.amber, .party] {
            let actual = try #require(look.render(proxy, dateStamp: false, sensor: .generic))
            let baseline = try #require(look.render(proxy, dateStamp: false, sensor: .generic,
                                                   effects: .all.subtracting(.saturation)))
            for region in regions {
                let a = try #require(FrameStatistics.measure(actual, region: region))
                let b = try #require(FrameStatistics.measure(baseline, region: region))
                func saturation(_ s: FrameStatistics) -> Double {
                    let high = max(s.meanR, s.meanG, s.meanB)
                    return (high - min(s.meanR, s.meanG, s.meanB)) / max(high, 0.001)
                }
                #expect(saturation(a) - saturation(b) < 0.12)
            }
        }
    }

    @Test("Moment processing keeps a finite frame for size-dependent effects")
    func momentFrameExtent() throws {
        let extent = CGRect(x: 12, y: 20, width: 96, height: 128)
        let source = CIImage(color: CIColor(red: 0.4, green: 0.3, blue: 0.2)).cropped(to: extent)
        let result = MomentVideoRenderer.processedFrame(source, look: .amber, sensor: .generic,
                                                       conditions: .init(iso: 400), isFront: false)
        #expect(!result.extent.isInfinite)
        #expect(result.extent == extent)
        let rendered = try #require(ImagingColorPipeline.displayImage(result, using: ImagingColorPipeline.makeContext()))
        #expect(rendered.width == 96 && rendered.height == 128)
    }

    @Test("Preview and export use the same centered focal crop")
    func focalCropGeometry() {
        let extent = CGRect(x: 12, y: 20, width: 3024, height: 4032)
        for aspect in CaptureAspectRatio.allCases {
            let base = aspect.cropRect(in: extent)
            let tele = aspect.cropRect(in: extent, focalCrop: 50.0 / 35.0)
            #expect(abs(tele.midX - base.midX) < 0.001)
            #expect(abs(tele.midY - base.midY) < 0.001)
            #expect(abs(tele.width / base.width - 35.0 / 50.0) < 0.001)
            #expect(aspect.cropRect(in: extent, focalCrop: .nan) == base)
        }
    }

    @Test("Export bakes orientation, embeds sRGB and replaces stale source dimensions")
    func exportColourAndGeometry() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8,
                                bytesPerRow: 160, space: p3,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: p3, components: [0.6, 0.3, 0.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = UIImage(cgImage: try #require(context.makeImage()), scale: 1, orientation: .right)
        let metadata = PhotoFrameMetadata([kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifPixelXDimension as String: 999,
            kCGImagePropertyExifPixelYDimension as String: 888,
            kCGImagePropertyExifColorSpace as String: 65535
        ], kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFOrientation as String: 6]])
        let encoded = try #require(CameraController.encodedPhoto(image, capturedAt: Date(timeIntervalSince1970: 0),
                                                               location: nil, exifData: metadata.exif,
                                                               tiffData: metadata.tiff, sourceGpsData: nil))
        let source = try #require(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        #expect(properties[kCGImagePropertyOrientation as String] as? Int == 1)
        #expect(properties[kCGImagePropertyPixelWidth as String] as? Int == 30)
        #expect(properties[kCGImagePropertyPixelHeight as String] as? Int == 40)
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifColorSpace as String] as? Int == 1)
        #expect(exif[kCGImagePropertyExifPixelXDimension as String] as? Int == 30)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.colorSpace?.name == ImagingColorPipeline.output.name)
    }
}

@Suite("Capture path corrections")
struct CapturePathCorrectionTests {
    private func metadata(iso: Int = 40) -> PhotoFrameMetadata {
        PhotoFrameMetadata([kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifISOSpeedRatings as String: [iso],
            kCGImagePropertyExifExposureTime as String: 1.0 / 125,
            kCGImagePropertyExifExposureBiasValue as String: -0.3,
            kCGImagePropertyExifWhiteBalance as String: 0
        ]])
    }

    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 96, height: 128), format: format).image { ctx in
            UIColor(red: 0.72, green: 0.5, blue: 0.46, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 128))
        }
    }

    @Test("Preview measures balance after the same colour anchor as the saved frame")
    func anchoredPreviewParity() throws {
        let image = image()
        let input = try #require(CIImage(image: image))
        let anchor = CaptureColorAnchor(red: 1, green: 0.5, blue: 0.2)
        let prepared = CCDLook.stabilizedInput(input, colorAnchor: anchor, consistencyStrength: 0.8)
        let gain = CCDLook.sceneBlueGain(prepared)
        #expect(abs(gain - CCDLook.sceneBlueGain(input)) > 0.002, "fixture must exercise the order-dependent correction")
        let preview = CCDLook.party.livePreview(prepared, sensor: .generic, flashStrength: 1, balanceGain: gain)
        let previewCG = try #require(ImagingColorPipeline.displayImage(preview, using: ImagingColorPipeline.makeContext()))
        let saved = try #require(CCDLook.party.render(image, dateStamp: false, sensor: .generic,
                                                      colorAnchor: anchor, consistencyStrength: 0.8, flash: 1))
        let a = try #require(FrameStatistics.measure(UIImage(cgImage: previewCG)))
        let b = try #require(FrameStatistics.measure(saved))
        #expect(a.maxChannelDelta(b) < 0.005)
    }

    @Test("Square crop taps map into the native letterboxed sensor preview")
    func squareFocusMapping() throws {
        let geometry = PreviewFrameGeometry(sourceSize: CGSize(width: 3000, height: 4000),
                                            aspectRatio: .square, focalCrop: 1)
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let top = try #require(geometry.layerPoint(for: CGPoint(x: 150, y: 0), in: bounds))
        let left = try #require(geometry.layerPoint(for: CGPoint(x: 0, y: 150), in: bounds))
        #expect(abs(top.x - 150) < 0.001 && abs(top.y - 37.5) < 0.001)
        #expect(abs(left.x - 37.5) < 0.001 && abs(left.y - 150) < 0.001)
    }

    @Test("Every crop and focal length preserves centre and stays inside the native preview",
          arguments: CaptureAspectRatio.allCases)
    func focalFocusMapping(aspect: CaptureAspectRatio) throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 400)
        let focals: [CGFloat] = [1, 50.0 / 35.0]
        for focal in focals {
            let geometry = PreviewFrameGeometry(sourceSize: CGSize(width: 3000, height: 4000),
                                                aspectRatio: aspect, focalCrop: focal)
            let middle = try #require(geometry.layerPoint(for: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds))
            #expect(abs(middle.x - bounds.midX) < 0.001)
            #expect(abs(middle.y - bounds.midY) < 0.001)
            if aspect != .fourThree {
                #expect(geometry.layerPoint(for: CGPoint(x: bounds.minX, y: bounds.minY), in: bounds) == nil,
                        "a letterbox tap must not focus on an unrelated scene point")
            }
        }
    }

    @Test("Archive uses each frame's EXIF instead of the manual control defaults")
    func originalArchiveExposure() async throws {
        let metadata = metadata()
        let encoded = try #require(CameraController.encodedPhoto(image(), capturedAt: Date(), location: nil,
                                                               exifData: metadata.exif, tiffData: nil, sourceGpsData: nil))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = OriginalFrameArchive(root: root)
        let snapshot = OriginalCaptureSnapshot(capturedAt: Date(), camera: CCDLook.amber.rawValue,
                                                cameraPosition: "back", mode: "standard", lens: "1×",
                                                exposureBias: 0, iso: 100, shutterSeconds: 1.0 / 60,
                                                whiteBalanceKelvin: 5200, flashMode: "NO FLASH")
        let diagnostics = CaptureExposureDiagnostics(
            policyRevision: CaptureExposureDiagnostics.policyRevision, appVersion: "1.0", appBuild: "test",
            requestedFlash: "FLASH", prioritization: "speed", manualExposure: false,
            flashLimitApplied: true, requestedMaximumSeconds: 1.0 / 60,
            before: .init(mode: 2, maximumSeconds: 1.0 / 60, shutterSeconds: 1.0 / 60, iso: 400),
            after: .init(mode: 2, maximumSeconds: 1.0 / 60, shutterSeconds: 0.25, iso: 64))
        await archive.archive([OriginalCaptureFrame(role: "standard", data: encoded.data,
                                                     diagnostics: diagnostics)], snapshot: snapshot)
        let folder = try #require(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("capture.json"))) as? [String: Any])
        #expect(json["iso"] as? Int == 40)
        #expect(abs((json["shutterSeconds"] as? Double ?? 0) - 1.0 / 125) < 0.0001)
        #expect(json["requestedISO"] as? Int == 100)
        #expect(json["whiteBalanceKelvin"] == nil, "unknown actual Kelvin must not be fabricated")
        let frames = try #require(json["frames"] as? [[String: Any]])
        #expect((frames.first?["exposure"] as? [String: Any])?["iso"] as? Int == 40)
        let archivedDiagnostics = try #require(frames.first?["diagnostics"] as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: archivedDiagnostics)
        #expect(try JSONDecoder().decode(CaptureExposureDiagnostics.self, from: data) == diagnostics)

    }

    @Test("Old roll entries without metadata still decode")
    func legacyRollEntry() throws {
        let entry = RollEntry(id: UUID(), fileName: "old.jpg", createdAt: Date(),
                              cameraRawValue: CCDLook.amber.rawValue, mode: .standard, qualityScore: 0.5)
        let data = try JSONEncoder().encode(entry)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["metadata"] == nil)
        #expect(try JSONDecoder().decode(RollEntry.self, from: data) == entry)
    }

    @MainActor
    @Test("Roll reload and note changes preserve metadata for the shared exporter")
    func rollMetadataSurvives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        let metadata = metadata()
        let id = try #require(await store.add(image(), camera: .amber, mode: .standard,
                                              createdAt: Date(), qualityScore: 0.5, metadata: metadata))
        store.updateNote("test", forEntryID: id)
        let restored = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        let entry = try #require(restored.entries.first)
        #expect(entry.metadata == metadata)
        let encoded = try #require(CameraController.encodedPhoto(image(), capturedAt: entry.createdAt,
                                                               location: nil, exifData: entry.metadata?.exif,
                                                               tiffData: entry.metadata?.tiff, sourceGpsData: entry.metadata?.gps))
        #expect(OriginalFrameExposure.read(encoded.data)?.iso == 40)
    }
}

@Suite("Roll write completion and dual recovery")
@MainActor
struct RollWriteAndDualRecoveryTests {
    private func frame() -> CapturedFrame {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
        }
        return CapturedFrame(image: image, role: .standard, qualityScore: 0.5)
    }

    @Test("A successful receipt is returned only with persisted images and index")
    func receiptAfterPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        let frames = [frame(), frame()]
        let receipt = await store.addFrames(frames, camera: .amber, mode: .flashPair, createdAt: Date())
        #expect(receipt.isComplete)
        #expect(receipt.storedCount == 2)
        let reopened = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        #expect(reopened.entries.count == 2)
        for entry in reopened.entries {
            #expect(FileManager.default.fileExists(atPath: reopened.thumbnailURL(for: entry).path))
        }
        #expect(Set(receipt.entryIDs.keys) == Set(frames.map(\.id)))
    }

    @Test("A recoverable image with a failed index is not reported as a completed save")
    func indexFailureReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manifest.json"), withIntermediateDirectories: true)
        let store = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        let receipt = await store.addFrames([frame()], camera: .amber, mode: .standard, createdAt: Date())
        #expect(receipt.storedCount == 1)
        #expect(receipt.failure == .index)
        #expect(!receipt.isComplete)
        let entry = try #require(store.entries.first)
        #expect(FileManager.default.fileExists(atPath: store.thumbnailURL(for: entry).path))
    }

    @Test("An image write error produces an explicit failure receipt")
    func imageWriteFailureReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)
        let store = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        let receipt = await store.addFrames([frame()], camera: .amber, mode: .standard, createdAt: Date())
        #expect(receipt.failure == .write)
        #expect(receipt.storedCount == 0)
        #expect(!receipt.isComplete)
    }

    @Test("A partly full roll reports partial storage instead of complete success")
    func partialRollReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
        for _ in 0..<(store.capacity - 1) {
            let image = frame().image
            let id = await store.add(image, camera: .amber, mode: .standard, createdAt: Date(), qualityScore: 0.5)
            #expect(id != nil)
        }
        let receipt = await store.addFrames([frame(), frame()], camera: .amber, mode: .flashPair, createdAt: Date())
        #expect(receipt.storedCount == 1)
        #expect(receipt.requestedCount == 2)
        #expect(receipt.failure == .full)
        #expect(!receipt.isComplete)
        #expect(store.entries.count == store.capacity)
    }

    enum StubError: Error, Equatable { case capture, switching, restoring }
    final class StubCamera {
        var position: AVCaptureDevice.Position
        var captures = 0
        var switches: [AVCaptureDevice.Position] = []
        var failingCapture: Int?
        var failFrontSwitch = false
        var failRestoration = false
        init(_ position: AVCaptureDevice.Position) { self.position = position }
        func move(to position: AVCaptureDevice.Position) throws {
            switches.append(position)
            if failRestoration && switches.count == 3 { throw StubError.restoring }
            if failFrontSwitch && position == .front { throw StubError.switching }
            self.position = position
        }
        func takePhoto() throws -> Int {
            captures += 1
            if captures == failingCapture { throw StubError.capture }
            return position == .back ? 100 : 200
        }
    }

    @Test("Sequential dual success restores the caller's initial front camera")
    func dualSuccessRestoresFront() async throws {
        let camera = StubCamera(.front)
        let photos = try await SequentialDualCapture.capture(initialPosition: .front,
            switchTo: { try camera.move(to: $0) }, capturePhoto: { try camera.takePhoto() }, waitForCamera: {})
        #expect(photos.rear == 100 && photos.front == 200)
        #expect(camera.position == .front)
        #expect(camera.switches == [.back, .front, .front])
    }

    @Test("A failed front capture restores the back camera before throwing")
    func frontFailureRestoresBack() async {
        let camera = StubCamera(.back)
        camera.failingCapture = 2
        do {
            _ = try await SequentialDualCapture.capture(initialPosition: .back,
                switchTo: { try camera.move(to: $0) }, capturePhoto: { try camera.takePhoto() }, waitForCamera: {})
            Issue.record("capture should have failed")
        } catch { #expect(error is StubError) }
        #expect(camera.position == .back)
        #expect(camera.switches.last == .back)
    }

    @Test("Cancellation during camera settling still awaits camera restoration")
    func cancellationRestoresCamera() async {
        let camera = StubCamera(.back)
        do {
            _ = try await SequentialDualCapture.capture(initialPosition: .back,
                switchTo: { try camera.move(to: $0) }, capturePhoto: { try camera.takePhoto() },
                waitForCamera: { throw CancellationError() })
            Issue.record("capture should have been cancelled")
        } catch { #expect(error is CancellationError) }
        #expect(camera.position == .back)
        #expect(camera.captures == 1)
    }

    @Test("A failed switch never captures the wrong lens and still restores")
    func failedSwitchDoesNotCaptureWrongLens() async {
        let camera = StubCamera(.back)
        camera.failFrontSwitch = true
        do {
            _ = try await SequentialDualCapture.capture(initialPosition: .back,
                switchTo: { try camera.move(to: $0) }, capturePhoto: { try camera.takePhoto() }, waitForCamera: {})
            Issue.record("switch should have failed")
        } catch { #expect(error is StubError) }
        #expect(camera.position == .back)
        #expect(camera.captures == 1)
    }

    @Test("Restoration failure is surfaced instead of returning a successful pair")
    func failedRestorationIsNotSuccess() async {
        let camera = StubCamera(.back)
        camera.failRestoration = true
        do {
            _ = try await SequentialDualCapture.capture(initialPosition: .back,
                switchTo: { try camera.move(to: $0) }, capturePhoto: { try camera.takePhoto() }, waitForCamera: {})
            Issue.record("restoration should have failed")
        } catch { #expect(error as? StubError == .restoring) }
    }
}

@Suite("Room portrait stage calibration")
struct RoomPortraitStageCalibration {
    @Test("Render new room and dark originals through individual grading stages")
    func stages() throws {
        let root = pocketCCDRoot.appendingPathComponent(".tmp/render-in")
        let variants: [(String, CCDLook.RenderEffects)] = [
            ("all", .all), ("no-red", .all.subtracting(.redGuard)),
            ("no-saturation", .all.subtracting(.saturation)), ("no-temperature", .all.subtracting(.temperature)),
            ("no-brightness", .all.subtracting(.brightness)), ("no-contrast", .all.subtracting(.lumaContrast)),
            ("no-tone", .all.subtracting(.toneCurve))
        ]
        for name in ["room1121-6394", "room1121-6397", "dark1121-6386", "dark1121-6389"] {
            let url = root.appendingPathComponent(name + ".jpg")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let image = try #require(UIImage(contentsOfFile: url.path))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let scale = 1000 / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let proxy = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            let conditions = PhotoFrameMetadata(props).imagingConditions
            for look in [CCDLook.amber, .night] {
                for (variant, effects) in variants {
                    let output = try #require(look.render(proxy, dateStamp: false, sensor: .generic,
                                                         effects: effects, conditions: conditions))
                    let path = FileManager.default.temporaryDirectory.appendingPathComponent("room-\(name)-\(look.shortName)-\(variant).png")
                    try #require(output.pngData()).write(to: path)
                    print("ROOM \(path.path)")
                }
            }
        }
    }
}

@Suite("Night shadow preservation")
struct NightShadowPreservationTests {
    @Test("N2 keeps black black and preserves a monotonic shadow ramp")
    func boundedShadows() {
        var previous = -1.0
        for step in 0...1000 {
            let input = Double(step) / 1000
            let trimmed = CCDLook.lumaTarget(luminance: input, strength: 1,
                                              brightness: -0.025, minimumGain: 0.85)
            let contrasted = CCDLook.lumaTarget(luminance: trimmed, strength: 1.04,
                                                 minimumGain: 0.90)
            #expect(contrasted >= input * 0.85 * 0.90 - 1e-10)
            #expect(contrasted >= previous)
            previous = contrasted
        }
        #expect(CCDLook.lumaTarget(luminance: 0, strength: 1,
                                  brightness: -0.025, minimumGain: 0.85) == 0)
        // At linear 0.02, the former channel subtraction wiped the entire signal.
        #expect(CCDLook.lumaTarget(luminance: 0.02, strength: 1,
                                  brightness: -0.025, minimumGain: 0.85) > 0.016)
    }
}

@Suite("Flash portrait stage calibration")
struct FlashPortraitStageCalibration {
    @Test("Compare flash portrait colour and falloff stages on captured originals")
    func stages() throws {
        let root = pocketCCDRoot.appendingPathComponent(".tmp/recheck-1121")
        for folder in ["20261121-230542-e0d341", "20261121-231841-f7f325", "20261121-233337-244236"] {
            let url = root.appendingPathComponent(folder + "/frame-1-flash.jpg")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let image = try #require(UIImage(contentsOfFile: url.path))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let scale = 1000 / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let proxy = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            for (name, effects) in [("all", CCDLook.RenderEffects.all),
                                     ("no-red", .all.subtracting(.redGuard)),
                                     ("no-falloff", .all.subtracting(.flashFalloff)),
                                     ("no-saturation", .all.subtracting(.saturation))] {
                let output = try #require(CCDLook.amber.render(proxy, dateStamp: false, sensor: .generic,
                                                              flash: 1, effects: effects,
                                                              conditions: .init(iso: 64)))
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("flash-\(folder)-\(name).png")
                try #require(output.pngData()).write(to: path)
                print("FLASHCHECK \(path.path)")
            }
        }
    }
}

@Suite("Flash colour continuity")
struct FlashColourContinuityTests {
    @Test("Brighter red skin cannot reverse into a grey band")
    func redRampStaysMonotonic() {
        for green: Float in [0.04, 0.12, 0.25, 0.40] {
            let blue = green * 0.60
            var previous = green
            for step in 0...500 {
                let red = green + (1 - green) * Float(step) / 500
                let result = CCDLook.flashGuardedRed(red: red, green: green, blue: blue, strength: 0.55)
                #expect(result >= previous - 0.000001)
                #expect(result >= green + (red - green) * 0.45 - 0.000001)
                #expect(result <= red + 0.000001)
                previous = result
            }
        }
    }

    @Test("Flash colour protection leaves neutral and blue-free light unchanged")
    func neutralAndLampSurvive() {
        #expect(CCDLook.flashGuardedRed(red: 0.5, green: 0.5, blue: 0.5, strength: 0.55) == 0.5)
        #expect(CCDLook.flashGuardedRed(red: 0.7, green: 0.15, blue: 0.005, strength: 0.55) == 0.7)
    }
}

@Suite("Flash motion preservation")
struct FlashMotionPreservationTests {
    @Test("Hardware flash prioritizes a prompt exposure while ambient retains quality")
    func capturePriorities() {
        #expect(CameraController.qualityPrioritization(manualExposure: false, hardwareFlash: true) == .speed)
        #expect(CameraController.qualityPrioritization(manualExposure: false, hardwareFlash: false) == .quality)
        #expect(CameraController.qualityPrioritization(manualExposure: true, hardwareFlash: true) == .speed)
    }

}

@Suite("Photo capture completion ordering")
struct PhotoCaptureCompletionTests {
    enum Failure: Error { case processing, terminal }

    @Test("A processed image cannot release configuration before capture ends")
    func processingFirst() throws {
        var state = PhotoCaptureCompletion<Int>()
        state.processed = .success(42)
        #expect(state.result == nil)
        state.finished = true
        #expect(try state.result?.get() == 42)
    }

    @Test("Completion arriving before the processing task still waits for its image")
    func completionFirst() throws {
        var state = PhotoCaptureCompletion<Int>()
        state.finished = true
        #expect(state.result == nil)
        state.processed = .success(42)
        #expect(try state.result?.get() == 42)
    }

    @Test("A terminal capture error overrides an already processed image")
    func terminalErrorWins() {
        var state = PhotoCaptureCompletion<Int>()
        state.processed = .success(42)
        state.finished = true
        state.terminalError = Failure.terminal
        if case .failure(Failure.terminal)? = state.result { } else { Issue.record("terminal error lost") }
    }

    @Test("A processing error is retained until the capture finishes")
    func processingFailure() {
        var state = PhotoCaptureCompletion<Int>()
        state.processed = .failure(Failure.processing)
        #expect(state.result == nil)
        state.finished = true
        if case .failure(Failure.processing)? = state.result { } else { Issue.record("processing error lost") }
    }
}

@Suite("1122 real-photo regression")
struct RealPhoto1122Regression {
    @Test("Render flash skin and high-contrast buildings from actual originals")
    func samples() throws {
        let root = pocketCCDRoot.appendingPathComponent(".tmp/review-1122")
        let index = root.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return }
        let entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        let targets = ["IMG_6415.HEIC", "IMG_6416.HEIC", "IMG_6417.HEIC", "IMG_6418.HEIC", "IMG_6454.HEIC", "IMG_6458.HEIC", "IMG_6459.HEIC"]
        for entry in entries where targets.contains(entry["file"] as? String ?? "") {
            let name = try #require(entry["file"] as? String)
            let folder = try #require(entry["folder"] as? String)
            let capture = try #require(entry["capture"] as? [String: Any])
            let cameraName = try #require(capture["camera"] as? String)
            let look = try #require(CCDLook(rawValue: cameraName))
            let url = root.appendingPathComponent(folder + "/frame-0-standard.jpg")
            let image = try #require(UIImage(contentsOfFile: url.path))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let scale = 1000 / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let proxy = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            let flash = ["IMG_6415.HEIC", "IMG_6416.HEIC", "IMG_6417.HEIC", "IMG_6418.HEIC"].contains(name)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            let output = try #require(look.render(proxy, dateStamp: false, sensor: .generic, flash: flash ? 1 : 0,
                                                 conditions: PhotoFrameMetadata(properties).imagingConditions))
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("1122-" + name.replacingOccurrences(of: ".HEIC", with: ".png"))
            try #require(output.pngData()).write(to: path)
            print("FIX1122 \(path.path)")
            if name == "IMG_6416.HEIC" || name == "IMG_6458.HEIC" {
                let native = try #require(look.render(image, dateStamp: false, sensor: .generic,
                                                      flash: flash ? 1 : 0,
                                                      conditions: PhotoFrameMetadata(properties).imagingConditions))
                let nativePath = FileManager.default.temporaryDirectory.appendingPathComponent("1122-native-" + name.replacingOccurrences(of: ".HEIC", with: ".png"))
                try #require(native.pngData()).write(to: nativePath)
                print("NATIVE1122 \(nativePath.path)")
            }
            if look == .chrome && !flash {
                let region = CGRect(x: 0, y: 0.65, width: 1, height: 0.3)
                let actual = try #require(FrameStatistics.measure(output, region: region))
                let reference = try #require(look.render(proxy, dateStamp: false, sensor: .generic,
                                                         effects: .all.subtracting(.lumaContrast),
                                                         conditions: PhotoFrameMetadata(properties).imagingConditions))
                let base = try #require(FrameStatistics.measure(reference, region: region))
                #expect(Double(actual.medianLuma) >= Double(base.medianLuma) * 0.70,
                        "C1 discarded shaded building structure")
            }
        }
    }
}

@Suite("N2 detail stage calibration")
struct NightDetailStageCalibration {
    @Test("Separate N2 glow, denoise and colour on real originals")
    func stages() throws {
        let root = pocketCCDRoot.appendingPathComponent(".tmp/review-1122")
        let sources = [("6469", "20261122-095226-3647bf"), ("6463", "20261122-094834-7ecd88"), ("6472", "20261122-102441-514edc")]
        let variants: [(String, CCDLook.RenderEffects)] = [
            ("all", .all), ("no-bloom", .all.subtracting(.bloom)),
            ("no-denoise", .all.subtracting(.denoise)), ("no-grain", .all.subtracting(.grain)),
            ("no-temperature", .all.subtracting(.temperature)), ("no-red", .all.subtracting(.redGuard))]
        for (name, folder) in sources {
            let url = root.appendingPathComponent(folder + "/frame-0-standard.jpg")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let image = try #require(UIImage(contentsOfFile: url.path))
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            for (variant, effects) in variants {
                let result = try #require(CCDLook.night.render(image, dateStamp: false, sensor: .generic,
                                                               flash: name == "6463" ? 1 : 0,
                                                               effects: effects,
                                                               conditions: PhotoFrameMetadata(properties).imagingConditions))
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("n2-" + name + "-" + variant + ".png")
                try #require(result.pngData()).write(to: path)
                print("N2DETAIL \(path.path)")
            }
        }
    }
}

@Suite("N2 noise-aware detail preservation")
struct NightNoiseAwareDetailTests {
    @Test("Clean daylight gets substantially less smoothing without weakening high-ISO protection")
    func lowISOProtectsDetail() {
        let clean = CCDLook.nightNoiseReduction(iso: 50)
        let dark = CCDLook.nightNoiseReduction(iso: 1600)
        #expect(clean < dark * 0.5)
        var previous = 0.0
        for iso in [50.0, 100, 200, 400, 800, 1600, 3200] {
            let amount = CCDLook.nightNoiseReduction(iso: iso)
            #expect(amount >= previous)
            #expect(amount > 0 && amount <= 0.034 + 1e-10)
            previous = amount
        }
        #expect(CCDLook.nightNoiseReduction(iso: nil) >= dark - 1e-10)
        #expect(CCDLook.nightNoiseReduction(iso: .nan).isFinite)
    }
}

@Suite("N2 high-ISO grain discipline")
struct NightHighISOGrainTests {
    @Test("Added grain decreases as sensor noise rises, while clean daylight keeps its texture")
    func addedTextureDoesNotStackOnNoise() {
        let daylight = CCDLook.nightGrainScale(iso: 50)
        let dark = CCDLook.nightGrainScale(iso: 3200)
        #expect(daylight > 0 && dark >= 0)
        #expect(dark < daylight / 3)
        var previous: CGFloat = 1
        for iso in [50.0, 100, 200, 400, 800, 1600, 3200] {
            let amount = CCDLook.nightGrainScale(iso: iso)
            #expect(amount <= previous && amount >= 0)
            previous = amount
        }
        #expect(CCDLook.nightGrainScale(iso: nil).isFinite)
    }

    @Test("N2 adds luminance texture without extra colour speckles")
    func grainIsNeutral() {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let noise = CIImage(color: CIColor(red: 0.2, green: 0.8, blue: 0.4, alpha: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        var pixel = [Float](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: space]).render(CCDLook.neutralGrainSource(noise),
            toBitmap: &pixel, rowBytes: 16, bounds: noise.extent, format: .RGBAf, colorSpace: space)
        #expect(abs(pixel[0] - pixel[1]) < 0.0001)
        #expect(abs(pixel[1] - pixel[2]) < 0.0001)
        #expect(pixel[0] > 0.2 && pixel[0] < 0.8)
        #expect(abs(pixel[3] - 1) < 0.0001)
    }
}

@Suite("M1 monochrome camera")
struct MonochromeCameraTests {
    @Test("Coloured subjects, flash, grain and date stamps remain neutral black and white")
    func neutralOutputAcrossCaptureOptions() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let input = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { ctx in
            for (i, color) in [UIColor.black, .red, .green, .blue, .white, .gray].enumerated() {
                color.setFill()
                ctx.fill(CGRect(x: (i % 3) * 86, y: (i / 3) * 128, width: 86, height: 128))
            }
        }
        for iso in [50.0, 3200] {
            for flash in [0.0, 1] {
                for stamp in [false, true] {
                    let output = try #require(CCDLook.mono.render(input, dateStamp: stamp, sensor: .generic,
                                                                  flash: flash, conditions: .init(iso: iso)))
                    let cg = try #require(output.cgImage)
                    var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                    let context = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height,
                        bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                    var maximumChroma = 0
                    for i in stride(from: 0, to: bytes.count, by: 4) {
                        let rgb = [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
                        maximumChroma = max(maximumChroma, rgb.max()! - rgb.min()!)
                    }
                    #expect(maximumChroma <= 1, "M1 output has a colour cast")
                }
            }
        }
    }

    @Test("M1 persists as its own body and existing Full entitlement includes it")
    func identityAndAccess() throws {
        #expect(CCDLook(rawValue: "POCKET M1") == .mono)
        #expect(ProductAccess.canUse(.mono, isFullUnlocked: true))
        #expect(!ProductAccess.canUse(.mono, isFullUnlocked: false))
        let defaults = try #require(UserDefaults(suiteName: "M1-" + UUID().uuidString))
        ShootingIdentity.remember(look: .mono, in: defaults)
        #expect(ShootingIdentity.look(in: defaults) == .mono)
    }

    @Test("Render M1 portrait, buildings and low light from real originals")
    func realOriginals() throws {
        let local = pocketCCDRoot.appendingPathComponent(".tmp/review-1122")
        let device = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PocketCCD Validation", isDirectory: true)
        let root = FileManager.default.fileExists(atPath: local.path) ? local : device
        for (name, folder) in [("portrait", "20261122-102258-94ebc0"),
                                ("buildings", "20261122-095226-3647bf"),
                                ("night", "20261122-102441-514edc")] {
            let url = root.appendingPathComponent(folder + "/frame-0-standard.jpg")
            try #require(FileManager.default.fileExists(atPath: url.path), "M1 validation input missing: \(url.path)")
            let input = try #require(UIImage(contentsOfFile: url.path))
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
            let result = try #require(CCDLook.mono.render(input, dateStamp: true, sensor: .generic,
                                                         conditions: PhotoFrameMetadata(properties).imagingConditions))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("m1-" + name + ".png")
            try #require(result.pngData()).write(to: file)
            print("M1RENDER \(file.path)")
        }
    }
}

@Suite("M1 live-device capture")
struct MonochromeLiveDeviceTests {
    @Test("Capture a real rear-camera frame and reopen its M1 roll entry",
          .enabled(if: ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == nil))
    @MainActor
    func liveCaptureAndReopen() async throws {
        let camera = CameraController()
        await camera.prepare()
        do {
            try #require(camera.isConfigured, "Physical camera was not configured")
            try await Task.sleep(for: .milliseconds(700))
            let photo = try await camera.capture(flashMode: .off)
            try #require(photo.originalData != nil, "Camera did not return an original")
            let output = try #require(CCDLook.mono.render(photo.image, dateStamp: true, sensor: .current(),
                                                         conditions: photo.metadata.imagingConditions))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("M1Live-" + UUID().uuidString)
            let store = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
            let id = try #require(await store.add(output, camera: .mono, mode: .standard,
                                                  createdAt: .now, qualityScore: 1, metadata: photo.metadata))
            let reopened = RollStore(root: root, defaults: isolatedRollDefaults(for: root))
            let entry = try #require(reopened.entries.first(where: { $0.id == id }))
            #expect(entry.cameraRawValue == "POCKET M1")
            #expect(entry.metadata == photo.metadata)
            let file = root.appendingPathComponent(entry.fileName)
            let decoded = try #require(UIImage(contentsOfFile: file.path))
            let stats = try #require(FrameStatistics.measure(decoded))
            #expect(abs(stats.meanR - stats.meanG) < 1)
            #expect(abs(stats.meanG - stats.meanB) < 1)
            let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("m1-live-device.jpg")
            try Data(contentsOf: file).write(to: evidence)
            print("M1LIVE \(evidence.path)")
            await camera.stopAndWait()
        } catch {
            await camera.stopAndWait()
            throw error
        }
    }
}

@Suite("Pocket Roll backup")
@MainActor
struct PocketRollBackupTests {
    @Test("Backup restores a re-adopted frame whose file name is not its UUID")
    func adoptedFrameSurvivesRoundTrip() async throws {
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCCD-BackupSource-\(UUID().uuidString)", isDirectory: true)
        let targetRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCCD-BackupTarget-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "PocketCCD.BackupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
            defaults.removePersistentDomain(forName: suiteName)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        let store = RollStore(root: sourceRoot, defaults: defaults)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 40)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 40))
        }
        let added = await store.add(image, camera: .amber, mode: .standard,
                                    createdAt: .now, qualityScore: 0.5)
        #expect(added != nil)
        let backupURL = try #require(await store.exportBackup(format: .v1))
        defer { try? FileManager.default.removeItem(at: backupURL) }
        let originalData = try Data(contentsOf: backupURL)

        // Simulate a frame recovered by `adoptUnindexedFrames`: it keeps its
        // on-disk name while carrying a new UUID. The old import rule rejected
        // the whole archive for exactly this case.
        let json = try JSONSerialization.jsonObject(with: originalData)
        var object = try #require(json as? [String: Any])
        var entries = try #require(object["currentEntries"] as? [[String: Any]])
        let canonicalName = try #require(entries.first?["fileName"] as? String)
        entries[0]["fileName"] = "IMG_0001.jpg"
        object["currentEntries"] = entries
        var images = try #require(object["imageDataByFileName"] as? [String: Any])
        guard let imagePayload = images.removeValue(forKey: canonicalName) else {
            Issue.record("backup has no image payload for \(canonicalName)")
            return
        }
        images["IMG_0001.jpg"] = imagePayload
        object["imageDataByFileName"] = images
        let adoptedData = try JSONSerialization.data(withJSONObject: object)

        let restored = RollStore(root: targetRoot, defaults: defaults)
        let count = try await restored.importBackup(data: adoptedData)
        #expect(count == 1)
        #expect(restored.entries.first?.fileName == "IMG_0001.jpg")
        #expect(FileManager.default.fileExists(
            atPath: targetRoot.appendingPathComponent("IMG_0001.jpg").path
        ))
    }

    @Test("Legacy v1 backup still imports through the URL API")
    func legacyURLImport() async throws {
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCCD-LegacySource-\(UUID().uuidString)", isDirectory: true)
        let targetRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCCD-LegacyTarget-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "PocketCCD.LegacyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
            defaults.removePersistentDomain(forName: suiteName)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        let store = RollStore(root: sourceRoot, defaults: defaults)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 24)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 24))
        }
        _ = await store.add(image, camera: .amber, mode: .standard, createdAt: .now, qualityScore: 0.5)
        let backupURL = try #require(await store.exportBackup(format: .v1))
        defer { try? FileManager.default.removeItem(at: backupURL) }

        let restored = RollStore(root: targetRoot, defaults: defaults)
        let count = try await restored.importBackup(from: backupURL)
        #expect(count == 1)
        #expect(restored.entries.count == 1)
    }

    @Test("Streaming backup writes JSON Lines and restores every frame")
    func streamingRoundTrip() async throws {
        let sourceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCCD-StreamSource-\(UUID().uuidString)", isDirectory: true)
        let targetRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCCD-StreamTarget-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "PocketCCD.StreamTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
            defaults.removePersistentDomain(forName: suiteName)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)

        let store = RollStore(root: sourceRoot, defaults: defaults)
        for index in 0..<2 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 32)).image { context in
                (index == 0 ? UIColor.red : UIColor.blue).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 24, height: 32))
            }
            let added = await store.add(image, camera: .amber, mode: .standard,
                                        createdAt: .now, qualityScore: 0.5)
            #expect(added != nil)
        }
        let backupURL = try #require(await store.exportBackup())
        defer { try? FileManager.default.removeItem(at: backupURL) }
        let text = try String(contentsOf: backupURL, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 3) // header + two image records
        #expect(lines.first?.contains("\"formatVersion\":2") == true)

        let restored = RollStore(root: targetRoot, defaults: defaults)
        let count = try await restored.importBackup(from: backupURL)
        #expect(count == 2)
        #expect(restored.entries.count == 2)
        for entry in restored.entries {
            #expect(FileManager.default.fileExists(
                atPath: targetRoot.appendingPathComponent(entry.fileName).path
            ))
        }
    }
}

@Suite("Moment video geometry")
struct MomentVideoGeometryTests {
    enum TestVideoError: Error { case setup, encodeFailed }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: true])

    @Test("Full Moment render crops the graded clip to the selected ratio")
    func fullRenderCropsClip() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("moment-render-\(UUID().uuidString).mov")
        try await Self.writeTestVideo(to: source, size: CGSize(width: 320, height: 240))

        let output = try await MomentVideoRenderer.render(
            sourceURL: source,
            look: .amber,
            sensor: .generic,
            balanceGain: 1.0,
            aspectRatio: .sixteenNine,
            focalCrop: 1,
            conditions: .init(),
            isFront: false
        )
        defer { try? FileManager.default.removeItem(at: output) }

        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 320)
        #expect(Int(size.height) == 180)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 0.5)
    }

    @Test("A rotated portrait recording keeps its orientation after cropping")
    func cropsRotatedVideo() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("moment-rotated-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: source) }
        try await Self.writeTestVideo(
            to: source,
            size: CGSize(width: 320, height: 240),
            transform: CGAffineTransform(rotationAngle: .pi / 2)
        )

        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: natural).applying(preferred).standardized
        #expect(Int(display.width) == 240)
        #expect(Int(display.height) == 320)

        let cropped = try #require(await MomentVideoRenderer.croppedVideoIfNeeded(
            sourceURL: source, aspectRatio: .square, focalCrop: 1
        ))
        defer { try? FileManager.default.removeItem(at: cropped) }
        let croppedAsset = AVURLAsset(url: cropped)
        let croppedTrack = try #require(try await croppedAsset.loadTracks(withMediaType: .video).first)
        let size = try await croppedTrack.load(.naturalSize)
        #expect(Int(size.width) == 240)
        #expect(Int(size.height) == 240)

        let generator = AVAssetImageGenerator(asset: croppedAsset)
        generator.appliesPreferredTrackTransform = true
        let (image, _) = try await generator.image(at: CMTime(value: 1, timescale: 10))
        // Rotating the 320×240 source 90° clockwise puts its red top edge on
        // the right. A 1:1 crop therefore must be red on the right, blue left.
        let left = Self.pixel(in: image, x: 20, y: image.height / 2)
        let right = Self.pixel(in: image, x: image.width - 20, y: image.height / 2)
        #expect(right.red > right.blue)
        #expect(left.blue > left.red)
    }

    @Test("A 4:3 recording crops to a 16:9 frame without shifting the image")
    func cropsToSixteenNine() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("moment-crop-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: source) }
        try await Self.writeTestVideo(to: source, size: CGSize(width: 320, height: 240))

        let sourceAsset = AVURLAsset(url: source)
        let sourceDuration = try await sourceAsset.load(.duration)
        #expect(sourceDuration.seconds > 0.5)

        let cropped = try #require(await MomentVideoRenderer.croppedVideoIfNeeded(
            sourceURL: source, aspectRatio: .sixteenNine, focalCrop: 1
        ))
        defer { try? FileManager.default.removeItem(at: cropped) }

        let asset = AVURLAsset(url: cropped)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 320)
        #expect(Int(size.height) == 180)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: cropped))
        generator.appliesPreferredTrackTransform = true
        let (image, _) = try await generator.image(at: CMTime(value: 1, timescale: 10))
        let top = Self.pixel(in: image, x: image.width / 2, y: image.height / 5)
        let bottom = Self.pixel(in: image, x: image.width / 2, y: image.height * 4 / 5)
        // Source top half is red, bottom half blue; a correct crop keeps them
        // that way. A flipped/skewed transform would swap the channels.
        #expect(top.red > top.blue)
        #expect(bottom.blue > bottom.red)
    }

    private static func pixel(in image: CGImage, x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let width = image.width
        let height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGBitmapContext memory rows run top-to-bottom.
        let row = y
        let index = (row * width + x) * 4
        return (data[index], data[index + 1], data[index + 2])
    }

    private static func writeTestVideo(
        to url: URL,
        size: CGSize,
        transform: CGAffineTransform = .identity
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        guard writer.canAdd(input) else { throw TestVideoError.setup }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TestVideoError.setup }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw TestVideoError.setup }

        let width = Int(size.width)
        let height = Int(size.height)
        for frame in 0..<10 {
            var optionalBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
            guard let buffer = optionalBuffer else { throw TestVideoError.setup }
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: bounds)
            let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: height / 2, width: width, height: height / 2))
            Self.ciContext.render(red.composited(over: blue), to: buffer,
                                  bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)) else {
                throw writer.error ?? TestVideoError.encodeFailed
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestVideoError.encodeFailed }
    }
}
