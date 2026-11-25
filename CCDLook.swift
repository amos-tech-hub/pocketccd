import CoreImage
import Metal
import UIKit

/// One colour contract for preview, processing and exported stills. Keep
/// intermediate calculations in linear half-float; quantize only for display.
enum ImagingColorPipeline {
    static let output = CGColorSpace(name: CGColorSpace.sRGB)!
    static let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private static let exportContext = makeContext()

    static func makeContext() -> CIContext {
        CIContext(options: [.workingColorSpace: working,
                            .workingFormat: CIFormat.RGBAh.rawValue,
                            .cacheIntermediates: false])
    }

    static func makeContext(commandQueue: MTLCommandQueue) -> CIContext {
        CIContext(mtlCommandQueue: commandQueue,
                  options: [.workingColorSpace: working,
                            .workingFormat: CIFormat.RGBAh.rawValue,
                            .cacheIntermediates: false])
    }

    static func displayImage(_ image: CIImage, using context: CIContext) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: output)
    }

    static func exportImage(_ image: UIImage) -> UIImage? {
        let upright = image.withOrientationBakedIn()
        guard let cg = upright.cgImage else { return nil }
        if cg.colorSpace?.name == output.name, cg.bitsPerComponent == 8 { return upright }
        guard let converted = displayImage(CIImage(cgImage: cg), using: exportContext) else { return nil }
        return UIImage(cgImage: converted, scale: upright.scale, orientation: .up)
    }
}

/// Actual capture metadata drives texture; missing metadata retains the recipe.
struct CaptureImagingConditions: Sendable {
    let iso: Double?
    let allowsSceneWhiteBalance: Bool

    init(iso: Double? = nil, allowsSceneWhiteBalance: Bool = true) {
        self.iso = iso.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.allowsSceneWhiteBalance = allowsSceneWhiteBalance
    }

    private var noiseLevel: Double? {
        iso.map { min(max(log2(max($0, 50) / 50) / 5, 0), 1) }
    }
    var grainScale: CGFloat { noiseLevel.map { CGFloat(0.45 + 0.55 * $0) } ?? 1 }
    var denoiseScale: Double { noiseLevel.map { 0.65 + 0.70 * $0 } ?? 1 }
    var sharpeningScale: Double { noiseLevel.map { 1 - 0.45 * $0 } ?? 1 }
}

/// Owned by one preview stream, never shared across cameras or test renders.
struct PreviewWhiteBalanceState {
    private(set) var value: Double?
    private var lastTime: CFTimeInterval?

    mutating func update(target: Double, at time: CFTimeInterval) -> Double {
        guard target.isFinite, time.isFinite else { return value ?? 1 }
        let target = min(max(target, 0.92), 1.08)
        if let value, let lastTime, time > lastTime {
            let weight = 1 - exp(-(time - lastTime) / 0.2)
            self.value = value + (target - value) * weight
        } else {
            value = target
        }
        lastTime = time
        return value ?? 1
    }
}

struct SceneMetering: Sendable {
    let luminance: Double
    let highlightFraction: Double
    let flashExpected: Bool
}

/// Conservative feedback: ignore small light sources, never brighten beyond
/// AE's baseline, and release protection on entering a dark scene.
struct HighlightExposureState {
    private(set) var bias: Float = 0

    mutating func update(_ scene: SceneMetering) -> Float {
        guard scene.luminance.isFinite, scene.highlightFraction.isFinite else { return bias }
        if scene.flashExpected || scene.luminance < 0.22 {
            bias = 0
        } else if scene.luminance > 0.42 && scene.highlightFraction > 0.03 {
            bias = max(-0.35, bias - 0.07)
        } else if scene.highlightFraction < 0.005 {
            // A slow release prevents AE and this controller from fighting.
            bias = min(0, bias + 0.015)
        }
        return bias
    }
}

struct CaptureColorAnchor: Codable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    func blended(with sample: CaptureColorAnchor, sampleWeight: CGFloat) -> CaptureColorAnchor {
        let weight = min(max(sampleWeight, 0), 1)
        return CaptureColorAnchor(
            red: red * (1 - weight) + sample.red * weight,
            green: green * (1 - weight) + sample.green * weight,
            blue: blue * (1 - weight) + sample.blue * weight
        )
    }

    static let sharedRenderContext = ImagingColorPipeline.makeContext()

    static func measure(_ image: UIImage, aspectRatio: CaptureAspectRatio) -> CaptureColorAnchor? {
        // Measure on a small proxy: the anchor only needs average colour, and a
        // full-resolution area average was adding hundreds of milliseconds to
        // every shutter press.
        let maxEdge: CGFloat = 512
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let target = CGSize(width: max(1, image.size.width * scale),
                            height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let proxy = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let input = CIImage(image: proxy) else { return nil }
        let cropped = input.cropped(to: aspectRatio.cropRect(in: input.extent))
        guard let average = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: cropped,
                kCIInputExtentKey: CIVector(cgRect: cropped.extent)
            ]
        )?.outputImage else { return nil }

        var pixel = [Float](repeating: 0, count: 4)
        sharedRenderContext.render(
            average,
            toBitmap: &pixel,
            rowBytes: MemoryLayout<Float>.size * 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        return CaptureColorAnchor(
            red: max(CGFloat(pixel[0]), 0.01),
            green: max(CGFloat(pixel[1]), 0.01),
            blue: max(CGFloat(pixel[2]), 0.01)
        )
    }

    func stabilizing(_ input: CIImage, strength: CGFloat) -> CIImage {
        let current = CaptureColorAnchor.measure(input)
        guard let current else { return input }

        let rawGains = [red / current.red, green / current.green, blue / current.blue]
        let neutralizer = pow(rawGains.reduce(1, *), 1 / 3)
        let gains = rawGains.map { gain in
            let neutralGain = gain / neutralizer
            return min(max(1 + ((neutralGain - 1) * strength), 0.94), 1.06)
        }
        return input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gains[0], y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gains[1], z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gains[2], w: 0)
        ])
    }

    private static func measure(_ input: CIImage) -> CaptureColorAnchor? {
        guard let average = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: input,
                kCIInputExtentKey: CIVector(cgRect: input.extent)
            ]
        )?.outputImage else { return nil }

        var pixel = [Float](repeating: 0, count: 4)
        sharedRenderContext.render(
            average,
            toBitmap: &pixel,
            rowBytes: MemoryLayout<Float>.size * 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        return CaptureColorAnchor(
            red: max(CGFloat(pixel[0]), 0.01),
            green: max(CGFloat(pixel[1]), 0.01),
            blue: max(CGFloat(pixel[2]), 0.01)
        )
    }
}

enum CCDLook: String, CaseIterable, Identifiable, Equatable {
    case amber = "POCKET A7"
    /// Harsh direct flash: the party look the EU/US CCD trend is built on.
    /// Deliberately its own camera so A7 keeps its warmer family-trip recipe.
    case party = "POCKET A8"
    case chrome = "POCKET C1"
    case night = "POCKET N2"
    case mono = "POCKET M1"
    case negative = "POCKET N1"

    /// `CIContext` owns expensive GPU/compiler caches and is safe to reuse
    /// across renders. Creating one per shutter press delayed every result.
    /// Contrast applied to luminance only. `CIColorControls` scales R, G and B
    /// independently, so on a warm flash frame the channel that starts lowest
    /// (blue, then green) is the one that dies. A color cube applies one gain to
    /// all three channels, preserving their ratios without the deprecated Core
    /// Image Kernel Language API.
    /// Built per strength and cached: the old static cube hard-coded 1.18, so
    /// `lumaContrast` was decorative and every A8 shadow stayed at that knee.
    private static let lumaCubeLock = NSLock()
    nonisolated(unsafe) private static var lumaCubeCache: [LumaGrade: Data] = [:]
    nonisolated(unsafe) private static var lumaCubeOrder: [LumaGrade] = []

    private struct LumaGrade: Hashable {
        let strength: Double
        let brightness: Double
        let minimumGain: Double
    }

    /// A bounded luminance trim preserves channel ratios and visible shadows.
    /// The default keeps the existing contrast curve for the other looks.
    static func lumaTarget(luminance: Double, strength: Double,
                           brightness: Double = 0, minimumGain: Double = 0) -> Double {
        let pivot = 0.18
        return min(max(pivot + (luminance - pivot) * strength + brightness,
                       luminance * minimumGain), 1)
    }

    private static func lumaContrastCube(strength: Double, brightness: Double = 0,
                                         minimumGain: Double = 0) -> Data {
        let grade = LumaGrade(strength: strength, brightness: brightness, minimumGain: minimumGain)
        lumaCubeLock.lock()
        defer { lumaCubeLock.unlock() }
        if let cached = lumaCubeCache[grade] { return cached }

        // 64³ is required here too: the tone/skin ratios move measurably with
        // a 33³ grid. Keep the quality and cap the cache instead.
        let dimension = 64
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)

