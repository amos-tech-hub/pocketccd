import Observation
import UIKit
import AVFoundation
import ImageIO

struct RollEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let createdAt: Date
    let cameraRawValue: String
    let mode: CaptureMode
    let qualityScore: Double?
    let note: String?
    let metadata: PhotoFrameMetadata?

    init(
        id: UUID,
        fileName: String,
        createdAt: Date,
        cameraRawValue: String,
        mode: CaptureMode,
        qualityScore: Double?,
        note: String? = nil,
        metadata: PhotoFrameMetadata? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.cameraRawValue = cameraRawValue
        self.mode = mode
        self.qualityScore = qualityScore
        self.note = note
        self.metadata = metadata
    }
}

struct RollArchive: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let entries: [RollEntry]
    let title: String?
    let note: String?

    init(id: UUID, createdAt: Date, entries: [RollEntry], title: String? = nil, note: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.entries = entries
        self.title = title
        self.note = note
    }
}

/// What the last index load (or write) found. The camera screen reports this
/// once and clears it, so a repaired roll never repairs itself in silence.
struct RollIndexHealth: Equatable {
    /// Frames found on disk that the manifest did not list.
    var adopted = 0
    /// Manifest entries whose image file is gone.
    var missing = 0
    /// The most recent manifest write failed; the index is behind the disk.
    var writeFailed = false

    var isEmpty: Bool { adopted == 0 && missing == 0 && !writeFailed }

    var message: LocalizedStringResource? {
        if writeFailed {
            return "Roll index could not be saved — frames stay on disk."
        }
        if adopted > 0, missing > 0 {
            return "Recovered \(adopted) frames · \(missing) missing"
        }
        if adopted > 0 {
            return "Recovered \(adopted) frames from disk"
        }
        if missing > 0 {
            return "\(missing) frames are missing from this roll"
        }
        return nil
    }
}

private struct RollManifestFile: Codable {
    let version: Int
    let entries: [RollEntry]
}

private struct RollArchiveFile: Codable {
    let version: Int
    let archives: [RollArchive]
}

private struct PocketRollBackup: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let currentTitle: String
    let currentNote: String
    let currentEntries: [RollEntry]
    let archives: [RollArchive]
    let imageDataByFileName: [String: Data]
}

private struct PocketRollBackupHeader: Codable {
    let formatVersion: Int
    let exportedAt: Date
    let currentTitle: String
    let currentNote: String
    let currentEntries: [RollEntry]
    let archives: [RollArchive]
}

private struct PocketRollBackupImage: Codable {
    let fileName: String
    let data: Data
}

private struct PreparedBackupImport {
    let currentEntries: [RollEntry]
    let archives: [RollArchive]
    let title: String
    let note: String
    let usableCount: Int
}

enum PocketRollBackupError: LocalizedError {
    case unreadable, unsupportedVersion, invalidContents, noUsablePhotos

    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "This Pocket CCD backup could not be read.")
        case .unsupportedVersion: String(localized: "This backup was created by an unsupported Pocket CCD version.")
        case .invalidContents: String(localized: "This backup contains invalid or unsafe photo data.")
        case .noUsablePhotos: String(localized: "The backup did not contain any new usable photos.")
        }
    }
}

struct RollWriteReceipt {
    enum Failure: Equatable { case full, storage, write, index }
    let requestedCount: Int
    let entryIDs: [UUID: UUID]
    let failure: Failure?
    var storedCount: Int { entryIDs.count }
    var isComplete: Bool { storedCount == requestedCount && failure == nil }
}

@MainActor
@Observable
final class RollStore {
    /// One store per process: CameraScreen used to construct a fresh RollStore
    /// (directory creation + manifest decode) on every view init.
    static let shared = RollStore()

