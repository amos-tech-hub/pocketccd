#!/usr/bin/env swift

// Turns a `PocketCCD Originals` archive into a measurement table.
//
// The in-app archive (`OriginalFrameArchive`) stores one folder per shutter
// press with the unprocessed frames plus `capture.json`. This script reads that
// archive, measures every frame the same way `analyze_samples.swift` does
// (1024 px thumbnail, DeviceRGB, normalised pixels), and adds the two things the
// night-flash work actually needs:
//
//   * a face region — auto-detected, or the lit half of it — for skin ratios;
//   * the modal dark level outside the face, i.e. the real black floor.
//
// Usage:
//   swift Research/originals_report.swift <archive-root> [options]
//
//   --roi   <file.csv>   manual face boxes: file,x,y,width,height (normalised,
//                        top-left origin). `file` may be a bare frame name or
//                        `<capture folder>/<frame name>`. Overrides detection.
//   --csv   <file.csv>   where to write the frame table (default: <root>/originals-report.csv)
//   --quiet              only write the CSV, no markdown summary
//
// Gates come from docs/NIGHT_FLASH_TUNING_2026-11-15.md §7 and only describe
// what that experiment established: lit-side skin R/G, R/B and the black floor
// for direct flash, plus a daylighight sanity band. They are advisory — a
// verdict of "—" means the scene type could not be inferred, not that it passed.

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

// MARK: - CLI

struct Options {
    var root: URL
    var roiFile: URL?
    var csvFile: URL
    var quiet: Bool
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: swift Research/originals_report.swift <archive-root> [--roi face.csv] [--csv out.csv] [--quiet]