        for blueIndex in 0..<dimension {
            let blue = Float(blueIndex) / Float(dimension - 1)
            for greenIndex in 0..<dimension {
                let green = Float(greenIndex) / Float(dimension - 1)
                for redIndex in 0..<dimension {
                    let red = Float(redIndex) / Float(dimension - 1)
                    let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
                    let target = Float(lumaTarget(luminance: Double(luminance),
                                                 strength: strength, brightness: brightness, minimumGain: minimumGain))
                    let gain = luminance > 0.0005 ? target / luminance : 0
                    values.append(min(max(red * gain, 0), 1))
                    values.append(min(max(green * gain, 0), 1))
                    values.append(min(max(blue * gain, 0), 1))
                    values.append(1)
                }
            }
        }
        let data = values.withUnsafeBytes { Data($0) }
        lumaCubeCache[grade] = data
        lumaCubeOrder.append(grade)
        while lumaCubeCache.count > 4, let oldest = lumaCubeOrder.first {
            lumaCubeOrder.removeFirst()
            lumaCubeCache.removeValue(forKey: oldest)
        }
        return data
    }

    /// Flash-lit skin on this look measured R/G 1.9–2.1: the red channel runs
    /// out of headroom long before luminance does, so cheeks go orange and lips
    /// go fluorescent. The guard pulls saturated red toward its nearest
    /// neighbour, but only where red is already bright — the warm midtones that
    /// define the camera are left alone.
    /// How hard the red-highlight guard bites. Flash looks get the full
    /// correction; N2 stays gentle, because on a sodium street the red it would
    /// remove is the light itself, not skin.
    private func redGuardStrength(flashed: Bool) -> Float {
        switch self {
        // Ambient skin needs a gentler correction across lit and shaded areas.
        // Keep the stronger correction for flash-lit highlights.
        case .amber: flashed ? 0.55 : 0.25
        case .party: flashed ? 0.65 : 0.55
        // C1 is already the cool body; a full guard took indoor skin down to
        // R/G 1.08, which reads grey rather than pale.
        case .chrome: 0.35
        case .night: 0.35
        case .negative: 0.30

        case .mono: 0
        }
    }

    /// Most red a single pixel may lose. Without it, saturated scene light
    /// (street lamps, sunsets) desaturates as hard as skin does.
    private static let redGuardLimit: Float = 0.22

    nonisolated(unsafe) private static var redGuardCubes: [RedGuardGrade: Data] = [:]
    nonisolated(unsafe) private static var redGuardOrder: [RedGuardGrade] = []
    private struct RedGuardGrade: Hashable {
        let strength: Float
        let smoothHighlights: Bool
    }
    private static let redGuardLock = NSLock()

    /// Cube for one strength. Night gets a weaker guard so sodium light keeps
    /// its colour, while flash portraits keep the full correction.
    /// 64³ is required: the guard's knee is narrow enough that a 33³ grid
    /// shifted skin ratios outside their reviewed bands.
    static let redGuardDimension = 64

    /// Monotonic chroma compression: increasing red cannot turn a highlight grey.
    static func flashGuardedRed(red: Float, green: Float, blue: Float, strength: Float) -> Float {
        guard red > green, red > blue else { return red }
        let closest = max(green, blue) * 1.05
        let excess = max(0, red - closest)
        let knee = max(green, blue) * 0.30 + 0.02
        let compressed = excess / (1 + excess / knee)
        let gate = smoothstep(0.12, 0.30, blue / max(green, 0.02))
        return red - (excess - compressed) * min(max(strength, 0), 1) * gate
    }

    static func redGuardCube(strength: Float, smoothHighlights: Bool = false) -> Data {
        let grade = RedGuardGrade(strength: strength, smoothHighlights: smoothHighlights)
        redGuardLock.lock()
        defer { redGuardLock.unlock() }
        if let cached = redGuardCubes[grade] { return cached }

        let dimension = redGuardDimension
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for blueIndex in 0..<dimension {
            let blue = Float(blueIndex) / Float(dimension - 1)
            for greenIndex in 0..<dimension {
                let green = Float(greenIndex) / Float(dimension - 1)
                for redIndex in 0..<dimension {
                    let red = Float(redIndex) / Float(dimension - 1)
                    var guardedRed = red
                    var guardedBlue = blue
                    if red > green, red > blue {
                        let closest = max(green, blue) * 1.05
                        let excess = max(0, red - closest)
                        // The cube runs in extended linear space, where midtone
                        // skin sits near 0.1–0.3. The old 0.30–0.65 gate meant
                        // only flash-bright faces were ever guarded; indoor and
                        // shadowed skin kept its red (measured R/G 2.3–2.7).
                        // The second gate keys on how red-dominant the pixel is,
                        // so a warm card (R/G ≈ 1.1) keeps its cast while skin
                        // (R/G ≈ 1.6–2) gets pulled.
                        let redness = red / max(green, 0.02)
                        // Skin keeps a real blue component (B/G ≈ 0.4–0.6);
                        // a sodium lamp is almost blue-free (B/G ≈ 0.1). The
                        // blue gate lets the guard work on faces without
                        // touching street light.
                        let skinGate = smoothstep(0.12, 0.30, blue / max(green, 0.02))
                        let pull = min(
                            excess * strength
                                * smoothstep(0.05, 0.18, red)
                                * smoothstep(1.30, 1.70, redness)
                                * skinGate,
                            redGuardLimit
                        )
                        guardedRed = smoothHighlights
                            ? flashGuardedRed(red: red, green: green, blue: blue, strength: strength)
                            : red - pull
                        // Compress chroma around green instead of subtracting
                        // red alone. Holding (R-G)/(G-B) preserves the warm hue;
                        // red-only removal rotated orange skin towards yellow.
                        if green > blue {
                            let chromaScale = (guardedRed - green) / max(red - green, 0.0001)
                            guardedBlue = green - (green - blue) * max(chromaScale, 0)
                        }
                    }
                    values.append(guardedRed)
                    values.append(green)
                    values.append(guardedBlue)
                    values.append(1)
                }
            }
        }
        let data = values.withUnsafeBytes { Data($0) }
        redGuardCubes[grade] = data
        redGuardOrder.append(grade)
        // Preview only needs the selected look's ambient + flash tables.
        // Keeping every look's 4 MB cube around cost ~48 MB; cap the cache.
        while redGuardCubes.count > 4, let oldest = redGuardOrder.first {
            redGuardOrder.removeFirst()
            redGuardCubes.removeValue(forKey: oldest)
        }
        return data
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// A7/A8's global saturation amplified already-warm skin into orange in
    /// the 1121 shop originals. Limit the extra saturation in warm midtones,
    /// while blue clothing, foliage and blue-free warm lights keep the recipe.
    private static let warmSaturationMask: Data = {
        let dimension = 32
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let red = Float(r) / Float(dimension - 1)
            let green = Float(g) / Float(dimension - 1)
            let blue = Float(b) / Float(dimension - 1)
            let ratio = red / max(green, 0.02)
            let blueRatio = blue / max(green, 0.02)
            let warm = smoothstep(1.02, 1.12, ratio)
                * smoothstep(0.10, 0.25, blueRatio)
                * (1 - smoothstep(0.95, 1.15, blueRatio))
                * smoothstep(0.025, 0.10, red)
            values.append(contentsOf: [warm, warm, warm, 1])
        } } }
        return values.withUnsafeBytes { Data($0) }
    }()

    static func warmSafeSaturation(_ image: CIImage, amount: Double) -> CIImage {
        let enriched = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: amount])
        guard amount > 1.04 else { return enriched }
        let restrained = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.04])
        let mask = image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": 32, "inputCubeData": warmSaturationMask
        ])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(0.5, min(image.extent.width, image.extent.height) / 75)
            ])
            .cropped(to: image.extent)
        return restrained.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: enriched, kCIInputMaskImageKey: mask
        ]).cropped(to: image.extent)
    }

    /// One 33³ table for the whole pointwise tone stage. It is baked from the
    /// same CI filters the pipeline used to run on every frame — exposure,
    /// saturation/contrast/brightness, temperature, the tone curve, the
    /// luminance-contrast cube, the red guard and the first clamp — so the
    /// replacement is a cache of the existing maths, not a second
    /// implementation that can drift away from it.
    ///
    /// What is deliberately not in the table: the vignette, bloom, noise
    /// reduction, sharpening and grain. Those are spatial or seeded, and a
    /// pointwise table cannot represent them.
    private static var halationScale: Double {
        let raw = UserDefaults.standard.object(forKey: "halationLevel") as? Int
        return (raw.flatMap(HalationLevel.init(rawValue:)) ?? .standard).scale
    }

    /// Daylight skies measured G/B 0.63 against the 0.72–0.85 a film sky
    /// holds: the blue survived the highlight roll-off and the cyan did not.
    /// This table lifts G and B together in the top of the curve, which turns
    /// the blue towards cyan without touching chroma elsewhere.
    nonisolated(unsafe) private static var skyTealData: Data?
    private static let skyTealLock = NSLock()

    private static func skyTealCube() -> Data {
        skyTealLock.lock()
        defer { skyTealLock.unlock() }
        if let skyTealData { return skyTealData }
        let dimension = 33
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let r = Float(red) / Float(dimension - 1)
                    let g = Float(green) / Float(dimension - 1)
                    let b = Float(blue) / Float(dimension - 1)
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    // Only blue-dominant pixels are sky. Without this gate the
                    // highlight lift also hit skin sheen and printed green
                    // patches on foreheads and cheeks.
                    let skyness = smoothstep(0.0, 0.08, b - r)
                    let lift = smoothstep(0.12, 0.35, luma) * 0.05 * skyness
                    values.append(r)
                    values.append(min(1, g + lift * 0.5))
                    values.append(min(1, b + lift))
                    values.append(1)
                }
            }
        }
        let data = values.withUnsafeBytes { Data($0) }
        skyTealData = data
        return data
    }

    nonisolated(unsafe) private static var toneCubes: [String: Data] = [:]
    private static let toneCubeLock = NSLock()

    private func toneCube() -> Data {
        Self.toneCubeLock.lock()
        defer { Self.toneCubeLock.unlock() }
        if let cached = Self.toneCubes[rawValue] { return cached }

        let dimension = 65
        var chain = CIImage(cgImage: Self.toneGrid(dimension: dimension))
            .applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: exposureEV
            ])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: saturation,
                kCIInputContrastKey: contrast,
                kCIInputBrightnessKey: brightness
            ])
            .applyingFilter("CIToneCurve", parameters: toneCurveParameters)
        chain = chain.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: blackClamp, y: blackClamp, z: blackClamp, w: 0),
            "inputMaxComponents": CIVector(x: whiteClamp, y: whiteClamp, z: whiteClamp, w: 1)
        ])
        // Fold the local sky/highlight desaturation into the same table: a
        // separate runtime pass added a second trilinear sample and moved the
        // boundary skin tests by 0.1%, which is enough to fail them.
        chain = chain.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": 33,
            "inputCubeData": Self.skyDesaturationCube()
        ])
        let data = Self.cubeData(from: chain, dimension: dimension)
        Self.toneCubes[rawValue] = data
        return data
    }

    /// Red-fastest, blue-slowest: the order `CIColorCube` reads and the same
    /// order the shoulder cube already used.
    ///
    /// The grid is written in the **linear** working space, because that is
    /// what `CIColorCube` samples: it linearises its input and indexes the
    /// table with the linear value. A grid written as sRGB-encoded values
    /// samples the wrong part of the table — the first attempt at this read
    /// the midtone card back 12% dark and the amber cast as neutral.
    private static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private static func toneGrid(dimension: Int) -> CGImage {
        let width = dimension, height = dimension * dimension
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        func encoded(_ value: Double) -> UInt16 { UInt16((value * 65535).rounded()) }
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let x = red, y = green + blue * dimension
                    let i = (y * width + x) * 4
                    pixels[i] = encoded(Double(red) / Double(dimension - 1))
                    pixels[i + 1] = encoded(Double(green) / Double(dimension - 1))
                    pixels[i + 2] = encoded(Double(blue) / Double(dimension - 1))
                    pixels[i + 3] = 65535
                }
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: width * 8, space: linearSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder16Little),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private static func cubeData(from image: CIImage, dimension: Int) -> Data {
        let width = dimension, height = dimension * dimension
        var pixels = [Float](repeating: 0, count: width * height * 4)
        renderContext.render(
            image, toBitmap: &pixels, rowBytes: width * 16,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAf, colorSpace: linearSpace
        )
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let x = red, y = green + blue * dimension
                    let i = (y * width + x) * 4
                    values.append(pixels[i])
                    values.append(pixels[i + 1])
                    values.append(pixels[i + 2])
                    values.append(1)
                }
            }
        }
        return values.withUnsafeBytes { Data($0) }
    }

    /// Local desaturation: the sky and the brightest highlights give up some
    /// saturation, everything else keeps its colour. A global `saturation`
    /// reduction was tried and rejected — it moved skin R/G with it and broke
    /// the sodium-lamp and C1-skin gates. This table keys on blue dominance
    /// (B > R, which no skin has) and on luminance, so a face cannot be
    /// touched.
    nonisolated(unsafe) private static var skyCube: Data?
    private static let skyCubeLock = NSLock()

    private static func skyDesaturationCube() -> Data {
        skyCubeLock.lock()
        defer { skyCubeLock.unlock() }
        if let skyCube { return skyCube }

        let dimension = 33
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let r = Float(red) / Float(dimension - 1)
                    let g = Float(green) / Float(dimension - 1)
                    let b = Float(blue) / Float(dimension - 1)
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    // Linear: a daylight sky sits around luma 0.10–0.35 with B
                    // well above R; skin at 0.27 has R above B and stays at 0.
                    let sky = smoothstep(0.03, 0.15, b - r) * smoothstep(0.08, 0.22, luma)
                    let highlight = smoothstep(0.55, 0.85, luma) * 0.25
                    let mask = min(max(sky, highlight), 1)
                    let keep: Float = 1 - 0.0 * mask
                    values.append(luma + (r - luma) * keep)
                    values.append(luma + (g - luma) * keep)
                    values.append(luma + (b - luma) * keep)
                    values.append(1)
                }
            }
        }
        let data = values.withUnsafeBytes { Data($0) }
        skyCube = data
        return data
    }

    /// Pre-warm static 3D color cubes into memory to guarantee zero allocation
    /// delays on the live preview video thread.
    static func prewarmCubes() {
        for look in allCases {
            _ = cameraCharacterCube(for: look)
            _ = shoulderCube(white: CGFloat(look.whiteClamp))
        }
    }

    /// Warms the two red-guard tables for the look the camera is about to use.
    /// The cache keeps at most four entries, so switching bodies does not
    /// accumulate 4 MB cubes for all six looks.
    static func prewarmRedGuard(for look: CCDLook) {
        Task.detached(priority: .utility) {
            _ = redGuardCube(strength: Float(look.redGuardStrength(flashed: false)))
            _ = redGuardCube(strength: Float(look.redGuardStrength(flashed: true)),
                             smoothHighlights: look == .amber || look == .party)
        }
    }

    /// Per-camera perceptual 3D color grading cube (33³).
    ///
    /// Core Image runs in `extendedLinearSRGB`, where perceptual midtones sit near
    /// 0.18–0.21 rather than 0.50. Each grid point is therefore converted to sRGB,
    /// graded in perceptual space (luminance-preserving monotone S-curve, shadow/
    /// midtone/highlight split toning, and hue-selective remapping), and converted
    /// back to linear sRGB. This gives every camera body a distinct, authentic
    /// photographic signature matching its real-world prototype in a single GPU pass.
    nonisolated(unsafe) private static var characterCubes: [CCDLook: Data] = [:]
    private static let characterCubeLock = NSLock()

    private static func linearToSRGB(_ x: Float) -> Float {
        let v = min(max(x, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * powf(v, 1.0 / 2.4) - 0.055
    }

    private static func srgbToLinear(_ x: Float) -> Float {
        let v = min(max(x, 0), 1)
        return v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
    }

    /// Fritsch–Carlson monotone cubic spline evaluation on 5 sorted (x, y) knots.
    private static func evalMonotoneCurve(_ x: Float, knots: [(Float, Float)]) -> Float {
        let v = min(max(x, 0), 1)
        let n = knots.count
        var secants = [Float](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx = max(knots[i + 1].0 - knots[i].0, 1e-5)
            secants[i] = (knots[i + 1].1 - knots[i].1) / dx
        }
        var tangents = [Float](repeating: 0, count: n)
        tangents[0] = secants[0]
        tangents[n - 1] = secants[n - 2]
        for i in 1..<(n - 1) {
            if secants[i - 1] * secants[i] <= 0 {
                tangents[i] = 0
            } else {
                tangents[i] = 0.5 * (secants[i - 1] + secants[i])
            }
        }
        for i in 0..<(n - 1) {
            if abs(secants[i]) < 1e-6 {
                tangents[i] = 0
                tangents[i + 1] = 0
            } else {
                let a = tangents[i] / secants[i]
                let b = tangents[i + 1] / secants[i]
                let sumSq = a * a + b * b
                if sumSq > 9.0 {
                    let tau = 3.0 / sqrtf(sumSq)
                    tangents[i] = tau * a * secants[i]
                    tangents[i + 1] = tau * b * secants[i]
                }
            }
        }
        var seg = n - 2
        for i in 0..<(n - 1) {
            if v <= knots[i + 1].0 {
                seg = i
                break
            }
        }
        let x0 = knots[seg].0, x1 = knots[seg + 1].0
        let y0 = knots[seg].1, y1 = knots[seg + 1].1
        let h = max(x1 - x0, 1e-5)
        let t = min(max((v - x0) / h, 0), 1)
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return min(max(h00 * y0 + h10 * h * tangents[seg] + h01 * y1 + h11 * h * tangents[seg + 1], 0), 1)
    }

    private static func cameraCharacterCube(for look: CCDLook) -> Data {
        characterCubeLock.lock()
        defer { characterCubeLock.unlock() }
        if let cached = characterCubes[look] { return cached }

        let dimension = 33
        // Data-calibrated perceptual sRGB S-curves: decisively pull down Apple Smart HDR's
        // over-lifted 0.20–0.40 shadow band (dropping dark clothing from ~82/255 into
        // real CCD/film velvety 32–50/255) while sculpting luminous midtones and highlights.
        let knots: [(Float, Float)]
        switch look {
        case .amber:
            // Canon PowerShot A70 / U2: open matte film toe (no dead <8 black at night), glowing skin midtones, sparkling highlights.
            knots = [(0.0, 0.045), (0.28, 0.21), (0.55, 0.59), (0.80, 0.88), (1.0, 0.995)]
        case .party:
            // Canon IXUS direct flash: punchy darks with shadow detail retained, hot specular flash core.
            knots = [(0.0, 0.018), (0.28, 0.155), (0.54, 0.62), (0.78, 0.90), (1.0, 0.995)]
        case .chrome:
            // Sony Cyber-shot: crisp high-contrast early CCD, clean darks, bright porcelain highlights.
            knots = [(0.0, 0.025), (0.28, 0.185), (0.54, 0.59), (0.78, 0.88), (1.0, 0.99)]
        case .night:
            // Fujifilm FinePix F30: lifted matte cinema night toe so sky & buildings retain detail, glowing streetlamps.
            knots = [(0.0, 0.048), (0.28, 0.195), (0.54, 0.53), (0.80, 0.86), (1.0, 0.99)]
        case .mono:
            // Ricoh GR Digital Moriyama high-contrast B&W: deep dramatic blacks, sparkling silver midtones.
            knots = [(0.0, 0.012), (0.28, 0.135), (0.52, 0.57), (0.76, 0.91), (1.0, 0.995)]
        case .negative:
            // Contax T3 + Portra 400: lifted velvety film toe (~42–46/255), clean open highlights (~240/255).
            knots = [(0.0, 0.068), (0.28, 0.22), (0.54, 0.56), (0.80, 0.86), (1.0, 0.99)]
        }

        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)

        for blueIdx in 0..<dimension {
            let bLin = Float(blueIdx) / Float(dimension - 1)
            let sb0 = linearToSRGB(bLin)
            for greenIdx in 0..<dimension {
                let gLin = Float(greenIdx) / Float(dimension - 1)
                let sg0 = linearToSRGB(gLin)
                for redIdx in 0..<dimension {
                    let rLin = Float(redIdx) / Float(dimension - 1)
                    let sr0 = linearToSRGB(rLin)

                    // 1. Luminance-preserving perceptual S-curve with additive matte film toe.
                    // Never multiply near-black RGB by (floor / y0), which explodes shadow
                    // chroma 10x+ into neon purple/blue blotches. Blending the matte floor
                    // additively in the shadow toe preserves exact luminance y1 while keeping
                    // deep shadows clean neutral charcoal and midtones fully saturated.
                    let y0 = 0.2126 * sr0 + 0.7152 * sg0 + 0.0722 * sb0
                    let y1 = evalMonotoneCurve(y0, knots: knots)
                    let blackFloor = knots[0].1
                    let toeAdd = blackFloor * (1.0 - smoothstep(0.0, 0.35, y0))
                    var sr: Float
                    var sg: Float
                    var sb: Float
                    if y0 > 1e-4 {
                        let gain = min(max(0, y1 - toeAdd) / y0, 1.8)
                        sr = toeAdd + sr0 * gain
                        sg = toeAdd + sg0 * gain
                        sb = toeAdd + sb0 * gain
                    } else {
                        sr = y1
                        sg = y1
                        sb = y1
                    }

                    // Soft gamut preservation if gain pushes a channel past 1.0
                    let peak = max(sr, max(sg, sb))
                    if peak > 1.0 {
                        let excess = peak - 1.0
                        let mixT = min(excess / max(peak - y1, 1e-4), 1.0)
                        sr = min(1.0, sr + (y1 - sr) * mixT)
                        sg = min(1.0, sg + (y1 - sg) * mixT)
                        sb = min(1.0, sb + (y1 - sb) * mixT)
                    }

                    // 2. Per-camera split toning & chroma-gated hue remapping in sRGB.
                    // `colorGate` keeps neutral white walls and white clothing crisp and
                    // clean (no cheap yellow wash) while letting skin, foliage, skies,
                    // and fabrics take on rich, unmistakable film/CCD character.
                    // Gate shadowW on input y0 so pure black stays neutral matte charcoal.
                    let shadowW = (1.0 - smoothstep(0.08, 0.42, y1)) * smoothstep(0.01, 0.08, y0)
                    let midW = smoothstep(0.12, 0.45, y1) * (1.0 - smoothstep(0.58, 0.92, y1))
                    let highW = smoothstep(0.52, 0.92, y1) * (1.0 - smoothstep(0.95, 1.0, y1))

                    let chroma = max(sr, max(sg, sb)) - min(sr, min(sg, sb))
                    let colorGate = smoothstep(0.03, 0.14, chroma)
                    let skyGate = smoothstep(0.03, 0.18, sb - max(sr, sg)) * smoothstep(0.18, 0.55, y1)
                    let foliageGate = smoothstep(0.03, 0.16, sg - max(sr, sb))
                    let warmGate = smoothstep(0.04, 0.20, sr - sb) * smoothstep(0.01, 0.12, sg - sb)

                    switch look {
                    case .amber:
                        // Canon PowerShot A70 / U2: clean neutral walls, warm sunlit-peach skin without yellow cast, restrained cyan-blue sky.
                        let warmSkin = (midW + highW * 0.72) * warmGate
                        sr += warmSkin * 0.022 + midW * 0.005 + shadowW * 0.004
                        sg += warmSkin * 0.014 + midW * 0.002
                        sb += -(warmSkin * 0.034 + midW * 0.009 + shadowW * 0.006)
                        // Restrained cyan-turquoise sky shift (avoids pushing blue sky -32° into green-cyan)
                        sg += skyGate * 0.044
                        sr -= skyGate * 0.014
                        // Gently warmed foliage
                        sr += foliageGate * 0.010
                        sg += foliageGate * 0.008
                        sb -= foliageGate * 0.008

                    case .party:
                        // Canon IXUS direct flash: hard shadow drop-off, crisp xenon white-warm core, punchy colors.
                        let desat = (1.0 - smoothstep(0.0, 0.26, y1)) * 0.45
                        sr = sr + (y1 - sr) * desat
                        sg = sg + (y1 - sg) * desat
                        sb = sb + (y1 - sb) * desat
                        sr += highW * colorGate * 0.020
                        sg += highW * colorGate * 0.010
                        // Slight turquoise sky retention if used outdoors
                        sg += skyGate * 0.032

                    case .chrome:
                        // Sony Cyber-shot W1: crisp contrast, cool cobalt-cyan shadows & porcelain highlights,
                        // with red-hue protection so pure reds stay punchy W1 red instead of drifting magenta.
                        let redGate = smoothstep(0.05, 0.22, sr - max(sg, sb))
                        sr += -(shadowW * 0.018 + highW * 0.008) + redGate * 0.028
                        sg += shadowW * 0.006 + highW * 0.004 + redGate * 0.014
                        sb += shadowW * 0.032 + highW * 0.018 - redGate * 0.044
                        // Punchy cobalt skies & crisp foliage
                        sb += skyGate * 0.034 + foliageGate * 0.014
                        sg += skyGate * 0.016

                    case .night:
                        // Fujifilm FinePix F30: cinema emerald/cyan-green locked to shadows so faces stay clean F30 neutral,
                        // plus rich amber-gold sodium streetlamps in highlights.
                        let nonWarmMid = midW * (1.0 - warmGate)
                        sr += -shadowW * 0.028 - nonWarmMid * 0.006 + highW * colorGate * 0.016
                        sg += shadowW * 0.036 + nonWarmMid * 0.008 + highW * colorGate * 0.008
                        sb += shadowW * 0.006 + nonWarmMid * 0.002 - highW * colorGate * 0.016
                        // Sodium streetlamps glow rich amber-gold
                        sr += warmGate * highW * 0.038
                        sg += warmGate * highW * 0.016
                        sb -= warmGate * highW * 0.032

                    case .negative:
                        // Contax T3 + Portra 400: clean neutral walls, warm-peach skin (not yellow),
                        // classic film cyan sky and cool emerald foliage.
                        let deepShadowDesat = (1.0 - smoothstep(0.0, 0.16, y1)) * 0.55
                        sr = sr + (y1 - sr) * deepShadowDesat
                        sg = sg + (y1 - sg) * deepShadowDesat
                        sb = sb + (y1 - sb) * deepShadowDesat
                        let skinWarm = (midW + highW * 0.72) * warmGate
                        sr += -shadowW * 0.003 + skinWarm * 0.022
                        sg += shadowW * 0.004 + skinWarm * 0.012
                        sb += shadowW * 0.002 - skinWarm * 0.034
                        // Portra-calibrated cool emerald foliage & cyan sky
                        sr -= foliageGate * 0.034
                        sg += foliageGate * 0.024 + skyGate * 0.056
                        sb += foliageGate * 0.042

                    case .mono:
                        // Ricoh GR Digital: pure neutral silver monochrome (tone curve already provides dramatic contrast).
                        let monoY = 0.2126 * sr + 0.7152 * sg + 0.0722 * sb
                        sr = monoY
                        sg = monoY
                        sb = monoY
                    }

                    values.append(srgbToLinear(sr))
                    values.append(srgbToLinear(sg))
                    values.append(srgbToLinear(sb))
                    values.append(1)
                }
            }
        }
        let data = values.withUnsafeBytes { Data($0) }
        characterCubes[look] = data
        return data
    }

    /// Soft shoulder, built per look because every look has its own white point
    /// (A7 0.94, A8 0.93, C1 0.97, N2 0.95). A single global curve pushed flash
    /// skin past its red ceiling and lifted C1's white shirt above the reviewed
    /// 242 limit; compressing into each look's own white point avoids both.
    ///
    /// Below 75% of the white point the value is untouched. Above it, the slope
    /// eases to zero at the white point, so neon and window light roll off
    /// instead of stopping dead.
    nonisolated(unsafe) private static var shoulderCubes: [String: Data] = [:]
    private static let shoulderLock = NSLock()

    private static func shoulderCube(white: CGFloat) -> Data {
        let key = String(format: "%.3f", Double(white))
        shoulderLock.lock()
        defer { shoulderLock.unlock() }
        if let cached = shoulderCubes[key] { return cached }

        let dimension = 32
        // Roll off smoothly in the top 28% so bright speculars (neon signs,
        // headlights, catchlights) sparkle cleanly before easing into whiteClamp.
        let knee = 0.72
        func shoulder(_ x: Float) -> Float {
            let w = Float(white)
            let u = x / w
            if u <= Float(knee) { return x }
            let k = Float(knee)
            let delta = 1.0 - k
            let t = min(max((u - k) / delta, 0), 1)
            // g(t) = t * (1 + t - t^2) ensures g'(0) = 1 (matching linear slope with C1 continuity)
            // and g'(1) = 0 (smooth horizontal roll-off at the white clamp point)
            let g = t * (1.0 + t - t * t)
            return w * (k + delta * g)
        }

        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for blueIndex in 0..<dimension {
            for greenIndex in 0..<dimension {
                for redIndex in 0..<dimension {
                    let r = Float(redIndex) / Float(dimension - 1)
                    let g = Float(greenIndex) / Float(dimension - 1)
                    let b = Float(blueIndex) / Float(dimension - 1)
                    values.append(shoulder(r))
                    values.append(shoulder(g))
                    values.append(shoulder(b))
                    values.append(1)
                }
            }
        }
        let data = values.withUnsafeBytes { Data($0) }
        shoulderCubes[key] = data
        return data
    }

    private static let renderContext = ImagingColorPipeline.makeContext()

    var id: Self { self }

    var shortName: String {
        switch self { case .amber: "A7"; case .party: "A8"; case .chrome: "C1"; case .night: "N2"
        case .negative: "N1"
        case .mono: "M1"
        }
    }

    /// Asset catalog name for the de-branded camera body thumbnail shown in `LookSelector`.
    /// Adding `CameraBody<shortName>.imageset` to `Assets.xcassets` automatically upgrades
    /// the corresponding card from the stylized body render to the real product photo.
    var bodyAssetName: String {
        "CameraBody\(shortName)"
    }

    /// The two-word name a camera is remembered by. `shortName` stays the model
    /// code quoted in metadata, receipts and purchase rows; this is the word
    /// people say out loud ("shoot it on Party Flash"). Two words keep it
    /// inside one strip card at 6.8 pt.
    var personality: LocalizedStringResource {
        switch self {
        case .amber: "Warm 2003"
        case .party: "Party Flash"
        case .chrome: "Cold Sharp"
        case .night: "Green Grain"
        case .negative: "Color Film"

        case .mono: "Silver Mono"
        }
    }

    /// A7 and A8 are the two free cameras: one warm, one harsh flash. The paid
    /// tier sells the two recipes that need more compromise (soft day, sodium
    /// night), so the free tier still covers the two screenshots people share.
    var isFree: Bool { self == .amber || self == .party }

    /// SF Symbol used by the in-app camera guide. Kept next to the body list so a
    /// new camera automatically gets a row without editing the guide view.
    var guideSymbol: String {
        switch self {
        case .amber: "sun.max.fill"
        case .party: "bolt.circle.fill"
        case .chrome: "snowflake"
        case .night: "moon.stars.fill"
        case .negative: "film.stack.fill"
        case .mono: "circle.lefthalf.filled"
        }
    }

    var characterCode: String {
        switch self { case .amber: "WARM"; case .party: "FLASH"; case .chrome: "COOL"; case .night: "NIGHT"
        case .negative: "FILM"
        case .mono: "MONO"
        }
    }

    /// Functional one-liner for the camera's job. The strip now shows
    /// `personality` instead, so this is spoken by VoiceOver as the hint.
    /// Where this body belongs, in two words. The same information as
    /// `personality`, but phrased as a use case so a new user can pick a
    /// camera instead of reading four mood names.
    var sceneTag: LocalizedStringResource {
        switch self {
        case .amber: "Portrait · Street"
        case .party: "Party · Night"
        case .chrome: "Landscape · City"
        case .night: "Night · Rain"
        case .negative: "Street · Daylight"

        case .mono: "Street · Portrait"
        }
    }

    var stripCaption: String {
        switch self {
        case .amber: String(localized: "WARM FLASH")
        case .party: String(localized: "HARSH FLASH")
        case .chrome: String(localized: "SOFT DAY")
        case .night: String(localized: "NO FLASH")
        case .negative: String(localized: "COLOR FILM")

        case .mono: String(localized: "MONOCHROME")
        }
    }

    var proofMark: String {
        switch self {
        case .amber: "A7 MEMORY PROOF"
        case .party: "A8 PARTY PROOF"
        case .chrome: "C1 DIGITAL PROOF"
        case .night: "N2 NIGHT PROOF"
        case .negative: "N1 NEGATIVE PROOF"

        case .mono: "M1 SILVER PROOF"
        }
    }

    var accent: ColorToken {
        switch self {
        case .amber: .amber
        case .party: .red
        case .chrome: .blue
        case .night: .pink
        case .negative: .teal

        case .mono: .silver
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .amber: "Warm skin and family-trip color"
        case .party: "Hard flash, black background, party light"
        case .chrome: "Cool, crisp early-digital JPEG"
        case .night: "Sodium street light, no flash, green shadows"
        case .negative: "Teal shadows, warm creamy highlights, wide film latitude"

        case .mono: "Neutral black and white, gentle highlights, detailed shadows"
        }
    }

    static func stabilizedInput(_ input: CIImage, colorAnchor: CaptureColorAnchor?,
                                consistencyStrength: CGFloat) -> CIImage {
        guard let colorAnchor, consistencyStrength > 0 else { return input }
        return colorAnchor.stabilizing(input, strength: consistencyStrength)
    }

    func livePreview(
        _ input: CIImage,
        sensor: SensorIdentity,
        flashStrength: Double = 0,
        colorAnchor: CaptureColorAnchor? = nil,
        consistencyStrength: CGFloat = 0,
        balanceGain: Double? = nil,
        conditions: CaptureImagingConditions = .init()
    ) -> CIImage {
        // Both capture-only inputs are passed in: the flash falloff and the
        // roll colour anchor. Leaving them out made a night-flash frame look
        // like an ambient one in the viewfinder and then change after the
        // shutter — the two inputs were the whole difference.
        //
        // Stabilising measures the incoming frame, so it is skipped when the
        // strength is zero (it would be an identity pass 24 times a second).
        let stabilized = Self.stabilizedInput(input, colorAnchor: colorAnchor,
                                             consistencyStrength: consistencyStrength)
        let preview = lensCharacter(
            processed(
                stabilized,
                sensorSeed: sensor.seed,
                flashed: flashStrength > 0.5,
                balanceGain: balanceGain,
                conditions: conditions
            ),
            flashed: flashStrength > 0.5,
            flashStrength: flashStrength
        )
        return preview.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: blackClamp, y: blackClamp, z: blackClamp, w: 0),
            "inputMaxComponents": CIVector(x: whiteClamp, y: whiteClamp, z: whiteClamp, w: 1)
        ])
    }

    func videoFrame(_ input: CIImage, sensor: SensorIdentity,
                    balanceGain: Double? = nil,
                    conditions: CaptureImagingConditions = .init()) -> CIImage {
        // A Moment is one clip, not a sequence of stills: measuring the scene
        // on every frame made blue gain jump between 0.92 and 1.08 and the
        // colour visibly breathe. The caller measures the first frame once and
        // passes that gain for the whole export.
        processed(input, sensorSeed: sensor.seed, balanceGain: balanceGain,
                  conditions: conditions).cropped(to: input.extent)
    }

    /// Stage controls for calibration; defaults match the normal camera path.
    struct RenderEffects: OptionSet, Sendable {
        let rawValue: Int
        static let redGuard = Self(rawValue: 1 << 0)
        static let bloom = Self(rawValue: 1 << 1)
        static let halation = Self(rawValue: 1 << 2)
        static let diffusion = Self(rawValue: 1 << 3)
        static let shoulder = Self(rawValue: 1 << 4)
        static let temperature = Self(rawValue: 1 << 5)
        static let saturation = Self(rawValue: 1 << 6)
        static let brightness = Self(rawValue: 1 << 7)
        static let lumaContrast = Self(rawValue: 1 << 8)
        static let toneCurve = Self(rawValue: 1 << 9)
        static let flashFalloff = Self(rawValue: 1 << 10)
        static let denoise = Self(rawValue: 1 << 11)
        static let grain = Self(rawValue: 1 << 12)
        static let all: Self = [.redGuard, .bloom, .halation, .diffusion, .shoulder, .temperature,
                                .saturation, .brightness, .lumaContrast, .toneCurve, .flashFalloff, .denoise, .grain]
    }

    func render(
        _ image: UIImage,
        dateStamp: Bool,
        aspectRatio: CaptureAspectRatio = .fourThree,
        sensor: SensorIdentity = .current(),
        colorAnchor: CaptureColorAnchor? = nil,
        consistencyStrength: CGFloat = 0,
        stampDate: Date = .now,
        flash: Double = 0,
        focalCrop: CGFloat = 1,
        dateStampFormat: DateStampFormat = .dayMonthYear,
        effects: RenderEffects = .all,
        conditions: CaptureImagingConditions = .init()
    ) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }

        // The 50 mm setting is a centre crop of the 35 mm frame, not a lens
        // change: the CCD stays one camera with one lens, and the crop keeps
        // the same look pipeline.
        let crop = aspectRatio.cropRect(in: input.extent, focalCrop: focalCrop)
        let croppedInput = input.cropped(to: crop)
        let stabilizedInput = Self.stabilizedInput(croppedInput, colorAnchor: colorAnchor,
                                                   consistencyStrength: consistencyStrength)
        var adjusted = processed(stabilizedInput, sensorSeed: sensor.seed, flashed: flash > 0.5, effects: effects, conditions: conditions)
        if effects.contains(.flashFalloff) {
            adjusted = lensCharacter(adjusted, flashed: flash > 0.5, flashStrength: flash)
        }
        // lensCharacter runs after the look's own clamp; guard once more so its
        // chromatic channels cannot push a highlight back to pure white.
        adjusted = adjusted.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: blackClamp, y: blackClamp, z: blackClamp, w: 0),
            "inputMaxComponents": CIVector(x: whiteClamp, y: whiteClamp, z: whiteClamp, w: 1)
        ])

        guard let cgImage = ImagingColorPipeline.displayImage(adjusted, using: Self.renderContext) else { return nil }
        // Camera captures already arrive in upright pixels via `videoRotationAngle`
        // + `decodedCapture`; imported photos bake their EXIF orientation here so
        // the date stamp always lands horizontally upright in the bottom-right corner.
        let filtered = UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
            .withOrientationBakedIn()
        return dateStamp ? DateStampRenderer.addStamp(to: filtered, camera: self, date: stampDate,
                                                       stampFormat: dateStampFormat) : filtered
    }

    /// Bounded scene white balance.
    ///
    /// A fixed temperature per look is what let A7 drift blue at dusk (R/B 0.64)
    /// while A8 drifted red on a sodium street (R/B 1.70). Correcting the whole
    /// way to neutral would erase the cameras' character, so this only touches
    /// extreme casts and never moves a channel more than 8%.
    private func sceneBalanced(_ input: CIImage, gainOverride: Double? = nil) -> CIImage {
        // The average needs a GPU readback, which stalls the pipeline. Only the
        // live preview may reuse a cached value; a still frame must measure its
        // own image, otherwise a render inherits the cast of whatever was on
        // screen half a second earlier.
        let gainBlue: Double
        if let gainOverride {
            gainBlue = gainOverride
        } else {
            guard let average = Self.averageColor(input) else { return input }
            gainBlue = Self.blueGain(red: average.0, blue: average.2)
        }
        guard abs(gainBlue - 1) > 0.002 else { return input }
        return input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gainBlue), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    static func sceneBlueGain(_ input: CIImage) -> Double {
        averageColor(input).map { blueGain(red: $0.0, blue: $0.2) } ?? 1
    }

    /// Pure decision behind the bounded correction, so the edges can be tested
    /// without a camera: deadband in the middle, ±8 % at the extremes.
    static func blueGain(red: Double, blue: Double) -> Double {
        guard red.isFinite, blue.isFinite else { return 1 }
        let ratio = max(red, 0.02) / max(blue, 0.02)
        // Fade into the existing correction over a narrow transition band.
        // Keep established casts outside that band, including A7's neutral-card
        // warmth, while avoiding a sudden 8% jump at a deadband edge.
        let target: Double
        let distance: Double
        if ratio > 1.60 {
            target = min(pow(ratio / 1.35, 0.45), 1.08)
            distance = (ratio - 1.60) / 0.05
        } else if ratio < 1.05 {
            target = max(pow(ratio / 1.30, 0.45), 0.92)
            distance = (1.05 - ratio) / 0.05
        } else {
            return 1
        }
        let t = min(max(distance, 0), 1)
        let weight = t * t * (3 - 2 * t)
        let gain = 1 + (target - 1) * weight
        return min(max(gain, 0.92), 1.08)
    }

    private static func averageColor(_ input: CIImage) -> (Double, Double, Double)? {
        guard let average = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: input,
                kCIInputExtentKey: CIVector(cgRect: input.extent)
            ]
        )?.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        renderContext.render(
            average,
            toBitmap: &pixel,
            rowBytes: MemoryLayout<Float>.size * 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        return (Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
    }

    private func processed(
        _ input: CIImage,
        sensorSeed: UInt64,
        flashed: Bool = false,
        balanceGain: Double? = nil,
        grainStrength: CGFloat = 1,
        effects: RenderEffects = .all,
        conditions: CaptureImagingConditions = .init()
    ) -> CIImage {
        let extent = input.extent
        // Preview frames arrive at ~1280 px while exports are ~3024–4032 px.
        // Bloom radius and stripe width are pixel-space effects, so without this
        // normalisation the live preview showed roughly three times the glow and
        // banding of the saved photo.
        let pitch = max(min(extent.width, extent.height) / 3024, 0.02)
        let balanced = sceneBalanced(input, gainOverride: conditions.allowsSceneWhiteBalance ? balanceGain : 1)
        // The direct chain is back: the 65³ tone table measured 13–24% off
        // 1.0.0 on the same scene (luma 0.469 vs 0.415, sat 0.476 vs 0.623)
        // even with every parameter reverted, so the bake itself was moving
        // the picture. The table stays in the file for the preview experiment;
        // the finished frame runs the original filters.
        let gradeInput = self == .mono ? Self.monochrome(balanced) : balanced
        let exposed = gradeInput.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposureEV])
        let amount = effects.contains(.saturation) ? (self == .amber && flashed ? 1.18 : saturation) : 1
        let saturated = self == .amber || self == .party
            ? Self.warmSafeSaturation(exposed, amount: amount)
            : exposed.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: amount])
        // N2's negative per-channel offset clipped blue/green in dark skin.
        // Keep its midtone trim, but limit shadow loss to 15% and use one RGB gain.
        let trimmed = self == .night && effects.contains(.brightness)
            ? Self.lumaContrasted(saturated, strength: 1, brightness: brightness, minimumGain: 0.85)
            : saturated
        var colorAdjusted = trimmed
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1,
                kCIInputContrastKey: contrast,
                kCIInputBrightnessKey: effects.contains(.brightness) && self != .night ? brightness : 0
            ])
            .applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": effects.contains(.temperature)
                    ? CIVector(x: temperature(flashed: flashed), y: tint) : CIVector(x: 6500, y: 0)
            ])
            .applyingFilter("CIToneCurve", parameters: effects.contains(.toneCurve) ? toneCurveParameters : Self.identityToneCurve)
        colorAdjusted = Self.lumaContrasted(colorAdjusted, strength: effects.contains(.lumaContrast) ? lumaContrast : nil,
                                                  minimumGain: self == .night ? 0.90 : (self == .mono ? 0.75 : (self == .chrome ? 0.65 : 0)))
        if effects.contains(.toneCurve) {
            colorAdjusted = colorAdjusted.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": 33,
                "inputCubeData": Self.cameraCharacterCube(for: self)
            ])
        }
        if effects.contains(.redGuard) {
            colorAdjusted = colorAdjusted.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": Self.redGuardDimension,
                "inputCubeData": Self.redGuardCube(strength: redGuardStrength(flashed: flashed),
                                                         smoothHighlights: flashed && (self == .amber || self == .party))
            ])
        }
        let colorGraded = colorAdjusted
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: blackClamp, y: blackClamp, z: blackClamp, w: 0),
                "inputMaxComponents": CIVector(x: whiteClamp, y: whiteClamp, z: whiteClamp, w: 1)
            ])
            .applyingFilter("CIVignetteEffect", parameters: [
                "inputCenter": CIVector(x: extent.midX, y: extent.midY),
                "inputRadius": min(extent.width, extent.height) * 0.78,
                "inputIntensity": vignette,
                "inputFalloff": 0.65
            ])

        // Avoid second-layer HDR flattening (CIHighlightShadowAdjust with highlight < 1
        // and shadowLift > 0) that previously washed out CCD contrast on top of Apple's ISP.
        let shadowAdjusted = shadowLift > 0.001
            ? colorGraded.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": shadowLift,
                "inputHighlightAmount": 1.0
            ])
            : colorGraded
        let bloomed = shadowAdjusted
            .applyingFilter("CIBloom", parameters: [
                kCIInputIntensityKey: effects.contains(.bloom) ? bloomIntensity : 0,
                kCIInputRadiusKey: max(0.5, bloomRadius * pitch)
            ])
            .cropped(to: extent)
        let glow = effects.contains(.halation) ? halationGlow(bloomed, pitch: pitch) : bloomed

        // Consumer CCD JPEG engines characteristically smoothed chroma noise
        // and then added conspicuous edge sharpening. Keeping both stages is
        // more convincing than placing film grain over a modern clean image.
        let diffused = effects.contains(.diffusion) ? diffusionGlow(glow, pitch: pitch) : glow
        let denoised = effects.contains(.denoise) ? diffused
            .applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": (self == .night ? Self.nightNoiseReduction(iso: conditions.iso) : noiseReduction) * conditions.denoiseScale,
                "inputSharpness": noiseReductionSharpness * conditions.sharpeningScale
            ]) : diffused
        let sharpened = denoised.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: sharpening * conditions.sharpeningScale
        ])

        // Organic silver-halide film grain blended symmetrically in perceptual sRGB
        // via SoftLight (0.5 = identity). Unlike additive linear noise, SoftLight
        // naturally darkens AND brightens midtones while tapering smoothly to zero
        // in deep shadows and pure highlights — eliminating bright "white snow" dots
        // on dark clothing and preserving clean skies.
        let offsetX = CGFloat(sensorSeed & 0x3FF)
        let offsetY = CGFloat((sensorSeed >> 10) & 0x3FF)
        let textureScale = self == .night || self == .mono ? Self.nightGrainScale(iso: conditions.iso) : conditions.grainScale
        let noiseAmount = effects.contains(.grain) ? grain * grainStrength * textureScale : 0
        let withNoise: CIImage
        if noiseAmount > 0.0005, let rawNoise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let grainScale = max(min(extent.width, extent.height) / 1600, 0.02)
            let crystalBlur = max(0.35, 0.45 * grainScale)
            // CIRandomGenerator produces random alpha in [0, 1]; clamp alpha to 1.0
            // BEFORE blur/matrix so Core Image never unpremultiplies RGB / (~0) into
            // explosive HDR white pinhole speckles.
            let opaqueNoise = rawNoise.applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
            let scaledNoise = opaqueNoise
                .transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
                .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
                .cropped(to: extent.insetBy(dx: -4, dy: -4))
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: crystalBlur])
                .cropped(to: extent)
            let monoNoise = Self.neutralGrainSource(scaledNoise)
            let amplitude = min(noiseAmount * 4.5, 0.48)
            let bias = 0.5 - amplitude * 0.5
            let softLightLayer = monoNoise.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: amplitude, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: amplitude, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: amplitude, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1)
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
            let srgbBase = sharpened.applyingFilter("CILinearToSRGBToneCurve")
            let srgbGrained = softLightLayer
                .applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: srgbBase])
                .cropped(to: extent)
            withNoise = srgbGrained.applyingFilter("CISRGBToneCurveToLinear")
        } else {
            withNoise = sharpened
        }

        let stripes: CIImage? = nil

        let composited = stripes?
            .applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: withNoise])
            .cropped(to: extent) ?? withNoise

        // Final guard: bloom and stripes run after the first clamp, so clamp
        // again to keep every channel under the look's white point. The shoulder
        // runs just before it and compresses into that same white point.
        let shouldered = effects.contains(.shoulder) ? composited.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": 32,
            "inputCubeData": Self.shoulderCube(white: whiteClamp)
        ]) : composited
        let finalImage = self == .mono ? Self.monochrome(shouldered) : shouldered
        return finalImage
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: blackClamp, y: blackClamp, z: blackClamp, w: 0),
                "inputMaxComponents": CIVector(x: whiteClamp, y: whiteClamp, z: whiteClamp, w: 1)
            ])
            .cropped(to: extent)
    }

    /// Continuous highlight energy in the linear working space. A binary
    /// threshold gave a barely-bright pixel the same glow as a white emitter.
    /// The soft ramp avoids flat, coloured patches on skin and around the sun.
    static func highlightSignal(_ image: CIImage, threshold: CGFloat) -> CIImage {
        let threshold = min(max(threshold, 0), 0.99)
        let gain = 1 / (1 - threshold)
        return image
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputBiasVector": CIVector(x: -threshold * gain, y: -threshold * gain,
                                           z: -threshold * gain, w: 0)
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
            .applyingFilter("CIColorPolynomial", parameters: [
                "inputRedCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
                "inputGreenCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2),
                "inputBlueCoefficients": CIVector(x: 0, y: 0, z: 3, w: -2)
            ])
            .cropped(to: image.extent)
    }

    /// Red halation: threshold the highlights, blur them, add them back as a
    /// red-only glow. Bloom lifts the whole frame; halation colours the edge of
    /// a blown highlight, which is the part of the film signature the CCD look
    /// was missing.
    private func halationGlow(_ image: CIImage, pitch: CGFloat) -> CIImage {
        let strength = halationIntensity * Self.halationScale
        guard strength > 0 else { return image }
        let highlights = Self.highlightSignal(image, threshold: 0.68)
        let blurred = highlights.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2, 14 * pitch)])
            .cropped(to: image.extent)
        let tint = halationTintColor
        let glow = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: strength * tint.g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: strength * tint.b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        return image.applyingFilter("CILinearDodgeBlendMode", parameters: [
            kCIInputBackgroundImageKey: glow
        ]).cropped(to: image.extent)
    }

    /// Neutral mist, highlights only. Blurring the whole frame and screening
    /// it back lifted the dark side of every high-contrast edge — sky over a
    /// treeline became a white haze along the canopy, which is not what a
    /// physical mist filter does. The blur is now masked to the highlights, so
    /// they bloom while the shadows keep their density.
    private func diffusionGlow(_ image: CIImage, pitch: CGFloat) -> CIImage {
        let strength = diffusionStrength * Self.halationScale
        guard strength > 0 else { return image }
        let highlights = Self.highlightSignal(image, threshold: 0.62)
        let blurred = highlights.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, 9 * pitch)])
            .cropped(to: image.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
        return image.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: blurred
        ]).cropped(to: image.extent)
    }

    /// Applies luminance-only contrast when the look asks for it.
    private static func lumaContrasted(_ image: CIImage, strength: Double?,
                                       brightness: Double = 0, minimumGain: Double = 0) -> CIImage {
        guard let strength else { return image }
        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": 64,
            "inputCubeData": lumaContrastCube(strength: strength, brightness: brightness, minimumGain: minimumGain)
        ])
    }

    /// Direct-flash falloff, chromatic aberration and corner softness. Applied to
    /// captures only: at preview resolution these read as noise and cost frames.
    private func lensCharacter(_ image: CIImage, flashed: Bool, flashStrength: Double) -> CIImage {
        let extent = image.extent
        // Work on the capture extent so every effect remains cropped to the
        // original frame throughout the lens-character pipeline.
        var output = image

        if flashed {
            // Hardware flash already raises exposure in the captured pixels.
            // Protect highlights here instead of adding a second exposure lift;
            // the old positive adjustment caused white floors and paper to clip.
            output = output
                .applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputShadowAmount": 0.08,
                    "inputHighlightAmount": 1 - 0.20 * flashStrength
                ])
                .applyingFilter("CIExposureAdjust", parameters: [
                    kCIInputEVKey: -0.08 * flashStrength
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: 0,
                    kCIInputContrastKey: 1
                ])
                .applyingFilter("CIVignetteEffect", parameters: [
                    "inputCenter": CIVector(x: extent.midX, y: extent.midY),
                    "inputRadius": min(extent.width, extent.height) * 0.62,
                    "inputIntensity": flashVignette * flashStrength,
                    "inputFalloff": 0.45
                ])
                .cropped(to: extent)
        }

        return output
    }



    /// Hardware flash supplies its own subject/background falloff. Keep only
    /// a small optical vignette so dark clothes retain their original detail
    /// without falling into harsh black tunnel cutoffs.
    private var flashVignette: Double {
        switch self { case .amber: 0.28; case .party: 0.36; case .chrome: 0.28; case .night: 0.30
        case .negative: 0.28
        case .mono: 0.28
        }
    }

    /// Shadow density is now shaped cleanly inside each camera's perceptual sRGB
    /// 3D LUT without local HDR shadow lifting or highlight pulling.
    private var shadowLift: Double {
        0.0
    }

    /// Zero artificial post-ISP sharpening on film/portrait bodies to eliminate
    /// harsh Apple Deep Fusion skin-pore crispness; retain subtle bite on C1 and M1.
    private var sharpening: Double {
        switch self { case .amber: 0.0; case .party: 0.0; case .chrome: 0.10; case .night: 0.0
        case .negative: 0.0
        case .mono: 0.08
        }
    }

    /// Edge-preserving bilateral softening melts away Apple ISP digital pore
    /// sharpening while keeping eyes, hair, and structural edges crisp.
    private var noiseReduction: Double {
        switch self { case .amber: 0.032; case .party: 0.024; case .chrome: 0.014; case .night: 0.038
        case .negative: 0.034
        case .mono: 0.018
        }
    }

    /// Clean daylight already passed through the camera ISP. Strong N2
    /// denoising is reserved for genuinely high-ISO captures and unknown input.
    static func nightNoiseReduction(iso: Double?) -> Double {
        guard let iso, iso.isFinite, iso > 0 else { return 0.034 }
        let noise = min(max(log2(max(iso, 50) / 50) / 5, 0), 1)
        return 0.012 + 0.022 * noise
    }

    /// Sensor noise already supplies high-ISO texture. Added film grain must
    /// taper off instead of stacking more noise onto an ISO3200 negative.
    static func nightGrainScale(iso: Double?) -> CGFloat {
        guard let iso, iso.isFinite, iso > 0 else { return 0.35 }
        let noise = min(max(log2(max(iso, 50) / 50) / 5, 0), 1)
        return CGFloat(0.45 - 0.35 * noise)
    }

    static func monochrome(_ image: CIImage) -> CIImage {
        // Moderate yellow/orange filter mix: darkens blue skies dramatically
        // while keeping skin tones rich and dimensional (GRD street style).
        let mix = CIVector(x: 0.34, y: 0.60, z: 0.06, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": mix, "inputGVector": mix, "inputBVector": mix
        ])
    }

    static func neutralGrainSource(_ image: CIImage) -> CIImage {
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": luma, "inputGVector": luma, "inputBVector": luma,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    private var noiseReductionSharpness: Double {
        switch self { case .amber: 0.0; case .party: 0.0; case .chrome: 0.04; case .night: 0.0
        case .negative: 0.0
        case .mono: 0.04
        }
    }

    private var redNoise: CGFloat {
        switch self { case .amber: 0.85; case .party: 0.95; case .chrome: 1; case .night: 0.92
        case .negative: 0.88
        case .mono: 1
        }
    }

    private var greenNoise: CGFloat {
        switch self { case .amber: 0.72; case .party: 0.85; case .chrome: 0.82; case .night: 1.18
        case .negative: 0.94
        case .mono: 1
        }
    }

    private var blueNoise: CGFloat {
        switch self { case .amber: 0.78; case .party: 0.90; case .chrome: 1.12; case .night: 1.36
        case .negative: 1.15
        case .mono: 1
        }
    }

    private var banding: CGFloat {
        switch self { case .amber: 0.012; case .party: 0.014; case .chrome: 0.008; case .night: 0.026
        case .negative: 0.005
        case .mono: 0
        }
    }

    private var bandTint: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .amber: (0.9, 0.55, 0.2)
        case .party: (1.0, 0.60, 0.28)
        case .chrome: (0.2, 0.55, 0.9)
        case .night: (0.15, 0.78, 0.42)
        case .negative: (0.18, 0.72, 0.65)
        case .mono: (0, 0, 0)
        }
    }

    private var saturation: Double {
        switch self { case .amber: 1.28; case .party: 1.36; case .chrome: 1.18; case .night: 1.18
        case .negative: 1.24
        case .mono: 0
        }
    }

    private var contrast: Double {
        // Per-channel contrast stays at 1.0 so warm skin hue ratios never explode;
        // contrast is applied via luminance-preserving kernels and perceptual S-curves.
        switch self { case .amber: 1.0; case .party: 1.0; case .chrome: 1.0; case .night: 1.0
        case .negative: 1.0
        case .mono: 1.0
        }
    }

    /// Luminance-only contrast kept restrained because `cameraCharacterCube`
    /// already applies each camera's perceptual sRGB S-curve.
    private var lumaContrast: Double? {
        switch self {
        case .amber: 1.04
        case .party: 1.08
        case .night: 1.04
        case .chrome: 1.12
        case .negative: 1.03
        case .mono: 1.12
        }
    }

    private var brightness: Double {
        switch self { case .amber: 0.0; case .party: 0.0; case .chrome: 0.0; case .night: 0.0
        case .negative: 0.0
        case .mono: 0
        }
    }

    /// Per-camera white balance targets keeping neutral white walls clean while
    /// chroma-gated 3D cubes supply rich film skin & color character.
    private func temperature(flashed: Bool) -> CGFloat {
        switch self {
        case .amber: flashed ? 6080 : 5820
        case .party: flashed ? 6400 : 6250
        case .chrome: 7150
        case .night: 6750
        case .negative: 6550
        case .mono: 6500
        }
    }

    private var tint: CGFloat {
        // In Core Image CITemperatureAndTint: positive = green, negative = magenta.
        switch self { case .amber: 0; case .party: 0; case .chrome: 1; case .night: 3
        case .negative: 1
        case .mono: 0
        }
    }

    /// Natural wide-angle compact-lens corner falloff (matching ~0.78–0.82 corner/wall
    /// ratio without blacking out night skies).
    private var vignette: Double {
        switch self { case .amber: 0.26; case .party: 0.36; case .chrome: 0.24; case .night: 0.28
        case .negative: 0.30
        case .mono: 0.34
        }
    }

    private var bloomIntensity: Double {
        switch self { case .amber: 0.13; case .party: 0.18; case .chrome: 0.09; case .night: 0.16
        case .negative: 0.14
        case .mono: 0.05
        }
    }

    private var bloomRadius: Double {
        switch self { case .amber: 6; case .party: 5; case .chrome: 3; case .night: 8
        case .negative: 6
        case .mono: 3
        }
    }

    /// The colour halation adds. Pure red was pushing skin highlights into a
    /// red face (R/G 1.85 outdoors, 1.99 indoors); daylight bodies now get an
    /// orange glow, while N2 keeps the red it was tuned on.
    private var halationTintColor: (g: CGFloat, b: CGFloat) {
        switch self { case .night: (0.12, 0.04); default: (0.42, 0.10) }
    }

    /// Halation — the red glow a bright highlight throws back off the film
    /// base. A flash-lit face or a window edge is where it shows. It is a
    /// spatial effect, so it stays out of the tone LUT.
    private var halationIntensity: Double {
        switch self { case .amber: 0.14; case .party: 0.32; case .chrome: 0.08; case .night: 0.30
        case .negative: 0.20
        case .mono: 0
        }
    }

    /// A diffusion filter (black/white mist): the soft bloom a physical filter
    /// adds in front of the lens, strongest where the frame is bright. Unlike
    /// halation it is neutral in colour.
    private var diffusionStrength: Double {
        // C1 is the cold sharp body; a mist filter contradicts it. It gets none.
        switch self { case .amber: 0.14; case .party: 0.14; case .chrome: 0; case .night: 0.10
        case .negative: 0.17
        case .mono: 0
        }
    }

    /// Tactile, clearly visible organic midtone film grain at 12 MP (blended via
    /// sRGB SoftLight so dark clothes and bright skies stay clean).
    private var grain: CGFloat {
        switch self { case .amber: 0.032; case .party: 0.042; case .chrome: 0.028; case .night: 0.062
        case .negative: 0.036
        case .mono: 0.060
        }
    }

    private var blackClamp: CGFloat {
        0.0
    }

    var whiteClamp: CGFloat {
        switch self { case .amber: 0.968; case .party: 0.968; case .chrome: 0.94; case .night: 0.968
        case .negative: 0.968
        case .mono: 0.968
        }
    }

    /// Film density exposure offsets: gentle sculptural density that preserves
    /// night-sky detail and specular sparkle (no 1.5-stop dark crush).
    private var exposureEV: Double {
        switch self { case .amber: 0.0; case .party: -0.06; case .chrome: -0.04; case .night: -0.04
        case .negative: -0.04
        case .mono: -0.08
        }
    }

    private static var identityToneCurve: [String: Any] {
        Dictionary(uniqueKeysWithValues: (0..<5).map { index in
            let value = CGFloat(index) / 4
            return ("inputPoint\(index)", CIVector(x: value, y: value))
        })
    }

    /// Linear-space endpoint anchor; perceptual S-curve shaping is now performed
    /// cleanly inside `cameraCharacterCube(for:)` in sRGB space so shadows are
    /// never double-crushed or double-lifted.
    private var toneCurveParameters: [String: Any] {
        let top: CGFloat
        switch self {
        case .amber: top = 0.985
        case .party: top = 0.985
        case .chrome: top = 0.945
        case .night: top = 0.985
        case .negative: top = 0.985
        case .mono: top = 0.985
        }
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0.25, 0.25), (0.5, 0.5), (0.75, 0.75), (1, top)]
        return Dictionary(uniqueKeysWithValues: points.enumerated().map { index, point in
            ("inputPoint\(index)", CIVector(x: point.0, y: point.1))
        })
    }
}