    private(set) var entries: [RollEntry] = []
    private(set) var archives: [RollArchive] = []
    private(set) var currentTitle = ""
    private(set) var currentNote = ""
    /// Set when the last load repaired or noticed something; the camera screen
    /// consumes it once (see `clearIndexHealth()`).
    private(set) var indexHealth = RollIndexHealth()
    private let directory: URL
    private let manifestURL: URL
    private let archivesURL: URL
    private var colorAnchors: [String: CaptureColorAnchor] = [:]
    private let defaults: UserDefaults
    init(fileManager: FileManager = .default, root overrideRoot: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = overrideRoot ?? base.appendingPathComponent("PocketRoll", isDirectory: true)
        manifestURL = directory.appendingPathComponent("manifest.json")
        archivesURL = directory.appendingPathComponent("archives.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        currentTitle = defaults.string(forKey: "pocketCCD.roll.title") ?? ""
        currentNote = defaults.string(forKey: "pocketCCD.roll.note") ?? ""
        if let data = defaults.data(forKey: "pocketCCD.roll.colorAnchors"),
           let decoded = try? JSONDecoder().decode([String: CaptureColorAnchor].self, from: data) {
            colorAnchors = decoded
        }
        load()
    }

    /// Configured roll size (12 or 24). Changes apply to the next capture.
    nonisolated static var capacity: Int { capacity(in: .standard) }

    nonisolated static func capacity(in defaults: UserDefaults) -> Int {
        let stored = defaults.integer(forKey: "pocketCCD.rollCapacity")
        return stored == 12 ? 12 : 24
    }

    var capacity: Int { Self.capacity(in: defaults) }

    var isFull: Bool { entries.count >= capacity }

    /// True when the last `add()` refused a frame because the volume was
    /// critically full. The camera screen turns this into a different message
    /// than "the roll is full".
    private(set) var blockedByStorage = false

    @discardableResult
    func add(
        _ image: UIImage,
        camera: CCDLook,
        mode: CaptureMode,
        createdAt: Date,
        qualityScore: Double,
        metadata: PhotoFrameMetadata? = nil
    ) async -> UUID? {
        guard !isFull else { return nil }
        // Writing a 3–6 MB JPEG into a nearly full volume fails after the
        // capture is already gone. Refuse before encoding and say why.
        guard StorageGuard.level(at: directory) != .critical else {
            blockedByStorage = true
            return nil
        }
        blockedByStorage = false
        let id = UUID()
        let fileName = "\(id.uuidString).jpg"
        let destination = directory.appendingPathComponent(fileName)
        let written = await Task.detached(priority: .utility) { [image] in
            guard let data = image.jpegData(compressionQuality: 0.94) else { return false }
            do {
                try data.write(to: destination, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
        guard written else { return nil }

        // The actor can be re-entered while encoding. If another capture filled
        // the roll meanwhile, remove this unindexed file instead of overflowing.
        guard !isFull else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        entries.append(RollEntry(
            id: id,
            fileName: fileName,
            createdAt: createdAt,
            cameraRawValue: camera.rawValue,
            mode: mode,
            qualityScore: qualityScore,
            metadata: metadata
        ))
        persist()
        return id
    }

    /// Returns only after image encoding and index persistence have finished.
    /// An image retained for recovery is not an indexed, successful roll save.
    func addFrames(_ frames: [CapturedFrame], camera: CCDLook, mode: CaptureMode,
                   createdAt: Date) async -> RollWriteReceipt {
        var ids: [UUID: UUID] = [:]
        var failure: RollWriteReceipt.Failure?
        for frame in frames {
            if let id = await add(frame.image, camera: camera, mode: mode, createdAt: createdAt,
                                  qualityScore: frame.qualityScore, metadata: frame.metadata) {
                ids[frame.id] = id
            } else if failure == nil {
                failure = blockedByStorage ? .storage : (isFull ? .full : .write)
            }
        }
        if failure == nil && indexHealth.writeFailed { failure = .index }
        return RollWriteReceipt(requestedCount: frames.count, entryIDs: ids, failure: failure)
    }

    /// Downsampled image for grids and strips. Decoding 24 full-resolution
    /// captures at once was pushing the process past a gigabyte on device.
    func thumbnail(for entry: RollEntry, maxPixel: CGFloat = 720) -> UIImage? {
        RollThumbnailCache.thumbnail(url: directory.appendingPathComponent(entry.fileName), maxPixel: maxPixel)
    }

    func thumbnailURL(for entry: RollEntry) -> URL {
        directory.appendingPathComponent(entry.fileName)
    }

    /// Read-only view of the roll anchor. `colorAnchor(for:sample:)` blends and
    /// persists on every call, so the live preview must not use it: at 24 fps it
    /// would drag the anchor along and create the very drift it prevents.
    func peekColorAnchor(for camera: CCDLook) -> CaptureColorAnchor? {
        colorAnchors[camera.rawValue]
    }

    func colorAnchor(for camera: CCDLook, sample: CaptureColorAnchor) -> CaptureColorAnchor {
        let key = camera.rawValue
        let anchor = colorAnchors[key] ?? sample
        // A slow moving reference prevents one unusual scene from tinting the whole roll.
        colorAnchors[key] = anchor.blended(with: sample, sampleWeight: 0.08)
        persistColorAnchors()
        return anchor
    }

    func startNewRoll() {
        let previousEntries = entries
        let previousArchives = archives
        let previousAnchors = colorAnchors
        let previousTitle = currentTitle
        let previousNote = currentNote
        if !entries.isEmpty {
            archives.insert(RollArchive(
                id: UUID(),
                createdAt: entries.map(\.createdAt).min() ?? .now,
                entries: entries,
                title: currentTitle.nilIfBlank,
                note: currentNote.nilIfBlank
            ), at: 0)
        }
        entries = []
        colorAnchors = [:]
        persistColorAnchors()
        updateCurrentMetadata(title: "", note: "")
        guard persist() else {
            // Put the roll back together if either file could not be written;
            // otherwise the photo files survive on disk with no index at all.
            // Metadata and colour anchors were already cleared and persisted,
            // so they need the same rollback.
            entries = previousEntries
            archives = previousArchives
            colorAnchors = previousAnchors
            currentTitle = previousTitle
            currentNote = previousNote
            persistColorAnchors()
            updateCurrentMetadata(title: previousTitle, note: previousNote)
            persist()
            return
        }
    }

    func updateCurrentMetadata(title: String, note: String) {
        currentTitle = String(title.prefix(60))
        currentNote = String(note.prefix(180))
        defaults.set(currentTitle, forKey: "pocketCCD.roll.title")
        defaults.set(currentNote, forKey: "pocketCCD.roll.note")
    }

    /// Preferred path: the caller knows exactly which roll entry it saved.
    func updateNote(_ note: String, forEntryID entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        applyNote(note, at: index)
    }

    /// Fallback for notes written before the roll write reported its entry id.
    /// Every frame of one burst shares `createdAt`, so the nearest-time match
    /// alone always picked the ambient frame; the index disambiguates.
    func updateNote(_ note: String, forCaptureAt createdAt: Date, frameIndex: Int = 0) {
        let matches = entries.indices.filter {
            abs(entries[$0].createdAt.timeIntervalSince(createdAt)) < 2
        }
        guard !matches.isEmpty else { return }
        applyNote(note, at: matches[min(max(frameIndex, 0), matches.count - 1)])
    }

    private func applyNote(_ note: String, at index: Int) {
        let entry = entries[index]
        entries[index] = RollEntry(
            id: entry.id,
            fileName: entry.fileName,
            createdAt: entry.createdAt,
            cameraRawValue: entry.cameraRawValue,
            mode: entry.mode,
            qualityScore: entry.qualityScore,
            note: String(note.prefix(120)).nilIfBlank,
            metadata: entry.metadata
        )
        persist()
    }

    func deleteEntry(_ entry: RollEntry, in archiveID: UUID? = nil) {
        if let archiveID {
            guard let archiveIndex = archives.firstIndex(where: { $0.id == archiveID }) else { return }
            let archive = archives[archiveIndex]
            guard let entryIndex = archive.entries.firstIndex(where: { $0.id == entry.id }) else { return }
            let previousArchives = archives
            var remaining = archive.entries
            let removed = remaining.remove(at: entryIndex)
            if remaining.isEmpty {
                archives.remove(at: archiveIndex)
            } else {
                archives[archiveIndex] = RollArchive(
                    id: archive.id,
                    createdAt: archive.createdAt,
                    entries: remaining,
                    title: archive.title,
                    note: archive.note
                )
            }
            // Write the index before deleting pixels: a failed write used to
            // leave an entry pointing at a file that no longer exists.
            guard persist() else {
                archives = previousArchives
                return
            }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(removed.fileName))
            return
        }
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let removed = entries.remove(at: index)
        guard persist() else {
            entries.insert(removed, at: index)
            return
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(removed.fileName))
    }

    func deleteArchive(_ archive: RollArchive) {
        guard let index = archives.firstIndex(where: { $0.id == archive.id }) else { return }
        for entry in archives[index].entries {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.fileName))
        }
        archives.remove(at: index)
        persist()
    }

    func contactSheet(for archive: RollArchive, format: ExportPreset) -> UIImage? {
        ContactSheetRenderer.render(
            images: archive.entries.compactMap { thumbnail(for: $0, maxPixel: 1200) },
            entries: archive.entries,
            format: format
        )
    }

    func contactSheet(format: ExportPreset = .square) -> UIImage? {
        let images = entries.compactMap { thumbnail(for: $0, maxPixel: 1200) }
        return ContactSheetRenderer.render(images: images, entries: entries, format: format)
    }

    func daySummaryVideo() async throws -> URL {
        let ordered = entries.sorted { $0.createdAt < $1.createdAt }
        let urls = ordered.map { (thumbnailURL(for: $0), $0) }
        let items: [DaySummaryRenderer.Item] = await Task.detached(priority: .userInitiated) {
            urls.compactMap { url, entry in
                guard let image = RollThumbnailCache.thumbnail(url: url, maxPixel: 1200) else { return nil }
                return DaySummaryRenderer.Item(image: image, entry: entry)
            }
        }.value
        guard !items.isEmpty else { throw PocketRollBackupError.noUsablePhotos }
        return try await DaySummaryRenderer.render(
            items: items,
            title: currentTitle.nilIfBlank ?? "POCKET DAY",
            note: currentNote.nilIfBlank
        )
    }

    enum BackupFormat {
        /// Legacy single JSON document. Kept for testing the v1 importer and
        /// for anyone who needs the old on-disk shape.
        case v1
        /// JSON Lines: one header line, then one image record per line. The
        /// file is written and read incrementally, so a large roll no longer
        /// materializes hundreds of megabytes of base64 at once.
        case v2
    }

    func exportBackup(format: BackupFormat = .v2) async -> URL? {
        let currentEntries = entries
        let archivedRolls = archives
        let title = currentTitle
        let note = currentNote
        let rollDirectory = directory
        return await Task.detached(priority: .utility) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            // A second-resolution timestamp collided when two exports ran in
            // the same second (and let one export delete the other's file).
            let suffix = String(UUID().uuidString.prefix(6)).lowercased()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("PocketCCD-Backup-\(formatter.string(from: .now))-\(suffix)")
                .appendingPathExtension("pocketccdbackup")

            switch format {
            case .v2:
                guard Self.writeStreamingBackup(
                    entries: currentEntries,
                    archives: archivedRolls,
                    title: title,
                    note: note,
                    directory: rollDirectory,
                    to: url
                ) else { return nil }
                return url
            case .v1:
                guard let data = Self.backupData(
                    entries: currentEntries,
                    archives: archivedRolls,
                    title: title,
                    note: note,
                    directory: rollDirectory
                ) else { return nil }
                do {
                    try data.write(to: url, options: .atomic)
                    return url
                } catch {
                    return nil
                }
            }
        }.value
    }

