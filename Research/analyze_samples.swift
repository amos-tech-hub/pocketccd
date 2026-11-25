#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO

struct Metrics {
    var count = 0
    var red = 0.0
    var green = 0.0
    var blue = 0.0
    var saturation = 0.0
    var luma = 0.0
    var clipped = 0
    var black = 0
    var edgeDifference = 0.0
    var edgeCount = 0
    var noiseDifference = 0.0
    var noiseCount = 0
}

struct NormalizedROI {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect {
        CGRect(
            x: x * Double(imageWidth),
            y: y * Double(imageHeight),
            width: width * Double(imageWidth),
            height: height * Double(imageHeight)
        ).intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    }
}

func loadROIs(from url: URL?) -> [String: NormalizedROI] {
    guard let url, let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var result: [String: NormalizedROI] = [:]
    for line in contents.split(whereSeparator: \.isNewline) {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5,
              fields[0].lowercased() != "file",
              let x = Double(fields[1]), let y = Double(fields[2]),
              let width = Double(fields[3]), let height = Double(fields[4]),
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else { continue }
        result[fields[0]] = NormalizedROI(x: x, y: y, width: width, height: height)
    }
    return result
}

func analyze(url: URL, roi: NormalizedROI? = nil) -> Metrics? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

    let maximumDimension = 1024
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maximumDimension
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var result = Metrics()
    var lumaPlane = [Double](repeating: 0, count: width * height)
    let measurementRect = roi?.pixelRect(imageWidth: width, imageHeight: height)
        ?? CGRect(x: 0, y: 0, width: width, height: height)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let index = (y * width + x) * 4
            let r = Double(pixels[index]) / 255
            let g = Double(pixels[index + 1]) / 255
            let b = Double(pixels[index + 2]) / 255
            let maximum = max(r, g, b)
            let minimum = min(r, g, b)
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            lumaPlane[y * width + x] = luminance
            guard measurementRect.contains(CGPoint(x: x, y: y)) else { continue }
            result.count += 1
            result.red += r
            result.green += g
            result.blue += b
            result.saturation += maximum == 0 ? 0 : (maximum - minimum) / maximum
            result.luma += luminance
            if max(pixels[index], pixels[index + 1], pixels[index + 2]) >= 250 { result.clipped += 1 }
            if luminance <= 0.04 { result.black += 1 }
            if x > 0 {
                result.edgeDifference += abs(luminance - lumaPlane[y * width + x - 1])
                result.edgeCount += 1
            }
            if y > 0 {
                result.edgeDifference += abs(luminance - lumaPlane[(y - 1) * width + x])
                result.edgeCount += 1
            }
        }
    }

    // High-frequency residual in non-highlight pixels. This is a noise/grain
    // proxy, not a physical sensor-noise measurement; compare like-for-like
    // captures at the same resolution.
    if width > 2, height > 2 {
        for y in 1 ..< height - 1 {
            for x in 1 ..< width - 1 where measurementRect.contains(CGPoint(x: x, y: y)) {
                let center = lumaPlane[y * width + x]
                guard center < 0.9 else { continue }
                let neighbors = (
                    lumaPlane[y * width + x - 1] + lumaPlane[y * width + x + 1]
                    + lumaPlane[(y - 1) * width + x] + lumaPlane[(y + 1) * width + x]
                ) / 4
                result.noiseDifference += abs(center - neighbors)
                result.noiseCount += 1
            }
        }
    }
    return result
}

let folder = CommandLine.arguments.dropFirst().first ?? "Research/Samples/pocketccd"
let roiFile = CommandLine.arguments.dropFirst(2).first
let root = URL(fileURLWithPath: folder)
let rois = loadROIs(from: roiFile.map { URL(fileURLWithPath: $0) })
let extensions = Set(["jpg", "jpeg", "png", "heic"])
let files = (try? FileManager.default.contentsOfDirectory(
    at: root,
    includingPropertiesForKeys: nil
))?.filter { extensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

guard !files.isEmpty else {
    print("No supported images found in \(root.path)")
    exit(1)
}

print("file,region,mean_luma,mean_saturation,red_minus_blue,blue_red_ratio,clip_ratio,black_ratio,sharpness_proxy,grain_proxy")
for file in files {
    let regions: [(String, NormalizedROI?)] = [("full", nil)]
        + (rois[file.lastPathComponent].map { [("roi", Optional($0))] } ?? [])
    for (regionName, roi) in regions {
        guard let metrics = analyze(url: file, roi: roi), metrics.count > 0 else { continue }
        let count = Double(metrics.count)
        let edgeCount = Double(max(metrics.edgeCount, 1))
        let meanRed = metrics.red / count
        let meanBlue = metrics.blue / count
        let values = [
            Double(metrics.luma / count),
            Double(metrics.saturation / count),
            Double(meanRed - meanBlue),
            meanRed > 0 ? meanBlue / meanRed : 0,
            Double(metrics.clipped) / count,
            Double(metrics.black) / count,
            metrics.edgeDifference / edgeCount,
            metrics.noiseDifference / Double(max(metrics.noiseCount, 1))
        ].map { String(format: "%.5f", $0) }
        print(([file.lastPathComponent, regionName] + values).joined(separator: ","))
    }
}