enum CCDRescueRenderer {
    static func render(_ image: UIImage, diagnosis: RescueDiagnosis) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        // Work in upright space: the diagnosis rectangles come from Vision and
        // the returned image is orientation-normalized.
        let oriented = CIImage(cgImage: cgImage).oriented(image.cgOrientation)
        let rawExtent = oriented.extent
        let input = oriented.transformed(by: CGAffineTransform(
            translationX: -rawExtent.minX,
            y: -rawExtent.minY
        ))
        var output = input

        if diagnosis.faceShadow || diagnosis.clippedHighlight,
           let mask = faceMask(extent: input.extent, rects: diagnosis.faceRects) {
            let corrected = output.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": diagnosis.faceShadow ? 0.22 : 0.06,
                "inputHighlightAmount": diagnosis.clippedHighlight ? 0.72 : 0.9
            ])
            output = corrected.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: mask
            ])
        }
        if diagnosis.excessiveChromaNoise {
            output = output.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.025,
                "inputSharpness": 0.12
            ])
        }
        if diagnosis.mildBlur {
            output = output
                .applyingFilter("CISharpenLuminance", parameters: [
                    kCIInputSharpnessKey: 0.22
                ])
        }

        guard let rendered = CaptureColorAnchor.sharedRenderContext.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: .up)
    }

    private static func faceMask(extent: CGRect, rects: [CGRect]) -> CIImage? {
        rects.reduce(nil as CIImage?) { combined, rect in
            let expanded = rect.insetBy(dx: -rect.width * 0.18, dy: -rect.height * 0.22)
                .intersection(extent)
            guard !expanded.isEmpty else { return combined }
            let radius = max(expanded.width, expanded.height) * 0.65
            guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: expanded.midX, y: expanded.midY),
                "inputRadius0": radius * 0.45,
                "inputRadius1": radius,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.clear
            ])?.outputImage?.cropped(to: extent) else { return combined }
            guard let combined else { return gradient }
            return gradient.applyingFilter("CIMaximumCompositing", parameters: [
                kCIInputBackgroundImageKey: combined
            ]).cropped(to: extent)
        }
    }
}