    private nonisolated static func writeStreamingBackup(
        entries: [RollEntry],
        archives: [RollArchive],
        title: String,
        note: String,
        directory: URL,
        to url: URL
    ) -> Bool {
        let header = PocketRollBackupHeader(
            formatVersion: 2,
            exportedAt: .now,
            currentTitle: title,
            currentNote: note,
            currentEntries: entries,
            archives: archives
        )
        guard let headerData = try? JSONEncoder().encode(header),
              FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: headerData)
            try handle.write(contentsOf: Data([0x0A]))
            var writtenNames = Set<String>()
            for entry in entries + archives.flatMap(\.entries) {
                guard writtenNames.insert(entry.fileName).inserted else { continue }
                let fileURL = directory.appendingPathComponent(entry.fileName)
                guard let imageData = try? Data(contentsOf: fileURL) else { continue }
                let record = PocketRollBackupImage(fileName: entry.fileName, data: imageData)
                let line = try JSONEncoder().encode(record)
                try handle.write(contentsOf: line)
                try handle.write(contentsOf: Data([0x0A]))
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    private nonisolated static func backupData(
        entries: [RollEntry],
        archives: [RollArchive],
        title: String,
        note: String,
        directory: URL
    ) -> Data? {
        let allEntries = entries + archives.flatMap(\.entries)
        let imagePairs: [(String, Data)] = allEntries.compactMap { entry in
            let url = directory.appendingPathComponent(entry.fileName)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (entry.fileName, data)
        }
        let imageData = Dictionary(imagePairs, uniquingKeysWith: { first, _ in first })
        let backup = PocketRollBackup(
            formatVersion: 1,
            exportedAt: .now,
            currentTitle: title,
            currentNote: note,
            currentEntries: entries,
            archives: archives,
            imageDataByFileName: imageData
        )
        return try? JSONEncoder().encode(backup)
    }

    @discardableResult
    func importBackup(data: Data) async throws -> Int {
        let knownEntryIDs = Set((entries + archives.flatMap(\.entries)).map(\.id))
        let knownArchiveIDs = Set(archives.map(\.id))
        let availableSlots = max(Self.capacity - entries.count, 0)
        let rollDirectory = directory
        let prepared = try await Task.detached(priority: .utility) {
            try Self.prepareBackupImport(
                data: data,
                knownEntryIDs: knownEntryIDs,
                knownArchiveIDs: knownArchiveIDs,
                availableSlots: availableSlots,
                directory: rollDirectory
            )
        }.value
        return try applyPreparedImport(prepared)
    }

    /// Streaming import. v2 backups are read one line at a time, so only one
    /// photo is resident in memory; v1 files fall back to the legacy decoder.
    @discardableResult
    func importBackup(from url: URL) async throws -> Int {
        let knownEntryIDs = Set((entries + archives.flatMap(\.entries)).map(\.id))
        let knownArchiveIDs = Set(archives.map(\.id))
        let availableSlots = max(Self.capacity - entries.count, 0)
        let rollDirectory = directory
        let prepared = try await Task.detached(priority: .utility) {
            try Self.prepareStreamingImport(
                url: url,
                knownEntryIDs: knownEntryIDs,
                knownArchiveIDs: knownArchiveIDs,
                availableSlots: availableSlots,
                directory: rollDirectory
            )
        }.value
        return try applyPreparedImport(prepared)
    }

    private func applyPreparedImport(_ prepared: PreparedBackupImport) throws -> Int {
        let previousEntries = entries
        let previousArchives = archives
        entries.append(contentsOf: prepared.currentEntries)
        archives.insert(contentsOf: prepared.archives, at: 0)
        guard persist() else {
            entries = previousEntries
            archives = previousArchives
            throw PocketRollBackupError.unreadable
        }
        if currentTitle.isEmpty, !prepared.title.isEmpty {
            updateCurrentMetadata(title: prepared.title, note: prepared.note)
        }
        return prepared.usableCount
    }

    private nonisolated static func prepareBackupImport(
        data: Data,
        knownEntryIDs: Set<UUID>,
        knownArchiveIDs: Set<UUID>,
        availableSlots: Int,
        directory: URL
    ) throws -> PreparedBackupImport {
        // The legacy single-document format materializes the payload in
        // memory. New exports use the streaming format below.
        guard data.count <= 500_000_000 else { throw PocketRollBackupError.invalidContents }
        guard let backup = try? JSONDecoder().decode(PocketRollBackup.self, from: data) else {
            throw PocketRollBackupError.unreadable
        }
        guard backup.formatVersion == 1 else { throw PocketRollBackupError.unsupportedVersion }

        let suppliedEntries = backup.currentEntries + backup.archives.flatMap(\.entries)
        try validateBackupEntries(suppliedEntries)
        guard backup.imageDataByFileName.values.allSatisfy({ $0.count <= 50_000_000 }) else {
            throw PocketRollBackupError.invalidContents
        }

        var writtenURLs: [URL] = []
        do {
            for entry in suppliedEntries where !knownEntryIDs.contains(entry.id) {
                let destination = directory.appendingPathComponent(entry.fileName)
                guard !FileManager.default.fileExists(atPath: destination.path),
                      let imageData = backup.imageDataByFileName[entry.fileName] else { continue }
                try imageData.write(to: destination, options: .atomic)
                writtenURLs.append(destination)
            }
            return try mergeBackup(
                currentEntries: backup.currentEntries,
                archives: backup.archives,
                title: backup.currentTitle,
                note: backup.currentNote,
                exportedAt: backup.exportedAt,
                knownEntryIDs: knownEntryIDs,
                knownArchiveIDs: knownArchiveIDs,
                availableSlots: availableSlots,
                imageExists: { fileName in
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(fileName).path
                    )
                }
            )
        } catch {
            for url in writtenURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Reads a v2 backup one line at a time. Only the current photo's base64
    /// payload is resident, so a 500 MB roll does not need 1.5 GB of RAM.
    private nonisolated static func prepareStreamingImport(
        url: URL,
        knownEntryIDs: Set<UUID>,
        knownArchiveIDs: Set<UUID>,
        availableSlots: Int,
        directory: URL
    ) throws -> PreparedBackupImport {
        let reader = try BackupLineReader(url: url, maxLineBytes: 80_000_000)
        guard let headerLine = try reader.nextLine() else { throw PocketRollBackupError.unreadable }
        guard let header = try? JSONDecoder().decode(PocketRollBackupHeader.self, from: headerLine),
              header.formatVersion == 2 else {
            // A v1 document is a single JSON object; fall back to the legacy
            // path so old backups keep restoring.
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try prepareBackupImport(
                data: data,
                knownEntryIDs: knownEntryIDs,
                knownArchiveIDs: knownArchiveIDs,
                availableSlots: availableSlots,
                directory: directory
            )
        }

        let suppliedEntries = header.currentEntries + header.archives.flatMap(\.entries)
        try validateBackupEntries(suppliedEntries)
        let referenced = Set(suppliedEntries.map(\.fileName))
        var writtenURLs: [URL] = []

        do {
            var seen = Set<String>()
            var totalBytes = 0
            while let line = try reader.nextLine() {
                guard !line.isEmpty else { continue }
                guard let record = try? JSONDecoder().decode(PocketRollBackupImage.self, from: line),
                      referenced.contains(record.fileName),
                      seen.insert(record.fileName).inserted,
                      record.data.count <= 50_000_000 else {
                    throw PocketRollBackupError.invalidContents
                }
                totalBytes += record.data.count
                guard totalBytes <= 1_500_000_000 else { throw PocketRollBackupError.invalidContents }
                let destination = directory.appendingPathComponent(record.fileName)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try record.data.write(to: destination, options: .atomic)
                    writtenURLs.append(destination)
                }
            }
            return try mergeBackup(
                currentEntries: header.currentEntries,
                archives: header.archives,
                title: header.currentTitle,
                note: header.currentNote,
                exportedAt: header.exportedAt,
                knownEntryIDs: knownEntryIDs,
                knownArchiveIDs: knownArchiveIDs,
                availableSlots: availableSlots,
                imageExists: { fileName in
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(fileName).path
                    )
                }
            )
        } catch {
            for url in writtenURLs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private nonisolated static func validateBackupEntries(_ supplied: [RollEntry]) throws {
        guard supplied.count <= 500,
              Set(supplied.map(\.id)).count == supplied.count,
              // iOS runs on a case-insensitive volume: `A.jpg` and `a.jpg`
              // would overwrite each other during restore.
              Set(supplied.map { $0.fileName.lowercased() }).count == supplied.count,
              supplied.allSatisfy(Self.hasSafeFileName) else {
            throw PocketRollBackupError.invalidContents
        }
    }

    /// Shared merge/overflow/archive logic for both on-disk formats.
    private nonisolated static func mergeBackup(
        currentEntries: [RollEntry],
        archives: [RollArchive],
        title: String,
        note: String,
        exportedAt: Date,
        knownEntryIDs: Set<UUID>,
        knownArchiveIDs: Set<UUID>,
        availableSlots: Int,
        imageExists: (String) -> Bool
    ) throws -> PreparedBackupImport {
        let newCurrent = currentEntries.filter { !knownEntryIDs.contains($0.id) }
        let restoredCurrent = Array(newCurrent.prefix(availableSlots))
        let overflow = Array(newCurrent.dropFirst(availableSlots))
        var restoredArchives = archives.filter { !knownArchiveIDs.contains($0.id) }
        if !overflow.isEmpty {
            restoredArchives.insert(RollArchive(
                id: UUID(),
                createdAt: overflow.map(\.createdAt).min() ?? exportedAt,
                entries: overflow,
                title: title.nilIfBlank,
                note: note.nilIfBlank
            ), at: 0)
        }
        // Overflow is already represented by the archive inserted above; do
        // not count or write those entries a second time.
        let acceptedEntries = restoredCurrent + restoredArchives.flatMap(\.entries)
        let usableEntries = acceptedEntries.filter { imageExists($0.fileName) }
        guard !usableEntries.isEmpty else { throw PocketRollBackupError.noUsablePhotos }
        let usableIDs = Set(usableEntries.map(\.id))
        let current = restoredCurrent.filter { usableIDs.contains($0.id) }
        let usableArchives: [RollArchive] = restoredArchives.compactMap { archive -> RollArchive? in
            let usable = archive.entries.filter { usableIDs.contains($0.id) }
            guard !usable.isEmpty else { return nil }
            return RollArchive(
                id: archive.id,
                createdAt: archive.createdAt,
                entries: usable,
                title: archive.title,
                note: archive.note
            )
        }
        return PreparedBackupImport(
            currentEntries: current,
            archives: usableArchives,
            title: title,
            note: note,
            usableCount: usableEntries.count
        )
    }

    private final class BackupLineReader {
        private let handle: FileHandle
        private let maxLineBytes: Int
        private var buffer = Data()
        private var reachedEOF = false

        init(url: URL, maxLineBytes: Int) throws {
            handle = try FileHandle(forReadingFrom: url)
            self.maxLineBytes = maxLineBytes
        }

        deinit { try? handle.close() }

        func nextLine() throws -> Data? {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    return line
                }
                if reachedEOF {
                    guard !buffer.isEmpty else { return nil }
                    let line = buffer
                    buffer.removeAll(keepingCapacity: false)
                    return line
                }
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty {
                    reachedEOF = true
                    continue
                }
                buffer.append(chunk)
                if buffer.count > maxLineBytes { throw PocketRollBackupError.invalidContents }
            }
        }
    }

