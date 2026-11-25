import Foundation
import ImageIO

/// Only values reported by the captured file are called actual exposure.
struct OriginalFrameExposure: Codable, Equatable, Sendable {
    let iso: Float?
    let shutterSeconds: Double?
    let exposureBias: Float?
    let whiteBalanceMode: Int?

    static func read(_ data: Data) -> Self? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] else { return nil }
        func finite(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first
        let actualISO = finite(iso).flatMap { $0 > 0 && $0 <= Double(Float.greatestFiniteMagnitude) ? Float($0) : nil }
        let duration = finite(exif[kCGImagePropertyExifExposureTime as String]).flatMap { $0 > 0 ? $0 : nil }
        return Self(iso: actualISO, shutterSeconds: duration,
                    exposureBias: finite(exif[kCGImagePropertyExifExposureBiasValue as String]).map { Float($0) },
                    whiteBalanceMode: (exif[kCGImagePropertyExifWhiteBalance as String] as? NSNumber)?.intValue)
    }
}

/// Everything about one shutter press except the pixels.
struct OriginalCaptureSnapshot: Sendable {
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
}

/// One unprocessed camera frame plus the role it played in the capture.
struct OriginalCaptureFrame: Sendable {
    let role: String
    let data: Data
    var diagnostics: CaptureExposureDiagnostics? = nil
}

struct OriginalArchiveStats: Sendable, Equatable {
    var captures: Int = 0
    var bytes: Int64 = 0
}

/// A capture folder as seen by the pruning pass.
struct OriginalCaptureRef: Equatable, Sendable {
    let name: String
    let bytes: Int64
}