enum CaptureAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case fourThree = "4:3"
    case square = "1:1"
    /// Instagram feed portrait. The familiar name is 4:5 (width:height), so the
    /// landscape value below is its reciprocal.
    case fourFive = "4:5"
    case sixteenNine = "16:9"

    var id: Self { self }

    var value: CGFloat {
        switch self {
        case .fourThree: 4 / 3
        case .square: 1
        case .fourFive: 5 / 4
        case .sixteenNine: 16 / 9
        }
    }

    /// The selected ratio is named in the familiar landscape form (4:3, 16:9),
    /// while a portrait camera preview needs the reciprocal geometry.
    var portraitValue: CGFloat { 1 / value }

    func cropRect(in extent: CGRect, focalCrop: CGFloat = 1) -> CGRect {
        let crop = aspectCropRect(in: extent)
        let factor = focalCrop.isFinite ? max(focalCrop, 1) : 1
        let width = crop.width / factor, height = crop.height / factor
        return CGRect(x: crop.midX - width / 2, y: crop.midY - height / 2,
                      width: width, height: height)
    }

    private func aspectCropRect(in extent: CGRect) -> CGRect {
        let targetRatio = extent.height > extent.width ? portraitValue : value
        let current = extent.width / extent.height
        if current > targetRatio {
            let width = extent.height * targetRatio
            return CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height)
        } else {
            let height = extent.width / targetRatio
            return CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height)
        }
    }
}