    /// Backup filenames are untrusted input. The old rule required exactly
    /// `"<id>.jpg"`, which silently rejected every backup containing frames
    /// re-adopted after an index write failure (those keep their on-disk name
    /// while getting a fresh UUID). Validate the path instead: one plain
    /// component, a JPEG extension, no traversal sequences. Duplicate names are
    /// rejected by the caller so a restore cannot overwrite an existing frame.
    private nonisolated static func hasSafeFileName(_ entry: RollEntry) -> Bool {
        let name = entry.fileName
        guard !name.isEmpty, name.count <= 128,
              (name as NSString).lastPathComponent == name,
              !name.contains(".."),
              !name.hasPrefix("/"),
              !name.hasPrefix("~") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg"
    }

    var accidentKeeper: RollEntry? {
        guard entries.count >= 12 else { return nil }
        let scored = entries.compactMap { entry -> (RollEntry, Double)? in
            guard let score = entry.qualityScore else { return nil }
            return (entry, score)
        }
        guard !scored.isEmpty else { return nil }
        let sorted = scored.sorted { $0.1 < $1.1 }
        return sorted[min(1, sorted.count - 1)].0
    }

    /// Reads the index, repairs it against the disk, and records what it found.
    ///
    /// The manifest and the image files are written separately, so a kill
    /// between the two (or a full disk, which fails the manifest write) leaves
    /// real frames that nothing lists. Those used to disappear at relaunch;
    /// they are now adopted back into the current roll instead.
    private func load() {
        var decodedEntries: [RollEntry] = []
        if let data = try? Data(contentsOf: manifestURL) {
            // v1 wraps the array with a format version; older builds wrote the
            // bare array, so keep decoding that shape as a migration path.
            let decoded = (try? JSONDecoder().decode(RollManifestFile.self, from: data))?.entries
                ?? (try? JSONDecoder().decode([RollEntry].self, from: data))
            if let decoded {
                decodedEntries = decoded
            } else {
                // Keep the unreadable index instead of overwriting it with the
                // adopted-only manifest below: it is the only record of which
                // camera/mode each surviving JPEG belonged to.
                Self.preserveCorruptIndex(manifestURL)
            }
        }
        var decodedArchives: [RollArchive] = []
        if let archiveData = try? Data(contentsOf: archivesURL) {
            let decoded = (try? JSONDecoder().decode(RollArchiveFile.self, from: archiveData))?.archives
                ?? (try? JSONDecoder().decode([RollArchive].self, from: archiveData))
            if let decoded {
                decodedArchives = decoded
            } else {
                Self.preserveCorruptIndex(archivesURL)
            }
        }

        func exists(_ fileName: String) -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }

