import CoreImage
import Vision
import UIKit

enum FrameAnalyzer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    /// Long side used for the Vision pass; see `assessSynchronously`.
    private static let analysisMaxSide: CGFloat = 1280

    private static func downsampled(_ image: CGImage, by scale: CGFloat) -> CGImage {
        let source = CIImage(cgImage: image)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent) ?? image
    }

    static func score(_ image: UIImage) async -> Double {
        await assess(image).overall
    }

    /// Analyze an exposure set concurrently while preserving its capture order.
    /// Sequence modes contain at most three frames, so this remains naturally
    /// bounded and avoids creating an unbounded pool of Vision requests.
    static func assessAll(_ images: [UIImage]) async -> [FrameAssessment] {
        guard images.count > 1 else {
            return images.isEmpty ? [] : [await assess(images[0])]
        }
        return await withTaskGroup(of: (Int, FrameAssessment).self) { group in
            for (index, image) in images.enumerated() {
                group.addTask {
                    (index, assessSynchronously(image))
                }
            }
            var indexed: [(Int, FrameAssessment)] = []
            indexed.reserveCapacity(images.count)
            for await result in group {
                indexed.append(result)
            }
            return indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    static func assess(_ image: UIImage) async -> FrameAssessment {
        await Task.detached(priority: .userInitiated) {
            assessSynchronously(image)
        }.value
    }

    private static func assessSynchronously(_ image: UIImage) -> FrameAssessment {
        guard let cgImage = image.cgImage else { return FrameAssessment.empty }
        let orientation = image.cgOrientation
        // Vision on a 4032×3024 frame was the single biggest cost between the
        // shutter and the result sheet. Face capture quality and landmarks do
        // not need full resolution: 1280 px is ~2.5× the largest face we care
        // about, and the rescue statistics already sample to 48 px.
        let longSide = CGFloat(max(cgImage.width, cgImage.height))
        let analysisScale = min(1, analysisMaxSide / max(longSide, 1))
        let analyzed = analysisScale < 1 ? downsampled(cgImage, by: analysisScale) : cgImage
        let face = faceQuality(analyzed, orientation: orientation)
        let detailScore = edgeEnergy(analyzed)
        // Vision returns boxes in the upright (orientation-applied) space.
        // Diagnose on an equally oriented image so face rectangles and the
        // radial rescue mask land on the same pixels.
        let oriented = CIImage(cgImage: analyzed).oriented(orientation)
        let rescue = rescueDiagnosis(oriented,
                                     faces: face.observations,
                                     sharpness: detailScore,
                                     analysisScale: analysisScale)
        return FrameAssessment(
            overall: face.quality * 0.72 + detailScore * 0.28,
            eyeOpenness: face.eyeOpenness,
            sharpness: detailScore,
            hasFaces: face.hasFaces,
            rescue: rescue
        )
    }

    private static func faceQuality(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> (quality: Double, eyeOpenness: Double, hasFaces: Bool, observations: [VNFaceObservation]) {
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let landmarkRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        do {
            try handler.perform([qualityRequest, landmarkRequest])
        } catch {
            return (0.45, 0.5, false, [])
        }

        let qualityFaces = qualityRequest.results ?? []
        let landmarkFaces = landmarkRequest.results ?? []
        guard !qualityFaces.isEmpty || !landmarkFaces.isEmpty else { return (0.48, 0.5, false, []) }

        let averageQuality = qualityFaces.isEmpty
            ? 0.55
            : qualityFaces.map { Double($0.faceCaptureQuality ?? 0.5) }.reduce(0, +)
                / Double(qualityFaces.count)
        let openEyeRatio = landmarkFaces.isEmpty
            ? 0.65
            : landmarkFaces.map(eyesAppearOpen).reduce(0, +) / Double(landmarkFaces.count)
        return (averageQuality * 0.65 + openEyeRatio * 0.35, openEyeRatio, true,
                landmarkFaces.isEmpty ? qualityFaces : landmarkFaces)
    }

    private static func rescueDiagnosis(
        _ input: CIImage,
        faces: [VNFaceObservation],
        sharpness: Double,
        analysisScale: CGFloat
    ) -> RescueDiagnosis {
        let rawExtent = input.extent
        let normalized = input.transformed(by: CGAffineTransform(
            translationX: -rawExtent.minX,
            y: -rawExtent.minY
        ))
        let extent = normalized.extent
        let overall = statistics(normalized, extent: extent)
        // Boxes arrive normalised, so they are measured in the analysed frame
        // and scaled back to the captured frame; `RescueDiagnosis.faceRects`
        // keeps meaning "pixels of the saved photo".
        let statsRects = faces.map { observation in
            CGRect(
                x: observation.boundingBox.minX * extent.width,
                y: observation.boundingBox.minY * extent.height,
                width: observation.boundingBox.width * extent.width,
                height: observation.boundingBox.height * extent.height
            ).intersection(extent)
        }.filter { !$0.isEmpty }
        let faceRects = statsRects.map { rect in
            CGRect(x: rect.minX / analysisScale, y: rect.minY / analysisScale,
                   width: rect.width / analysisScale, height: rect.height / analysisScale)
        }
        let faceStats = statsRects.map { statistics(normalized, extent: $0) }
        let faceShadow = faceStats.contains { $0.luminance < 0.32 && overall.luminance > $0.luminance + 0.08 }
        let clippedHighlight = faceStats.contains { $0.highlightFraction > 0.035 }
        let excessiveNoise = overall.chromaSpread > 0.19 && overall.luminance < 0.38
        let mildBlur = sharpness < 0.5
        return RescueDiagnosis(
            faceShadow: faceShadow,
            clippedHighlight: clippedHighlight,
            excessiveChromaNoise: excessiveNoise,
            mildBlur: mildBlur,
            faceRects: faceRects
        )
    }

    private static func statistics(_ image: CIImage, extent: CGRect) -> (luminance: Double, highlightFraction: Double, chromaSpread: Double) {
        let sample = image.cropped(to: extent).transformed(by: CGAffineTransform(
            scaleX: min(48 / max(extent.width, 1), 1),
            y: min(48 / max(extent.height, 1), 1)
        ))
        guard let cg = context.createCGImage(sample, from: sample.extent) else { return (0.5, 0, 0) }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let bitmap = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0.5, 0, 0) }
        bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var luminance = 0.0, highlights = 0.0, chroma = 0.0
        let count = max(width * height, 1)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Double(bytes[index]) / 255, g = Double(bytes[index + 1]) / 255, b = Double(bytes[index + 2]) / 255
            let y = r * 0.2126 + g * 0.7152 + b * 0.0722
            luminance += y
            if max(r, g, b) > 0.985 { highlights += 1 }
            chroma += max(r, g, b) - min(r, g, b)
        }
        return (luminance / Double(count), highlights / Double(count), chroma / Double(count))
    }

    private static func eyesAppearOpen(_ face: VNFaceObservation) -> Double {
        guard let left = face.landmarks?.leftEye?.normalizedPoints,
              let right = face.landmarks?.rightEye?.normalizedPoints else { return 0.6 }
        return (eyeOpenness(left) + eyeOpenness(right)) / 2
    }

    private static func eyeOpenness(_ points: [CGPoint]) -> Double {
        guard points.count >= 4 else { return 0.5 }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return 0.5 }
        let width = max(maxX - minX, 0.001)
        let ratio = (maxY - minY) / width
        return min(max(Double((ratio - 0.08) / 0.16), 0), 1)
    }

    private static func edgeEnergy(_ image: CGImage) -> Double {
        let input = CIImage(cgImage: image)
        let scaled = input.transformed(by: CGAffineTransform(
            scaleX: min(320 / input.extent.width, 1),
            y: min(320 / input.extent.height, 1)
        ))
        let edges = scaled.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 2.2])
        let extent = edges.extent
        guard !extent.isEmpty,
              let average = CIFilter(
                name: "CIAreaAverage",
                parameters: [kCIInputImageKey: edges, kCIInputExtentKey: CIVector(cgRect: extent)]
              )?.outputImage else { return 0.45 }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let luminance = (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
        return min(luminance * 3.2, 1)
    }
}