enum ColorToken: Equatable {
    case amber, red, blue, pink, silver, teal
}

/// Fixed retro stamp used by both the live preview and the burned-in photo:
/// day, month, two-digit year — `05 11 ’26`.
/// The date-print formats a compact camera offers. The stamp is a camera
/// artifact, so the calendar is pinned to Gregorian: `Calendar.current` would
/// print a Buddhist or Islamic year for users who selected one system-wide.
/// How much glow the lens is allowed to throw. One knob for both halation and
/// diffusion: they are the same physical story (light spilling through and
/// around the lens), so a user who wants a cleaner frame should not have to
/// turn off two separate things.
enum HalationLevel: Int, CaseIterable, Identifiable {
    case off = 0, light, standard, strong, maximum
    var id: Int { rawValue }
    var scale: Double {
        switch self {
        case .off: 0
        case .light: 0.5
        case .standard: 1
        case .strong: 1.6
        case .maximum: 2.2
        }
    }
    var title: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .standard: "Standard"
        case .strong: "Strong"
        case .maximum: "Maximum"
        }
    }
}

/// Adds the camera's date print to an already-rendered image, for sharing a
/// frame that was saved without one.
func stampedForSharing(_ image: UIImage, camera: CCDLook, date: Date,
                       format: DateStampFormat = .dayMonthYear) -> UIImage {
    DateStampRenderer.addStamp(to: image, camera: camera, date: date, stampFormat: format)
}