        // Count each missing file once: an archived frame and a current frame
        // share the same directory, so the same file can be referenced twice.
        let referenced = Set(decodedEntries.map(\.fileName))
            .union(decodedArchives.flatMap { $0.entries.map(\.fileName) })
        let missing = referenced.filter { !exists($0) }.count

        entries = decodedEntries.filter { exists($0.fileName) }
        archives = decodedArchives.map { archive in
            RollArchive(
                id: archive.id,
                createdAt: archive.createdAt,
                entries: archive.entries.filter { exists($0.fileName) },
                title: archive.title,
                note: archive.note
            )
        }.filter { !$0.entries.isEmpty }

        let adopted = adoptUnindexedFrames()
        indexHealth = RollIndexHealth(
            adopted: adopted,
            missing: missing,
            writeFailed: indexHealth.writeFailed
        )
        if adopted > 0 {
            persist()
        }
    }

    private nonisolated static func preserveCorruptIndex(_ url: URL) {
        let backup = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    /// Re-attaches image files that no manifest or archive lists. Only the file
    /// survives such a failure, so the camera and mode are unknown: the entry is
    /// marked `POCKET ?` rather than claiming a body it never recorded.
    private func adoptUnindexedFrames() -> Int {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let referenced = Set(entries.map(\.fileName))
            .union(archives.flatMap { $0.entries.map(\.fileName) })
        let orphans = contents.filter { url in
            let ext = url.pathExtension.lowercased()
            return (ext == "jpg" || ext == "jpeg") && !referenced.contains(url.lastPathComponent)
        }
        guard !orphans.isEmpty else { return 0 }

        let recovered = orphans.compactMap { url -> RollEntry? in
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            return RollEntry(
                id: UUID(),
                fileName: url.lastPathComponent,
                createdAt: values?.creationDate ?? values?.contentModificationDate ?? .now,
                cameraRawValue: "POCKET ?",
                mode: .standard,
                qualityScore: nil
            )
        }.sorted { $0.createdAt < $1.createdAt }

        // Appending may push the roll past its configured size. That is the
        // honest outcome: the frames exist, and the roll is developed next.
        entries.append(contentsOf: recovered)
        return recovered.count
    }

    /// Lets the camera screen report the last health notice exactly once.
    func clearIndexHealth() {
        indexHealth = RollIndexHealth()
    }

    @discardableResult
    private func persist() -> Bool {
        // Archives first: startNewRoll clears `entries` in memory before this
        // call, so writing the manifest first could orphan a full roll if the
        // process died between the two writes.
        guard let archiveData = try? JSONEncoder().encode(RollArchiveFile(version: 1, archives: archives)),
              (try? archiveData.write(to: archivesURL, options: .atomic)) != nil,
              let data = try? JSONEncoder().encode(RollManifestFile(version: 1, entries: entries)),
              (try? data.write(to: manifestURL, options: .atomic)) != nil else {
            // The frame files are already written; a failed index write means
            // they can only be found by the adoption pass on the next launch.
            indexHealth.writeFailed = true
            return false
        }
        indexHealth.writeFailed = false
        return true
    }

    private func persistColorAnchors() {
        if let data = try? JSONEncoder().encode(colorAnchors) {
            defaults.set(data, forKey: "pocketCCD.roll.colorAnchors")
        }
    }

}