struct FrameAssessment: Sendable {
    let overall: Double
    let eyeOpenness: Double
    let sharpness: Double
    let hasFaces: Bool
    let rescue: RescueDiagnosis

    static let empty = FrameAssessment(overall: 0, eyeOpenness: 0, sharpness: 0, hasFaces: false, rescue: .none)

    func ranksBefore(_ other: FrameAssessment) -> Bool {
        if hasFaces && other.hasFaces, abs(eyeOpenness - other.eyeOpenness) > 0.08 {
            return eyeOpenness > other.eyeOpenness
        }
        return overall > other.overall
    }
}

struct RescueDiagnosis: Sendable {
    let faceShadow: Bool
    let clippedHighlight: Bool
    let excessiveChromaNoise: Bool
    let mildBlur: Bool
    let faceRects: [CGRect]

    static let none = RescueDiagnosis(
        faceShadow: false, clippedHighlight: false,
        excessiveChromaNoise: false, mildBlur: false, faceRects: []
    )

    var needsRescue: Bool { faceShadow || clippedHighlight || excessiveChromaNoise || mildBlur }

    var summary: String {
        var parts: [LocalizedStringResource] = []
        if faceShadow { parts.append("face shadow") }
        if clippedHighlight { parts.append("flash highlight") }
        if excessiveChromaNoise { parts.append("night color noise") }
        if mildBlur { parts.append("low detail") }
        return parts.map { String(localized: $0) }.joined(separator: ", ")
    }
}