enum DateStampFormat: String, CaseIterable, Identifiable {
    case dayMonthYear, yearFirst, monthDayYear, dayTime
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .dayMonthYear: "20 11 ’26"
        case .yearFirst: "’26 11 20"
        case .monthDayYear: "11 20 ’26"
        case .dayTime: "20 11 21:34"
        }
    }
    func text(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = parts.day ?? 0
        let month = parts.month ?? 0
        let year = (parts.year ?? 0) % 100
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        switch self {
        case .dayMonthYear: return String(format: "%02d %02d ’%02d", day, month, year)
        case .yearFirst: return String(format: "’%02d %02d %02d", year, month, day)
        case .monthDayYear: return String(format: "%02d %02d ’%02d", month, day, year)
        case .dayTime: return String(format: "%02d %02d %02d:%02d", day, month, hour, minute)
        }
    }
}

enum PocketDateStamp {
    static func text(for date: Date) -> String {
        DateStampFormat.dayMonthYear.text(for: date)
    }
}

private enum DateStampRenderer {
    static func addStamp(to image: UIImage, camera: CCDLook, date: Date,
                         stampFormat: DateStampFormat = .dayMonthYear) -> UIImage {
        // `UIGraphicsImageRenderer(size:)` defaults to the screen scale (3 on
        // iPhone), while rendered captures carry scale 1. Without pinning the
        // format scale the stamp upscaled a 12 MP photo to ~109 MP (~439 MB per
        // frame) and three-frame modes held >1 GB, which triggered jetsam.
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(image.scale, 1)
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: image.size))

            let text = stampFormat.text(for: date)
            let fontSize = max(14, image.size.width * 0.022)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: stampColor(camera),
                .shadow: shadow
            ]
            let size = text.size(withAttributes: attributes)
            let margin = image.size.width * 0.045
            text.draw(at: CGPoint(x: image.size.width - size.width - margin,
                                  y: image.size.height - size.height - margin),
                      withAttributes: attributes)
        }
    }

    private static func stampColor(_ camera: CCDLook) -> UIColor {
        switch camera {
        case .amber: UIColor(red: 1, green: 0.58, blue: 0.12, alpha: 0.94)
        case .party: UIColor(red: 1, green: 0.30, blue: 0.26, alpha: 0.94)
        case .chrome: UIColor(red: 0.68, green: 0.85, blue: 1, alpha: 0.94)
        case .night: UIColor(red: 0.65, green: 1, blue: 0.74, alpha: 0.94)
        case .negative: UIColor(red: 0.35, green: 0.95, blue: 0.88, alpha: 0.94)
        case .mono: UIColor(white: 0.94, alpha: 0.94)
        }
    }

    private static var shadow: NSShadow {
        let value = NSShadow()
        value.shadowColor = UIColor.black.withAlphaComponent(0.65)
        value.shadowOffset = CGSize(width: 1, height: 2)
        value.shadowBlurRadius = 2
        return value
    }
}