enum DaySummaryRenderer {
    struct Item { let image: UIImage; let entry: RollEntry }

    private static let fps: Int32 = 24
    private static let introFrames = 30
    private static let outroFrames = 36
    private static let transitionFrames = 6

    static func render(items: [Item], title: String, note: String?) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketCCD-Day-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        let size = CGSize(width: 1080, height: 1920)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        guard writer.canAdd(input) else { throw CameraIssue.captureFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CameraIssue.captureFailed }
        writer.startSession(atSourceTime: .zero)
        defer {
            if writer.status == .writing {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        // Pacing follows the reel convention: calmer holds for a short roll,
        // shorter holds once the roll is long enough that 1.8 s would push the
        // video past half a minute.
        let perPhoto: Int = items.count > 16 ? 29 : (items.count > 10 ? 36 : 43)

        var frameNumber: Int64 = 0
        let pool = adaptor.pixelBufferPool

        func append(_ buffer: CVPixelBuffer?) async throws {
            guard let buffer else { throw CameraIssue.captureFailed }
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? CameraIssue.captureFailed }
                try await Task.sleep(for: .milliseconds(8))
            }
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: frameNumber, timescale: fps)) {
                throw writer.error ?? CameraIssue.captureFailed
            }
            frameNumber += 1
        }

        for index in 0..<introFrames {
            let progress = CGFloat(index) / CGFloat(max(introFrames - 1, 1))
            try await append(makeCard(kind: .intro, items: items, title: title, note: note,
                                      size: size, progress: progress, pool: pool))
        }

        for (itemIndex, item) in items.enumerated() {
            for local in 0..<perPhoto {
                let progress = CGFloat(local) / CGFloat(perPhoto)
                let blend: CGFloat = (local >= perPhoto - transitionFrames && itemIndex < items.count - 1)
                    ? CGFloat(local - (perPhoto - transitionFrames)) / CGFloat(transitionFrames)
                    : 0
                let nextItem = (blend > 0 && itemIndex < items.count - 1) ? items[itemIndex + 1] : nil
                try await append(makePhoto(item: item, nextItem: nextItem,
                                           index: itemIndex, count: items.count, title: title,
                                           note: note, size: size, progress: progress,
                                           blend: blend, pool: pool))
            }
        }

        for index in 0..<outroFrames {
            let progress = CGFloat(index) / CGFloat(max(outroFrames - 1, 1))
            try await append(makeCard(kind: .outro, items: items, title: title, note: nil,
                                      size: size, progress: progress, pool: pool))
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CameraIssue.captureFailed }
        return outputURL
    }

    private enum CardKind { case intro, outro }

    private static func makeCard(kind: CardKind, items: [Item], title: String, note: String?,
                                 size: CGSize, progress: CGFloat,
                                 pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        drawIntoBuffer(size: size, pool: pool) { context in
            context.setFillColor(UIColor(red: 0.055, green: 0.058, blue: 0.052, alpha: 1).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            let alpha = kind == .intro ? progress : 1 - progress
            let amber = UIColor(red: 0.94, green: 0.68, blue: 0.24, alpha: alpha)
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: kind == .intro ? 62 : 50, weight: .bold),
                .foregroundColor: amber
            ]
            let cardText = kind == .intro ? title.uppercased() : "POCKET CCD"
            let cardSize = cardText.size(withAttributes: titleAttributes)
            cardText.draw(at: CGPoint(x: (size.width - cardSize.width) / 2,
                                      y: size.height / 2 - cardSize.height / 2),
                          withAttributes: titleAttributes)

            let subtitle: String
            if kind == .intro {
                let day = items.first?.entry.createdAt.formatted(.dateTime.month(.wide).day()) ?? ""
                subtitle = "\(items.count) FRAMES  ·  \(day)"
            } else {
                subtitle = "NO SUBSCRIPTION  ·  \(items.count) FRAMES"
            }
            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 26, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.62 * alpha)
            ]
            let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
            subtitle.draw(at: CGPoint(x: (size.width - subtitleSize.width) / 2,
                                      y: size.height / 2 + cardSize.height / 2 + 26),
                          withAttributes: subtitleAttributes)
            if kind == .intro, let note {
                let noteAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 28),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.55 * alpha)
                ]
                let noteSize = note.size(withAttributes: noteAttributes)
                note.draw(at: CGPoint(x: (size.width - noteSize.width) / 2,
                                      y: size.height / 2 + cardSize.height / 2 + 78),
                          withAttributes: noteAttributes)
            }
        }
    }

    private static func makePhoto(item: Item, nextItem: Item?, index: Int, count: Int,
                                  title: String, note: String?, size: CGSize,
                                  progress: CGFloat, blend: CGFloat,
                                  pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        drawIntoBuffer(size: size, pool: pool) { context in
            context.setFillColor(UIColor(red: 0.055, green: 0.058, blue: 0.052, alpha: 1).cgColor)
            context.fill(CGRect(origin: .zero, size: size))

            let photoRect = CGRect(x: 44, y: 210, width: 992, height: 1488)
            context.saveGState()
            context.clip(to: photoRect)
            // Both frames of a crossfade must share one zoom, or the outgoing
            // photo stays visible as a rim around the incoming one. The
            // outgoing frame eases back from 1.07 to 1.0 during the blend so
            // the two never differ in size.
            let isTransition = nextItem != nil && blend > 0
            if let nextItem, isTransition {
                // A horizontal slide reads as turning to the next photo; a
                // fade alone read as a slideshow. The outgoing frame exits
                // left while the incoming one arrives from the right, both at
                // the same scale.
                draw(image: item.image, in: photoRect, progress: 0, index: index,
                     offsetX: -photoRect.width * blend)
                draw(image: nextItem.image, in: photoRect, progress: 0, index: index + 1,
                     offsetX: photoRect.width * (1 - blend))
                // A dim shutter flash over the first third of the slide.
                if blend < 0.35 {
                    context.setFillColor(UIColor.white.withAlphaComponent((0.35 - blend) / 0.35 * 0.16).cgColor)
                    context.fill(photoRect)
                }
            } else {
                draw(image: item.image, in: photoRect, progress: progress, index: index)
            }
            context.restoreGState()

            title.draw(at: CGPoint(x: 44, y: 68), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 46, weight: .bold),
                .foregroundColor: UIColor(red: 0.94, green: 0.68, blue: 0.24, alpha: 1)
            ])
            let footer = "\(String(format: "%02d", index + 1))/\(String(format: "%02d", count))  •  \(item.entry.cameraRawValue)  •  \(item.entry.createdAt.formatted(.dateTime.hour().minute()))"
            footer.draw(at: CGPoint(x: 44, y: 1745), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 25, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.8)
            ])
            if let note {
                note.draw(in: CGRect(x: 44, y: 1794, width: 992, height: 80), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 26), .foregroundColor: UIColor.white.withAlphaComponent(0.62)
                ])
            }
        }
    }

    private static func draw(image: UIImage, in rect: CGRect, progress: CGFloat,
                             index: Int, alpha: CGFloat = 1, offsetX: CGFloat = 0) {
        // No zoom. The outgoing and incoming photos share one scale, and only
        // a few points of vertical breathing keep the frame from looking like
        // a frozen slide.
        let direction: CGFloat = index.isMultiple(of: 2) ? 1 : -1
        let drift = (progress - 0.5) * 10 * direction
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2 + offsetX,
                             y: rect.midY - drawSize.height / 2 + drift)
        image.draw(in: CGRect(origin: origin, size: drawSize), blendMode: .normal, alpha: alpha)
    }

    private static func drawIntoBuffer(size: CGSize, pool: CVPixelBufferPool?,
                                       draw: (CGContext) -> Void) -> CVPixelBuffer? {
        var optional: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) }
        if optional == nil {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB, nil, &optional)
        }
        guard let buffer = optional else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        draw(context)
        return buffer
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