/// Keeps the camera's unprocessed files on disk, one folder per shutter press.
///
/// Why this exists: the app used to keep only the rendered JPEG, which made a
/// rendering regression impossible to attribute — the input was gone by the
/// time you looked at the output. With originals on disk the calibration set
/// can be re-rendered against a new recipe and compared pixel for pixel, and a
/// real night-flash sample can become a regression fixture instead of a
/// one-off measurement.
///
/// Off by default. Originals are roughly four times the size of a rendered
/// frame, so the archive is capped by both capture count and total bytes and
/// always keeps the newest capture.
actor OriginalFrameArchive {
    static let shared = OriginalFrameArchive()

    static let enabledKey = "pocketCCD.keepOriginalFrames"

    /// Kept deliberately below 2 GB: an iPhone that runs out of storage stops
    /// being able to take photos at all.
    static let maxBytes: Int64 = 1_500_000_000
    static let maxCaptures = 300
    static let currentVersion = 1

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    private let fileManager: FileManager
    private let root: URL

    init(fileManager: FileManager = .default, root overrideRoot: URL? = nil) {
        self.fileManager = fileManager
        if let overrideRoot {
            root = overrideRoot
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            root = base.appendingPathComponent("PocketCCD Originals", isDirectory: true)
        }
        // Diagnostics data, not user content: keep up to 1.5 GB of sensor
        // originals out of iCloud backups.
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var mutableRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableRoot.setResourceValues(values)
    }

    // MARK: - Writing

    func archive(_ frames: [OriginalCaptureFrame], snapshot: OriginalCaptureSnapshot) {
        guard !frames.isEmpty else { return }
        guard let directory = makeCaptureDirectory(for: snapshot.capturedAt) else { return }

        var manifestFrames: [OriginalManifest.Frame] = []
        for (index, frame) in frames.enumerated() {
            let fileName = "frame-\(index)-\(frame.role).\(Self.fileExtension(for: frame.data))"
            let url = directory.appendingPathComponent(fileName)
            do {
                try frame.data.write(to: url, options: .atomic)
            } catch {
                continue
            }
            let size = Self.pixelSize(of: frame.data)
            manifestFrames.append(.init(
                role: frame.role,
                fileName: fileName,
                byteCount: frame.data.count,
                pixelWidth: size?.width ?? 0,
                pixelHeight: size?.height ?? 0,
                exposure: OriginalFrameExposure.read(frame.data),
                diagnostics: frame.diagnostics
            ))
        }

        // A folder with no frames is worse than nothing: it would show up in
        // the corpus as a capture that renders to nothing.
        guard !manifestFrames.isEmpty else {
            try? fileManager.removeItem(at: directory)
            return
        }

        let manifest = OriginalManifest(
            version: Self.currentVersion,
            capturedAt: snapshot.capturedAt,
            camera: snapshot.camera,
            cameraPosition: snapshot.cameraPosition,
            mode: snapshot.mode,
            lens: snapshot.lens,
            exposureBias: manifestFrames.first?.exposure?.exposureBias ?? snapshot.exposureBias,
            iso: manifestFrames.first?.exposure?.iso,
            shutterSeconds: manifestFrames.first?.exposure?.shutterSeconds,
            whiteBalanceKelvin: nil,
            requestedISO: snapshot.iso,
            requestedShutterSeconds: snapshot.shutterSeconds,
            requestedWhiteBalanceKelvin: snapshot.whiteBalanceKelvin,
            flashMode: snapshot.flashMode,
            frames: manifestFrames
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
        }

        pruneIfNeeded()
    }

    private func makeCaptureDirectory(for date: Date) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        let suffix = String(UUID().uuidString.prefix(6)).lowercased()
        let directory = root.appendingPathComponent("\(stamp)-\(suffix)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    // MARK: - Maintenance

    func stats() -> OriginalArchiveStats {
        let refs = captureRefs()
        return OriginalArchiveStats(
            captures: refs.count,
            bytes: refs.reduce(0) { $0 + $1.bytes }
        )
    }

    func removeAll() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    private func pruneIfNeeded() {
        let refs = captureRefs()
        let doomed = Self.capturesToDelete(refs, maxBytes: Self.maxBytes, maxCaptures: Self.maxCaptures)
        for name in doomed {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// Oldest first, so the pruning plan reads in the same order as the folders.
    private func captureRefs() -> [OriginalCaptureRef] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            let directory = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return OriginalCaptureRef(name: name, bytes: Self.byteCount(of: directory, fileManager: fileManager))
        }
    }

    private static func byteCount(of directory: URL, fileManager: FileManager) -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Pure so the trimming rule can be tested without touching a disk.
    /// `captures` must be oldest first; the newest capture is never deleted.
    static func capturesToDelete(
        _ captures: [OriginalCaptureRef],
        maxBytes: Int64,
        maxCaptures: Int
    ) -> [String] {
        guard captures.count > 1 else { return [] }
        var total = captures.reduce(Int64(0)) { $0 + $1.bytes }
        var dropForBytes = 0
        while total > maxBytes, dropForBytes < captures.count - 1 {
            total -= captures[dropForBytes].bytes
            dropForBytes += 1
        }
        let dropForCount = max(0, captures.count - maxCaptures)
        return captures.prefix(max(dropForBytes, dropForCount)).map(\.name)
    }

    // MARK: - Payload helpers

    /// The capture pipeline writes JPEG today, but a HEIC setting or a future
    /// format change should not end up in a file a labeller cannot open.
    static func fileExtension(for data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.count > 12, data[4..<8] == Data("ftyp".utf8) { return "heic" }
        return "bin"
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}

private struct OriginalManifest: Codable {
    struct Frame: Codable {
        let role: String
        let fileName: String
        let byteCount: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let exposure: OriginalFrameExposure?
        let diagnostics: CaptureExposureDiagnostics?
    }

    let version: Int
    let capturedAt: Date
    let camera: String
    let cameraPosition: String
    let mode: String
    let lens: String
    let exposureBias: Float
    let iso: Float?
    let shutterSeconds: Double?
    let whiteBalanceKelvin: Float?
    let requestedISO: Float?
    let requestedShutterSeconds: Double?
    let requestedWhiteBalanceKelvin: Float?
    let flashMode: String
    let frames: [Frame]
}