    """.utf8))
    exit(2)
}

func parseOptions() -> Options {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let first = args.first, !first.hasPrefix("--") else { usage() }
    var options = Options(
        root: URL(fileURLWithPath: first),
        roiFile: nil,
        csvFile: URL(fileURLWithPath: first).appendingPathComponent("originals-report.csv"),
        quiet: false
    )
    var index = 1
    while index < args.count {
        switch args[index] {
        case "--roi":
            index += 1
            guard index < args.count else { usage() }
            options.roiFile = URL(fileURLWithPath: args[index])
        case "--csv":
            index += 1
            guard index < args.count else { usage() }
            options.csvFile = URL(fileURLWithPath: args[index])
        case "--quiet":
            options.quiet = true
        default:
            usage()
        }
        index += 1
    }
    return options
}

// MARK: - Archive reading

struct CaptureManifest: Decodable {
    struct Frame: Decodable {
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
    let exposureBias: Double
    let iso: Double
    let shutterSeconds: Double
    let whiteBalanceKelvin: Double
    let flashMode: String
    let frames: [Frame]
}

struct Capture {
    let folder: URL
    let manifest: CaptureManifest
}

func loadCaptures(root: URL) -> [Capture] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let folders = (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey]
    )) ?? []
    return folders
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .compactMap { folder -> Capture? in
            let manifestURL = folder.appendingPathComponent("capture.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(CaptureManifest.self, from: data) else { return nil }
            return Capture(folder: folder, manifest: manifest)
        }
        .sorted { $0.manifest.capturedAt < $1.manifest.capturedAt }
}

// MARK: - Regions

struct NormalizedRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect {
        let originX = x * Double(imageWidth)
        let originY = y * Double(imageHeight)
        let boxWidth = width * Double(imageWidth)
        let boxHeight = height * Double(imageHeight)
        let box = CGRect(x: originX, y: originY, width: boxWidth, height: boxHeight)
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        return box.intersection(bounds)
    }

    static func fromPixels(_ rect: CGRect, width: Int, height: Int) -> NormalizedRect {
        NormalizedRect(
            x: rect.minX / Double(width),
            y: rect.minY / Double(height),
            width: rect.width / Double(width),
            height: rect.height / Double(height)
        )
    }
}

func loadROIs(from url: URL?) -> [String: NormalizedRect] {
    guard let url, let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var result: [String: NormalizedRect] = [:]
    for line in contents.split(whereSeparator: \.isNewline) {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5,
              fields[0].lowercased() != "file",
              let x = Double(fields[1]), let y = Double(fields[2]),
              let width = Double(fields[3]), let height = Double(fields[4]),
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else { continue }
        result[fields[0]] = NormalizedRect(x: x, y: y, width: width, height: height)
    }
    return result
}

// MARK: - Pixel measurements

struct PixelBuffer {
    let data: [UInt8]
    let width: Int
    let height: Int

    func rgb(x: Int, y: Int) -> (Double, Double, Double) {
        let index = (y * width + x) * 4
        return (Double(data[index]) / 255, Double(data[index + 1]) / 255, Double(data[index + 2]) / 255)
    }
}

struct RegionStats {
    var count = 0
    var sumR = 0.0
    var sumG = 0.0
    var sumB = 0.0
    var sumLuma = 0.0
    var sumSaturation = 0.0
    var clipped = 0
    var black = 0
    // 0…255 histograms so medians survive without storing every pixel.
    var histogramR = [Int](repeating: 0, count: 256)
    var histogramG = [Int](repeating: 0, count: 256)
    var histogramB = [Int](repeating: 0, count: 256)
    var histogramLuma = [Int](repeating: 0, count: 256)

    var meanR: Double { count > 0 ? sumR / Double(count) : 0 }
    var meanG: Double { count > 0 ? sumG / Double(count) : 0 }
    var meanB: Double { count > 0 ? sumB / Double(count) : 0 }
    var meanLuma: Double { count > 0 ? sumLuma / Double(count) : 0 }
    var meanSaturation: Double { count > 0 ? sumSaturation / Double(count) : 0 }
    var clipRatio: Double { count > 0 ? Double(clipped) / Double(count) : 0 }
    var blackRatio: Double { count > 0 ? Double(black) / Double(count) : 0 }

    var medianR: Double { Self.median(histogramR, count: count) }
    /// Normalised to 0–1 like `meanLuma`, so the two columns share a scale.
    var medianLuma: Double { Self.median(histogramLuma, count: count) / 255 }
    var medianG: Double { Self.median(histogramG, count: count) }
    var medianB: Double { Self.median(histogramB, count: count) }

    /// Ratio of the channel medians, which is what the night-flash log reports
    /// ("受光侧 161/57/24 → R/G 2.82").
    var medianRoverG: Double { medianG > 0 ? medianR / medianG : 0 }
    var medianRoverB: Double { medianB > 0 ? medianR / medianB : 0 }

    static func median(_ histogram: [Int], count: Int) -> Double {
        guard count > 0 else { return 0 }
        let half = (count + 1) / 2
        var running = 0
        for (value, occurrences) in histogram.enumerated() {
            running += occurrences
            if running >= half { return Double(value) }
        }
        return 0
    }
}

func measure(_ buffer: PixelBuffer, in rect: CGRect) -> RegionStats {
    var stats = RegionStats()
    let minX = max(0, Int(rect.minX.rounded(.down)))
    let maxX = min(buffer.width - 1, Int(rect.maxX.rounded(.up)) - 1)
    let minY = max(0, Int(rect.minY.rounded(.down)))
    let maxY = min(buffer.height - 1, Int(rect.maxY.rounded(.up)) - 1)
    guard minX <= maxX, minY <= maxY else { return stats }
    for y in minY...maxY {
        for x in minX...maxX {
            let (r, g, b) = buffer.rgb(x: x, y: y)
            let maximum = max(r, g, b)
            let minimum = min(r, g, b)
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            stats.count += 1
            stats.sumR += r; stats.sumG += g; stats.sumB += b
            stats.sumLuma += luma
            stats.sumSaturation += maximum == 0 ? 0 : (maximum - minimum) / maximum
            stats.histogramR[Int((r * 255).rounded())] += 1
            stats.histogramG[Int((g * 255).rounded())] += 1
            stats.histogramB[Int((b * 255).rounded())] += 1
            stats.histogramLuma[Int((luma * 255).rounded())] += 1
            if maximum >= 250.0 / 255.0 { stats.clipped += 1 }
            if luma <= 0.04 { stats.black += 1 }
        }
    }
    return stats
}

/// Histogram of luminance outside `exclude`, with the share held by its most
/// common dark bin. This reproduces the "黑位主峰 16 @ 29.8%" column.
func blackFloor(_ buffer: PixelBuffer, excluding exclude: CGRect?) -> (level: Int, share: Double) {
    var histogram = [Int](repeating: 0, count: 256)
    var counted = 0
    for y in 0..<buffer.height {
        for x in 0..<buffer.width where exclude?.contains(CGPoint(x: x, y: y)) != true {
            let (r, g, b) = buffer.rgb(x: x, y: y)
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            histogram[Int((luma * 255).rounded())] += 1
            counted += 1
        }
    }
    guard counted > 0 else { return (0, 0) }
    let searchRange = 0..<80
    let level = searchRange.max { histogram[$0] < histogram[$1] } ?? 0
    return (level, Double(histogram[level]) / Double(counted))
}

/// High-frequency residual outside highlights — the same definition as
/// `analyze_samples.swift`, so numbers stay comparable.
func grainProxy(_ buffer: PixelBuffer, in rect: CGRect) -> Double {
    var total = 0.0
    var count = 0
    let minX = max(1, Int(rect.minX))
    let maxX = min(buffer.width - 2, Int(rect.maxX) - 1)
    let minY = max(1, Int(rect.minY))
    let maxY = min(buffer.height - 2, Int(rect.maxY) - 1)
    guard minX <= maxX, minY <= maxY else { return 0 }
    for y in minY...maxY {
        for x in minX...maxX {
            let center = buffer.rgb(x: x, y: y)
            let centerLuma = 0.2126 * center.0 + 0.7152 * center.1 + 0.0722 * center.2
            guard centerLuma < 0.9 else { continue }
            let left = buffer.rgb(x: x - 1, y: y)
            let right = buffer.rgb(x: x + 1, y: y)
            let up = buffer.rgb(x: x, y: y - 1)
            let down = buffer.rgb(x: x, y: y + 1)
            let n = [left, right, up, down].map { 0.2126 * $0.0 + 0.7152 * $0.1 + 0.0722 * $0.2 }
            let neighbours = n.reduce(0, +) / 4
            total += abs(centerLuma - neighbours)
            count += 1
        }
    }
    return count > 0 ? total / Double(count) : 0
}

// MARK: - Image loading and faces

func loadPixels(url: URL) -> PixelBuffer? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 1024
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let width = image.width
    let height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &data,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return PixelBuffer(data: data, width: width, height: height)
}

final class FaceFinder {
    private let detector = CIDetector(
        ofType: CIDetectorTypeFace,
        context: CIContext(options: [.useSoftwareRenderer: false]),
        options: [CIDetectorAccuracy: CIDetectorAccuracyLow, CIDetectorTracking: false]
    )

    /// Largest face as a top-left-origin pixel rect.
    func largestFace(in url: URL, imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
              ] as CFDictionary),
              let detector else { return nil }
        let faces = detector.features(in: CIImage(cgImage: image))
            .compactMap { $0 as? CIFaceFeature }
        guard let biggest = faces.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else {
            return nil
        }
        let bounds = biggest.bounds
        return CGRect(
            x: bounds.minX,
            y: Double(imageHeight) - Double(bounds.maxY),
            width: bounds.width,
            height: bounds.height
        )
    }
}

// MARK: - Gates

struct FrameRow {
    let capture: Capture
    let frame: CaptureManifest.Frame
    let frameIndex: Int
    let width: Int
    let height: Int
    let full: RegionStats
    let face: RegionStats?
    let litSide: String
    let blackLevel: Int
    let blackShare: Double
    let grain: Double
    let clippedAt255: Double

    var key: String { "\(capture.folder.lastPathComponent)/\(frame.fileName)" }
    var isFlashFrame: Bool { frame.role == "flash" || capture.manifest.flashMode == "FLASH" }
    var isDaylightGuess: Bool { !isFlashFrame && full.meanLuma >= 0.30 }
}

func gate(for row: FrameRow) -> (name: String, failed: [String])? {
    if row.isFlashFrame {
        guard let face = row.face else { return ("night-flash", ["no face region"]) }
        var failed: [String] = []
        if face.medianRoverG > 2.5 { failed.append("skin R/G \(fmt(face.medianRoverG)) > 2.5") }
        if face.medianRoverB > 4.0 { failed.append("skin R/B \(fmt(face.medianRoverB)) > 4.0") }
        if row.blackLevel > 8 { failed.append("black floor \(row.blackLevel) > 8") }
        return ("night-flash", failed)
    }
    if row.isDaylightGuess {
        let ratio = row.full.medianB > 0 ? row.full.medianR / row.full.medianB : 0
        var failed: [String] = []
        if ratio < 1.15 || ratio > 1.35 { failed.append("full R/B \(fmt(ratio)) outside 1.15–1.35") }
        if row.clippedAt255 > 0.001 { failed.append("255 cluster \(fmt(row.clippedAt255))") }
        return ("daylight", failed)
    }
    return nil
}

func fmt(_ value: Double, _ digits: Int = 3) -> String {
    String(format: "%.\(digits)f", value)
}

// MARK: - Main

let options = parseOptions()
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: options.root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    FileHandle.standardError.write(Data("not a directory: \(options.root.path)\n".utf8))
    exit(1)
}

let captures = loadCaptures(root: options.root)
guard !captures.isEmpty else {
    FileHandle.standardError.write(Data("no capture folders with capture.json in \(options.root.path)\n".utf8))
    exit(1)
}

let manualROIs = loadROIs(from: options.roiFile)
let finder = FaceFinder()
var rows: [FrameRow] = []

for capture in captures {
    for (index, frame) in capture.manifest.frames.enumerated() {
        let url = capture.folder.appendingPathComponent(frame.fileName)
        guard let buffer = loadPixels(url: url) else {
            FileHandle.standardError.write(Data("could not read \(url.path)\n".utf8))
            continue
        }

        var faceRect: CGRect?
        if let manual = manualROIs["\(capture.folder.lastPathComponent)/\(frame.fileName)"]
            ?? manualROIs[frame.fileName] {
            faceRect = manual.pixelRect(imageWidth: buffer.width, imageHeight: buffer.height)
        } else {
            faceRect = finder.largestFace(in: url, imageWidth: buffer.width, imageHeight: buffer.height)
        }

        var faceStats: RegionStats?
        var litSide = ""
        if let faceRect, faceRect.width >= 8, faceRect.height >= 8 {
            // "Lit side" is whichever half of the face is brighter; that is the
            // cheek the flash actually reached.
            let left = CGRect(x: faceRect.minX, y: faceRect.minY,
                              width: faceRect.width / 2, height: faceRect.height)
            let right = CGRect(x: faceRect.midX, y: faceRect.minY,
                               width: faceRect.width / 2, height: faceRect.height)
            let leftStats = measure(buffer, in: left)
            let rightStats = measure(buffer, in: right)
            if leftStats.meanLuma >= rightStats.meanLuma {
                faceStats = leftStats
                litSide = "left"
            } else {
                faceStats = rightStats
                litSide = "right"
            }
            if (faceStats?.count ?? 0) < 16 { faceStats = nil }
        }

        let blackFloorValue = blackFloor(buffer, excluding: faceRect)
        let full = measure(buffer, in: CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
        var at255 = 0
        for value in 250...255 { at255 += full.histogramR[value] + full.histogramG[value] + full.histogramB[value] }
        let channelCount = max(full.count * 3, 1)

        rows.append(FrameRow(
            capture: capture,
            frame: frame,
            frameIndex: index,
            width: buffer.width,
            height: buffer.height,
            full: full,
            face: faceStats,
            litSide: litSide,
            blackLevel: blackFloorValue.level,
            blackShare: blackFloorValue.share,
            grain: grainProxy(buffer, in: CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height)),
            clippedAt255: Double(at255) / Double(channelCount)
        ))
    }
}

guard !rows.isEmpty else {
    FileHandle.standardError.write(Data("no readable frames\n".utf8))
    exit(1)
}

// MARK: - CSV

var csv = """
capture,folder,frame,role,frame_index,camera,position,mode,lens,iso,shutter,ev,kelvin,flash_state,\
width,height,mean_r,mean_g,mean_b,skin_r_over_g,skin_r_over_b,luma_p50,mean_luma,saturation,\
clip_ratio,black_ratio,black_floor,black_share,grain_proxy,face_found,lit_side,gate,verdict,failed_checks

"""
for row in rows {
    let m = row.capture.manifest
    let gateResult = gate(for: row)
    let failed = gateResult?.failed ?? []
    let verdict = gateResult == nil ? "—" : (failed.isEmpty ? "pass" : "fail")
    let fields: [String] = [
        String(format: "%.0f", m.capturedAt.timeIntervalSince1970),
        row.capture.folder.lastPathComponent,
        row.frame.fileName,
        row.frame.role,
        String(row.frameIndex),
        m.camera,
        m.cameraPosition,
        m.mode,
        m.lens,
        String(format: "%.0f", m.iso),
        String(format: "%.4f", m.shutterSeconds),
        String(format: "%.2f", m.exposureBias),
        String(format: "%.0f", m.whiteBalanceKelvin),
        m.flashMode,
        String(row.width),
        String(row.height),
        fmt(row.full.meanR), fmt(row.full.meanG), fmt(row.full.meanB),
        row.face.map { fmt($0.medianRoverG) } ?? "",
        row.face.map { fmt($0.medianRoverB) } ?? "",
        fmt(row.full.medianLuma),
        fmt(row.full.meanLuma),
        fmt(row.full.meanSaturation),
        fmt(row.full.clipRatio),
        fmt(row.full.blackRatio),
        String(row.blackLevel),
        fmt(row.blackShare),
        fmt(row.grain, 5),
        row.face != nil ? "yes" : "no",
        row.litSide,
        gateResult?.name ?? "",
        verdict,
        failed.joined(separator: " | ")
    ]
    csv += fields.joined(separator: ",") + "\n"
}

do {
    try csv.write(to: options.csvFile, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("could not write \(options.csvFile.path): \(error)\n".utf8))
    exit(1)
}

// MARK: - Markdown summary

if !options.quiet {
    var out = ""
    let cameraCache = Dictionary(grouping: rows, by: { $0.capture.manifest.camera })
    out += "# Originals report\n\n"
    out += "\(captures.count) captures · \(rows.count) frames · \(cameraCache.count) bodies\n\n"
    out += "| capture | frame | role | body | skin R/G | skin R/B | black floor | clip | verdict |\n"
    out += "|---|---|---|---|---:|---:|---:|---:|---|\n"
    for row in rows {
        let gateResult = gate(for: row)
        let failed = gateResult?.failed ?? []
        let verdict = gateResult == nil ? "—" : (failed.isEmpty ? "PASS" : "FAIL: " + failed.joined(separator: "; "))
        out += "| \(row.capture.folder.lastPathComponent) | \(row.frame.fileName) | \(row.frame.role) "
        out += "| \(row.capture.manifest.camera.replacingOccurrences(of: "POCKET ", with: "")) "
        out += "| \(row.face.map { fmt($0.medianRoverG, 2) } ?? "—") "
        out += "| \(row.face.map { fmt($0.medianRoverB, 2) } ?? "—") "
        let floorText = row.blackShare > 0 ? "\(row.blackLevel) (\(fmt(row.blackShare * 100, 1))%)" : "—"
        out += "| \(floorText) "
        out += "| \(fmt(row.full.clipRatio * 100, 1))% | \(verdict) |\n"
    }

    // A burst that changes colour between frames is the specific failure the
    // roll-consistency work exists to prevent.
    let multiFrame = Dictionary(grouping: rows, by: { $0.capture.folder.lastPathComponent })
        .filter { $0.value.count > 1 }
    if !multiFrame.isEmpty {
        out += "\n## Within-capture spread\n\n"
        out += "| capture | metric | min | max | spread |\n|---|---|---:|---:|---:|\n"
        for (name, frames) in multiFrame.sorted(by: { $0.key < $1.key }) {
            let values = frames.compactMap { $0.face?.medianRoverG }
            if values.count > 1 {
                out += "| \(name) | skin R/G | \(fmt(values.min()!, 2)) | \(fmt(values.max()!, 2)) | \(fmt(values.max()! - values.min()!, 3)) |\n"
            }
            let lumas = frames.map(\.full.meanLuma)
            out += "| \(name) | mean luma | \(fmt(lumas.min()!, 2)) | \(fmt(lumas.max()!, 2)) | \(fmt(lumas.max()! - lumas.min()!, 3)) |\n"
        }
    }

    let failures = rows.filter { gate(for: $0)?.failed.isEmpty == false }
    out += "\n\(failures.isEmpty ? "Every gated frame passes." : "\(failures.count) frame(s) fail a gate.")\n"
    print(out)
}