/// What an export is *for*, named after the place it gets posted. Users do not
/// know "4:5" or "9:16"; they know Instagram and TikTok, and they know whether
/// they are making a feed post or a story.
enum ExportPreset: String, CaseIterable, Identifiable {
    case square
    case feed
    case story
    case tiktok

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .square: "SQUARE"
        case .feed: "IG FEED"
        case .story: "IG STORY"
        case .tiktok: "TIKTOK"
        }
    }

    /// Second line in plain language, so the ratio reads as a detail.
    var hint: LocalizedStringResource {
        switch self {
        case .square: "1:1 · anywhere"
        case .feed: "4:5 · full-width post"
        case .story: "9:16 · 24 hours"
        case .tiktok: "9:16 · full screen"
        }
    }

    var size: CGSize {
        switch self {
        case .square: CGSize(width: 2160, height: 2160)
        case .feed: CGSize(width: 1080, height: 1350)
        case .story, .tiktok: CGSize(width: 1080, height: 1920)
        }
    }

    var columns: Int { 4 }

    /// IG Story covers the top ~250 pt with the account row and the bottom
    /// ~340 pt with the reply bar; TikTok takes ~180 top and ~400 bottom.
    /// Everything the user needs to read stays between these insets.
    var topInset: CGFloat {
        switch self {
        case .square, .feed: 0
        case .story: 250
        case .tiktok: 180
        }
    }

    var bottomInset: CGFloat {
        switch self {
        case .square, .feed: 0
        case .story: 340
        case .tiktok: 400
        }
    }

    var sideMargin: CGFloat { self == .square ? 54 : 34 }
    var gap: CGFloat { self == .square ? 22 : 12 }
    var titleSize: CGFloat { self == .square ? 46 : 34 }
    var detailSize: CGFloat { self == .square ? 22 : 18 }
    var labelSize: CGFloat { self == .square ? 24 : 18 }
    var titleY: CGFloat { topInset + (self == .square ? 62 : 38) }
    var detailY: CGFloat { topInset + (self == .square ? 118 : 84) }
    /// First row of thumbnails.
    var header: CGFloat { topInset + 150 }
    /// Distance from the bottom edge to the last row.
    var bottomMargin: CGFloat { bottomInset + (self == .square ? 54 : 34) }

    /// SF Symbol used for this preset in the export sheet.
    var sheetSymbol: String {
        switch self {
        case .square: "square.grid.3x3"
        case .feed: "rectangle.portrait"
        case .story: "rectangle.portrait.on.rectangle.portrait"
        case .tiktok: "play.rectangle"
        }
    }
}

enum ContactSheetRenderer {
    private static func metadataLine(for entries: [RollEntry], count: Int) -> String? {
        guard !entries.isEmpty else { return nil }
        let cameras = Set(entries.map(\.cameraRawValue)).compactMap { CCDLook(rawValue: $0)?.shortName }
        let ordered = cameras.sorted()
        let spans = entries.map(\.createdAt)
        guard let first = spans.min(), let last = spans.max() else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MM"
        let span = formatter.string(from: first) == formatter.string(from: last)
            ? formatter.string(from: first)
            : "\(formatter.string(from: first)) — \(formatter.string(from: last))"
        return "\(ordered.joined(separator: " / ")) · \(span) · \(count) FRAMES"
    }

    static func render(
        images: [UIImage],
        entries: [RollEntry],
        format preset: ExportPreset = .square
    ) -> UIImage? {
        guard !images.isEmpty else { return nil }
        let size = preset.size
        let margin = preset.sideMargin
        let header = preset.header
        let gap = preset.gap
        let rects = layoutRects(
            count: images.count,
            format: preset,
            size: size,
            margin: margin,
            header: header,
            gap: gap
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.055, green: 0.058, blue: 0.052, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let title = "POCKET ROLL  \(images.count)/\(RollStore.capacity)"
            title.draw(at: CGPoint(x: margin, y: preset.titleY), withAttributes: [
                .font: UIFont.monospacedSystemFont(ofSize: preset.titleSize, weight: .bold),
                .foregroundColor: UIColor(red: 0.94, green: 0.68, blue: 0.24, alpha: 1)
            ])

            // Restrained metadata: cameras, date span, frame count.
            if let detail = metadataLine(for: entries, count: images.count) {
                detail.draw(at: CGPoint(x: margin, y: preset.detailY), withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: preset.detailSize, weight: .medium),
                    .foregroundColor: UIColor(white: 0.62, alpha: 1)
                ])
            }

            for (index, image) in images.enumerated() {
                let rect = rects[index]
                drawAspectFill(image, in: rect, context: context)
                let label = String(format: "%02d", index + 1)
                label.draw(at: CGPoint(x: rect.minX + 18, y: rect.maxY - 54), withAttributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: preset.labelSize, weight: .bold),
                    .foregroundColor: UIColor.white
                ])
            }
        }
    }

    static func layoutRects(
        count: Int,
        format preset: ExportPreset,
        size: CGSize? = nil,
        margin: CGFloat? = nil,
        header: CGFloat? = nil,
        gap: CGFloat? = nil
    ) -> [CGRect] {
        guard count > 0 else { return [] }
        let canvas = size ?? preset.size
        let resolvedGap = gap ?? preset.gap
        let resolvedMargin = margin ?? preset.sideMargin
        let resolvedHeader = header ?? preset.header
        let contentWidth = canvas.width - resolvedMargin * 2
        let contentHeight = canvas.height - resolvedHeader - preset.bottomMargin

        if count == 5 {
            let column = (contentWidth - resolvedGap) / 2
            let row = (contentHeight - resolvedGap * 2) / 3
            let rightX = resolvedMargin + column + resolvedGap
            let secondY = resolvedHeader + row + resolvedGap
            let thirdY = secondY + row + resolvedGap
            return [
                CGRect(x: resolvedMargin, y: resolvedHeader, width: column, height: row),
                CGRect(x: rightX, y: resolvedHeader, width: column, height: row),
                CGRect(x: resolvedMargin, y: secondY, width: column, height: row * 2 + resolvedGap),
                CGRect(x: rightX, y: secondY, width: column, height: row),
                CGRect(x: rightX, y: thirdY, width: column, height: row)
            ]
        }

        let columns = count <= 5 ? min(2, count) : preset.columns
        let rows = Int(ceil(Double(count) / Double(columns)))
        let cellWidth = (contentWidth - CGFloat(columns - 1) * resolvedGap) / CGFloat(columns)
        let cellHeight = (contentHeight - CGFloat(max(rows - 1, 0)) * resolvedGap) / CGFloat(rows)
        return (0..<count).map { index in
            let column = index % columns
            let row = index / columns
            let isSingleLastCell = index == count - 1 && count % columns == 1
            return CGRect(
                x: isSingleLastCell ? resolvedMargin : resolvedMargin + CGFloat(column) * (cellWidth + resolvedGap),
                y: resolvedHeader + CGFloat(row) * (cellHeight + resolvedGap),
                width: isSingleLastCell ? contentWidth : cellWidth,
                height: cellHeight
            )
        }
    }

    private static func drawAspectFill(
        _ image: UIImage,
        in rect: CGRect,
        context: UIGraphicsImageRendererContext
    ) {
        context.cgContext.saveGState()
        context.cgContext.clip(to: rect)
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
        context.cgContext.restoreGState()
    }
}

enum CameraReceiptRenderer {
    static func render(
        image: UIImage,
        camera: CCDLook,
        mode: CaptureMode,
        identity: SensorIdentity,
        date: Date
    ) -> UIImage {
        let width: CGFloat = 1440
        let photoHeight = width / 4 * 3
        let footer: CGFloat = 260
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: photoHeight + footer), format: format)
            .image { context in
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: photoHeight + footer))
                ContactSheetRenderer.renderPhoto(image, in: CGRect(x: 0, y: 0, width: width, height: photoHeight), context: context)

                camera.rawValue.draw(at: CGPoint(x: 64, y: photoHeight + 54), withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 52, weight: .bold),
                    .foregroundColor: UIColor(red: 0.94, green: 0.68, blue: 0.24, alpha: 1)
                ])
                let details = "\(mode.shortTitle)  •  \(identity.serial)  •  \(date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))"
                details.draw(at: CGPoint(x: 64, y: photoHeight + 142), withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 28, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.72)
                ])
            }
    }
}

enum PairedMemoryRenderer {
    static func render(local: UIImage, remote: UIImage, date: Date = .now) -> UIImage {
        let size = CGSize(width: 1080, height: 1920)
        let margin: CGFloat = 44
        let gap: CGFloat = 24
        let header: CGFloat = 150
        let footer: CGFloat = 100
        let photoHeight = (size.height - header - footer - gap - margin) / 2
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.055, green: 0.058, blue: 0.052, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            "POCKET CCD / TWO VIEWPOINTS".draw(
                at: CGPoint(x: margin, y: 54),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 34, weight: .bold),
                    .foregroundColor: UIColor(red: 0.94, green: 0.68, blue: 0.24, alpha: 1)
                ]
            )
            ContactSheetRenderer.renderPhoto(
                local,
                in: CGRect(x: margin, y: header, width: size.width - margin * 2, height: photoHeight),
                context: context
            )
            ContactSheetRenderer.renderPhoto(
                remote,
                in: CGRect(x: margin, y: header + photoHeight + gap, width: size.width - margin * 2, height: photoHeight),
                context: context
            )
            date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()).draw(
                at: CGPoint(x: margin, y: size.height - 66),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.65)
                ]
            )
        }
    }
}

private extension ContactSheetRenderer {
    static func renderPhoto(
        _ image: UIImage,
        in rect: CGRect,
        context: UIGraphicsImageRendererContext
    ) {
        drawAspectFill(image, in: rect, context: context)
    }
}



/// Shared decode cache so scrolling the roll does not re-parse JPEGs.
enum RollThumbnailCache {
    /// NSCache is documented as thread-safe. This holder makes that external
    /// synchronization guarantee explicit at the Swift concurrency boundary.
    private final class Storage: @unchecked Sendable {
        let cache: NSCache<NSString, UIImage>
        private var memoryObserver: NSObjectProtocol?

        init() {
            let cache = NSCache<NSString, UIImage>()
            cache.countLimit = 80
            cache.totalCostLimit = 64 * 1024 * 1024
            self.cache = cache
            memoryObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.cache.removeAllObjects()
            }
        }

        deinit {
            if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        }
    }

    private static let storage = Storage()

    static func cached(url: URL, maxPixel: CGFloat) -> UIImage? {
        storage.cache.object(forKey: "\(url.lastPathComponent)@\(Int(maxPixel))" as NSString)
    }

    static func thumbnail(url: URL, maxPixel: CGFloat) -> UIImage? {
        let key = "\(url.lastPathComponent)@\(Int(maxPixel))" as NSString
        if let hit = storage.cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        let cost = cgImage.bytesPerRow * cgImage.height
        storage.cache.setObject(image, forKey: key, cost: cost)
        return image
    }
}
