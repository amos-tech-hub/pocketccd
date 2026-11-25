import AVKit
import Photos
import SwiftUI
import UniformTypeIdentifiers

private struct RollSharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct RollImageExport: Identifiable {
    let id = UUID()
    let image: UIImage
    let title: String
}

private final class RollVideoExport: Identifiable {
    let id = UUID()
    let url: URL

    init(url: URL) {
        self.url = url
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

struct RollThumbnailView: View {
    let url: URL
    var maxPixel: CGFloat = 720
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: url) {
                if let cached = RollThumbnailCache.cached(url: url, maxPixel: maxPixel) {
                    image = cached
                    return
                }
                let loaded = await Task.detached(priority: .userInitiated) {
                    RollThumbnailCache.thumbnail(url: url, maxPixel: maxPixel)
                }.value
                image = loaded
            }
    }
}

struct PocketRollView: View {
    @Bindable var store: RollStore
    /// When set, the page shows a developed roll read-only instead of the
    /// current one: same grid, same previews, no capture or archive actions.
    var archive: RollArchive? = nil
    @State private var sharePayload: RollSharePayload?
    @State private var previewEntry: RollEntry?
    @State private var imageExport: RollImageExport?
    @State private var videoExport: RollVideoExport?
    @State private var showActions = false
    @State private var showExportPresets = false
    @State private var showArchive = false
    @State private var showDevelopConfirm = false
    @State private var isExporting = false
    @State private var rollTitle = ""
    @State private var rollNote = ""
    @State private var showBackupImporter = false
    @State private var backupStatus: String?
    @State private var isBuildingDay = false
    @State private var showRollDetails = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var isSavingSelected = false
    @State private var saveToast: String?
    @Environment(\.dismiss) private var dismiss

    private var surface: Color { Color(red: 0.075, green: 0.078, blue: 0.072) }

    private var isArchive: Bool { archive != nil }
    private var entries: [RollEntry] {
        if let archive {
            return store.archives.first(where: { $0.id == archive.id })?.entries ?? []
        }
        return store.entries
    }
    private var displayTitle: String {
        if let title = archive?.title, !title.isEmpty { return title }
        return rollTitle.isEmpty ? "Pocket Roll" : rollTitle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 2) {
                    Text(displayTitle)
                        .pocketFont(27, weight: .bold)
                        .foregroundStyle(CameraTheme.ink)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(verbatim: String(format: "%02d / %d", entries.count, isArchive ? max(entries.count, 1) : store.capacity))
                        .pocketFont(11, weight: .bold, design: .monospaced)
                        .tracking(1.2)
                        .foregroundStyle(CameraTheme.accent)
                }

                HStack(alignment: .center, spacing: 6) {
                    Text(verbatim: subtitle)
                        .pocketFont(8, weight: .bold, design: .monospaced)
                        .tracking(1.6)
                        .foregroundStyle(CameraTheme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !entries.isEmpty {
                        if isSelecting {
                            let allSelected = selectedIDs.count == entries.count
                            Button {
                                if allSelected {
                                    selectedIDs.removeAll()
                                } else {
                                    selectedIDs = Set(entries.map(\.id))
                                }
                            } label: {
                                Text(allSelected ? "NONE" : "ALL")
                                    .pocketFont(8, weight: .bold, design: .monospaced)
                                    .tracking(1.2)
                                    .foregroundStyle(CameraTheme.accent)
                                    .padding(.horizontal, 9)
                                    .frame(height: 30)
                                    .overlay { Rectangle().stroke(CameraTheme.accent.opacity(0.6), lineWidth: 1) }
                                    .frame(height: CameraTheme.hit)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            withAnimation(.easeOut(duration: 0.16)) {
                                if isSelecting {
                                    isSelecting = false
                                    selectedIDs.removeAll()
                                } else {
                                    isSelecting = true
                                }
                            }
                        } label: {
                            Text(isSelecting ? "CANCEL" : "SELECT")
                                .pocketFont(8, weight: .bold, design: .monospaced)
                                .tracking(1.2)
                                .foregroundStyle(isSelecting ? CameraTheme.ink : CameraTheme.muted)
                                .padding(.horizontal, 9)
                                .frame(height: 30)
                                .overlay { Rectangle().stroke(isSelecting ? CameraTheme.ink.opacity(0.55) : CameraTheme.line, lineWidth: 1) }
                                .frame(height: CameraTheme.hit)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSelecting ? "Cancel selection" : "Select photos")
                    }

                    if !isSelecting {
                        Button {
                            withAnimation(.easeOut(duration: 0.16)) { showActions = true }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "ellipsis")
                                    .pocketFont(11, weight: .bold)
                                Text("MORE")
                                    .pocketFont(8, weight: .bold, design: .monospaced)
                                    .tracking(1.2)
                            }
                            .foregroundStyle(CameraTheme.muted)
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                            .frame(height: CameraTheme.hit)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("More roll actions")
                    }
                }

                rollGrid


                if showRollDetails {
                    VStack(spacing: 8) {
                        TextField("Name this roll", text: $rollTitle)
                        TextField("Add one line about these days", text: $rollNote)
                    }
                    .pocketFont(12)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(CameraTheme.cameraWell)
                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                    .onSubmit(saveMetadata)
                }

                if entries.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("YOUR ROLL IS READY")
                            .pocketFont(8, weight: .bold, design: .monospaced)
                            .tracking(2)
                            .foregroundStyle(CameraTheme.muted)
                        Text("Take a photo and it lands here automatically.")
                            .pocketFont(13)
                            .foregroundStyle(CameraTheme.ink)
                        PocketButton(title: "OPEN CAMERA", filled: true) { dismiss() }
                    }
                    .padding(14)
                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                    .padding(.top, 12)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 16)
            // Duo / iPad: the roll reads as one phone-wide column.
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            rollActionBar
        }
        // Attached to the page, not to the action bar: an overlay inherits its
        // host's frame, and the docked bar is too short for a four-row sheet.
        .overlay {
            PocketSheet("EXPORT", isPresented: $showExportPresets) {
                ExportPresetRows(isExporting: isExporting) { preset in
                    showExportPresets = false
                    exportSheet(preset)
                }
            }
        }
        .overlay {
            // Encoding a day can take several seconds; without a blocking
            // indicator the tap reads as dead.
            if isBuildingDay {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView()
                            .tint(CameraTheme.accent)
                            .scaleEffect(1.2)
                        Text("Making your Pocket Day…")
                            .pocketFont(11, weight: .bold, design: .monospaced)
                            .tracking(0.8)
                            .foregroundStyle(CameraTheme.ink)
                    }
                    .padding(22)
                    .background(CameraTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isBuildingDay)
        .background(surface.ignoresSafeArea())
        .foregroundStyle(CameraTheme.ink)
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guard !isArchive else { return }
            rollTitle = store.currentTitle
            rollNote = store.currentNote
        }
        .onDisappear {
            guard !isArchive else { return }
            saveMetadata()
        }
        .tint(CameraTheme.accent)
        .sheet(item: $sharePayload) { payload in
            ActivityShareSheet(items: payload.items, onComplete: { _ in
                for case let url as URL in payload.items where url.pathExtension == "pocketccdbackup" {
                    try? FileManager.default.removeItem(at: url)
                }
                sharePayload = nil
            })
        }
        .fullScreenCover(item: $previewEntry) { entry in
            RollPhotoPreview(entries: entries, start: entry, store: store, archiveID: archive?.id)
        }
        .fullScreenCover(item: $imageExport) { export in
            RollImageExportPreview(export: export)
        }
        .fullScreenCover(item: $videoExport) { export in
            RollVideoExportPreview(export: export)
        }
        .fileImporter(
            isPresented: $showBackupImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            restoreBackup(result)
        }
        .overlay {
            PocketAlert(
                title: "POCKET ROLL",
                message: backupStatus ?? "",
                isPresented: Binding(
                    get: { backupStatus != nil },
                    set: { if !$0 { backupStatus = nil } }
                )
            )
        }
        .overlay {
            PocketSheet("ROLL ACTIONS", isPresented: $showActions) {
                if !isArchive {
                    PocketActionRow(title: "Name this roll", symbol: "pencil.line") {
                        showActions = false
                        showRollDetails = true
                    }
                    PocketSheetDivider()
                }
                PocketActionRow(title: "Export contact sheet", symbol: "square.grid.3x3") {
                    showActions = false
                    showExportPresets = true
                }
                PocketSheetDivider()
                PocketActionRow(title: "Pocket Day video", symbol: "play.rectangle", isBusy: isBuildingDay) {
                    showActions = false
                    createDayVideo()
                }
                if !isArchive {
                    PocketSheetDivider()
                    PocketActionRow(title: "Roll archive", symbol: "film.stack", showsChevron: true) {
                        showActions = false
                        showArchive = true
                    }
                }
                PocketSheetDivider()
                PocketActionRow(title: "Export local backup", symbol: "externaldrive") {
                    showActions = false
                    guard !isExporting else { return }
                    isExporting = true
                    Task {
                        defer { isExporting = false }
                        if let url = await store.exportBackup() {
                            sharePayload = RollSharePayload(items: [url])
                        } else {
                            backupStatus = String(localized: "Couldn’t create the backup. Try again.")
                        }
                    }
                }
                PocketSheetDivider()
                PocketActionRow(title: "Restore local backup", symbol: "externaldrive.badge.plus") {
                    showActions = false
                    showBackupImporter = true
                }
                if !isArchive {
                    PocketSheetDivider()
                    PocketActionRow(title: "Develop roll and start new", symbol: "arrow.triangle.2.circlepath", destructive: true) {
                        showActions = false
                        showDevelopConfirm = true
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showArchive) {
            ArchivedRollsView(store: store)
        }
        .overlay {
            PocketSheet("DEVELOP THIS ROLL?", isPresented: $showDevelopConfirm) {
                Text("The current photos move to the Roll Archive and stay available for viewing and export.")
                    .pocketFont(11)
                    .foregroundStyle(CameraTheme.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                PocketSheetDivider()
                PocketActionRow(title: "Archive roll and start new", symbol: "archivebox", destructive: true) {
                    showDevelopConfirm = false
                    store.startNewRoll()
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let saveToast {
                Text(saveToast)
                    .pocketFont(10, weight: .bold, design: .monospaced)
                    .tracking(0.8)
                    .foregroundStyle(CameraTheme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(CameraTheme.panel)
                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                    .padding(.bottom, 92)
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .top) { PocketDismissBar(label: "CLOSE") }
    }

    private func rollActionButton(_ title: LocalizedStringResource, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.mini).tint(CameraTheme.ink)
                } else {
                    Text(title)
                        .pocketFont(8.5, weight: .bold, design: .monospaced)
                        .tracking(1.4)
                        .foregroundStyle(CameraTheme.ink)
                }
            }
            .frame(maxWidth: .infinity, minHeight: CameraTheme.control)
            .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private var subtitle: String {
        let date = entries.map(\.createdAt).min() ?? archive?.createdAt ?? .now
        let stamp = date.formatted(.dateTime.day().month(.abbreviated).year())
        let note = (archive?.note ?? store.currentNote).trimmingCharacters(in: .whitespacesAndNewlines)
        return note.isEmpty ? stamp.uppercased() : "\(stamp.uppercased()) · \(note.uppercased())"
    }

    /// Actions stay docked below the contact sheet: with an empty roll the grid
    /// can be several screens tall, and export must remain one tap away.
    private var rollActionBar: some View {
        VStack(spacing: 8) {
            if isSelecting {
                HStack(alignment: .center, spacing: 10) {
                    Text(selectedIDs.isEmpty
                        ? String(localized: "TAP PHOTOS TO SELECT")
                        : String(localized: "\(selectedIDs.count) SELECTED"))
                        .pocketFont(8, weight: .bold, design: .monospaced)
                        .tracking(1.4)
                        .foregroundStyle(selectedIDs.isEmpty ? CameraTheme.muted : CameraTheme.accent)
                    Spacer(minLength: 8)
                }
                .padding(.top, 4)

                Button {
                    saveSelectedToPhotos()
                } label: {
                    HStack(spacing: 6) {
                        if isSavingSelected {
                            ProgressView().controlSize(.mini).tint(.black)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .pocketFont(12, weight: .bold)
                        }
                        Text(selectedIDs.isEmpty
                            ? String(localized: "SAVE TO PHOTOS")
                            : String(localized: "SAVE TO PHOTOS (\(selectedIDs.count))"))
                            .pocketFont(8.5, weight: .bold, design: .monospaced)
                            .tracking(1.4)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: CameraTheme.control + 6)
                    .background(selectedIDs.isEmpty ? CameraTheme.muted.opacity(0.45) : CameraTheme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selectedIDs.isEmpty || isSavingSelected)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    Text(verbatim: entries.count == 1
                        ? String(localized: "1 FRAME · ONE EVENING")
                        : String(localized: "\(entries.count) FRAMES · ONE EVENING"))
                        .pocketFont(8, weight: .bold, design: .monospaced)
                        .tracking(1.4)
                        .foregroundStyle(CameraTheme.muted)
                    Spacer(minLength: 8)
                }
                .padding(.top, 4)

                HStack(spacing: 8) {
                    // One primary exit. The 9:16 sheet is the thing that gets
                    // sent, so it no longer hides behind a four-way format
                    // question; the format sheet and Pocket Day are the
                    // alternatives, not peers of the main action.
                    rollActionButton("EXPORT 9:16", busy: isExporting) { exportSheet(.story) }
                    rollActionButton("FORMAT") { showExportPresets = true }
                }
                .disabled(entries.isEmpty || isExporting)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(surface)
        .overlay(alignment: .top) {
            Rectangle().fill(CameraTheme.line).frame(height: 0.5)
        }
    }

    private var rollGrid: some View {
        let frames = entries
        // Adaptive columns so a Duo-width roll does not stay three huge tiles
        // across 1500 pt.
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 6)]
        // A recovered index can legitimately hold more frames than the
        // configured roll size. Clamp instead of building a reversed Range,
        // which traps at runtime (`20 ..< 12`).
        let emptySlots = max(store.capacity - frames.count, 0)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(frames) { entry in
                let isSelected = selectedIDs.contains(entry.id)
                RollThumbnailView(url: store.thumbnailURL(for: entry), maxPixel: 720)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(CameraTheme.cameraWell)
                    .overlay {
                        if isSelecting {
                            Rectangle()
                                .stroke(isSelected ? CameraTheme.accent : Color.white.opacity(0.25),
                                        lineWidth: isSelected ? 2 : 0.75)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelecting {
                            ZStack {
                                Rectangle()
                                    .fill(isSelected ? CameraTheme.accent : Color.black.opacity(0.55))
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        Rectangle().stroke(isSelected ? CameraTheme.accent : Color.white.opacity(0.7), lineWidth: 1)
                                    }
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.black)
                                }
                            }
                            .padding(6)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isSelecting {
                            if isSelected {
                                selectedIDs.remove(entry.id)
                            } else {
                                selectedIDs.insert(entry.id)
                            }
                            UISelectionFeedbackGenerator().selectionChanged()
                        } else {
                            previewEntry = entry
                        }
                    }
            }
            // Every remaining slot is drawn, so a short roll reads as a contact
            // sheet with room left rather than a half-empty page.
            ForEach(0..<emptySlots, id: \.self) { slot in
                Color.clear
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay {
                        if slot == 0 {
                            VStack(spacing: 6) {
                                Text("+")
                                    .pocketFont(16, weight: .light, design: .monospaced)
                                Text("\(emptySlots) MORE")
                                    .pocketFont(7, weight: .bold, design: .monospaced)
                                    .tracking(1.2)
                            }
                            .foregroundStyle(CameraTheme.muted.opacity(0.65))
                        }
                    }
                    .overlay {
                        Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(CameraTheme.line.opacity(slot == 0 ? 1 : 0.55))
                    }
            }
        }
    }

    private func exportSheet(_ format: ExportPreset) {
        guard !isExporting else { return }
        isExporting = true
        let urls = entries.map { store.thumbnailURL(for: $0) }
        let rollEntries = entries
        let target = format
        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let images = urls.compactMap { RollThumbnailCache.thumbnail(url: $0, maxPixel: 1200) }
                return ContactSheetRenderer.render(images: images, entries: rollEntries, format: target)
            }.value
            isExporting = false
            if let image {
                imageExport = RollImageExport(image: image, title: String(localized: target.title))
            } else {
                backupStatus = String(localized: "Couldn’t create this contact sheet. Try again.")
            }
        }
    }

    private func saveMetadata() {
        store.updateCurrentMetadata(title: rollTitle, note: rollNote)
    }

    private func restoreBackup(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            Task {
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    // Streaming import: the store reads one photo at a time
                    // instead of materializing the whole backup in memory.
                    let count = try await store.importBackup(from: url)
                    backupStatus = String(localized: "Restored \(count) photos without replacing existing rolls.")
                } catch {
                    backupStatus = error.localizedDescription
                }
            }
        } catch {
            backupStatus = error.localizedDescription
        }
    }

    private func createDayVideo() {
        isBuildingDay = true
        Task {
            do {
                let url = try await store.daySummaryVideo()
                videoExport = RollVideoExport(url: url)
            } catch {
                backupStatus = error.localizedDescription
            }
            isBuildingDay = false
        }
    }

    private func saveSelectedToPhotos() {
        guard !isSavingSelected else { return }
        let targets = entries.filter { selectedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        isSavingSelected = true
        let items = targets.map { (entry: $0, url: store.thumbnailURL(for: $0)) }
        Task { @MainActor in
            var savedCount = 0
            for item in items {
                let image = await Task.detached(priority: .userInitiated) {
                    UIImage(contentsOfFile: item.url.path)
                }.value
                if let image,
                   await CameraController.saveToLibrary(image, capturedAt: item.entry.createdAt, metadata: item.entry.metadata) {
                    savedCount += 1
                }
            }
            isSavingSelected = false
            withAnimation(.easeOut(duration: 0.16)) {
                isSelecting = false
                selectedIDs.removeAll()
            }
            let message = savedCount == items.count
                ? String(localized: "Saved \(savedCount) photos to Photos")
                : String(localized: "Saved \(savedCount) of \(items.count) photos")
            withAnimation(.easeOut(duration: 0.16)) { saveToast = message }
            try? await Task.sleep(for: .seconds(2))
            if saveToast == message {
                withAnimation(.easeOut(duration: 0.2)) { saveToast = nil }
            }
        }
    }
}

private struct BalancedRollGrid: View {
    @Bindable var store: RollStore

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        let keeperID = store.accidentKeeper?.id
        Group {
            if store.entries.count == 5 {
                FivePhotoRollLayout(store: store, keeperID: keeperID)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                        RollPhotoTile(
                            imageURL: store.thumbnailURL(for: entry),
                            number: index + 1,
                            isKeeper: entry.id == keeperID,
                            hasNote: entry.note != nil
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(CameraTheme.paperInk.opacity(0.055))
        .frame(maxWidth: .infinity)
    }
}

/// A dedicated five-frame proof layout. Five is the one count where a regular
/// two-column grid reads as an accidental missing tile; this composition fills
/// the rectangle while giving the middle frame a deliberate hero position.
private struct FivePhotoRollLayout: View {
    @Bindable var store: RollStore
    let keeperID: UUID?

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 8
            let column = (proxy.size.width - gap) / 2
            let row = (proxy.size.height - gap * 2) / 3

            ZStack(alignment: .topLeading) {
                tile(at: 0, width: column, height: row)
                    .offset(x: 0, y: 0)
                tile(at: 1, width: column, height: row)
                    .offset(x: column + gap, y: 0)
                tile(at: 2, width: column, height: row * 2 + gap)
                    .offset(x: 0, y: row + gap)
                tile(at: 3, width: column, height: row)
                    .offset(x: column + gap, y: row + gap)
                tile(at: 4, width: column, height: row)
                    .offset(x: column + gap, y: (row + gap) * 2)
            }
        }
        .frame(height: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Five photo Pocket Roll")
    }

    @ViewBuilder
    private func tile(at index: Int, width: CGFloat, height: CGFloat) -> some View {
        let entry = store.entries[index]
        RollPhotoTile(
            imageURL: store.thumbnailURL(for: entry),
            number: index + 1,
            isKeeper: entry.id == keeperID,
            hasNote: entry.note != nil,
            height: height
        )
        .frame(width: width, height: height)
    }
}

private struct RollPhotoTile: View {
    let imageURL: URL
    let number: Int
    let isKeeper: Bool
    let hasNote: Bool
    var height: CGFloat = 190

    var body: some View {
        RollThumbnailView(url: imageURL, maxPixel: 720)
            .background(CameraTheme.paperInk.opacity(0.08))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            .overlay { Rectangle().stroke(CameraTheme.paper, lineWidth: 3) }
            .overlay(alignment: .bottomLeading) {
                Text(number, format: .number)
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(CameraTheme.paperInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(CameraTheme.paper.opacity(0.88))
                    .padding(5)
            }
            .overlay(alignment: .topTrailing) {
                if isKeeper {
                    Image(systemName: "wand.and.stars")
                        .font(.caption.bold())
                        .padding(7)
                        .background(.black.opacity(0.72), in: Circle())
                        .padding(6)
                        .accessibilityLabel("Accident Keeper")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasNote {
                    Image(systemName: "text.quote")
                        .font(.caption2.bold())
                        .padding(6)
                        .background(.black.opacity(0.68), in: Circle())
                        .padding(6)
                        .accessibilityLabel("Has note")
                }
            }
    }
}

private struct RollImageExportPreview: View {
    let export: RollImageExport
    @Environment(\.dismiss) private var dismiss
    @State private var sharePayload: RollSharePayload?
    @State private var isSaving = false
    @State private var saveMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            PocketDismissBar(label: "CLOSE")
            ZoomableImage(image: export.image)
                .background(Color.black)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    PocketButton(title: isSaving ? "SAVING…" : "SAVE IMAGE", filled: true) {
                        saveImage()
                    }
                    .disabled(isSaving)
                    PocketButton(title: "SHARE", filled: false) {
                        sharePayload = RollSharePayload(items: [export.image])
                    }
                }
                .padding(12)
                .background(CameraTheme.background)
                .overlay(alignment: .top) { Rectangle().fill(CameraTheme.line).frame(height: 1) }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(item: $sharePayload) { payload in
            ActivityShareSheet(items: payload.items, onComplete: { _ in sharePayload = nil })
        }
        .overlay {
            PocketAlert(
                title: "POCKETCCD",
                message: saveMessage ?? "",
                isPresented: Binding(
                    get: { saveMessage != nil },
                    set: { if !$0 { saveMessage = nil } }
                )
            )
        }
    }

    private func saveImage() {
        isSaving = true
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                isSaving = false
                saveMessage = String(localized: "Allow Photos access to save this image.")
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: export.image)
                }
                saveMessage = String(localized: "Saved to Photos.")
            } catch {
                saveMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

private struct RollVideoExportPreview: View {
    let export: RollVideoExport
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    @State private var sharePayload: RollSharePayload?
    @State private var isSaving = false
    @State private var saveMessage: String?

    init(export: RollVideoExport) {
        self.export = export
        _player = State(initialValue: AVPlayer(url: export.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            PocketDismissBar(label: "CLOSE")
            VideoPlayer(player: player)
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        PocketButton(title: isSaving ? "SAVING…" : "SAVE VIDEO", filled: true, action: saveVideo)
                            .disabled(isSaving)
                        PocketButton(title: "SHARE", filled: false) {
                            sharePayload = RollSharePayload(items: [export.url])
                        }
                    }
                    .padding(12)
                    .background(CameraTheme.background)
                    .overlay(alignment: .top) { Rectangle().fill(CameraTheme.line).frame(height: 1) }
                }
                .onAppear { player.play() }
                .onDisappear { player.pause() }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(item: $sharePayload) { payload in
            ActivityShareSheet(items: payload.items, onComplete: { _ in sharePayload = nil })
        }
        .overlay {
            PocketAlert(
                title: "POCKETCCD",
                message: saveMessage ?? "",
                isPresented: Binding(
                    get: { saveMessage != nil },
                    set: { if !$0 { saveMessage = nil } }
                )
            )
        }
    }

    private func saveVideo() {
        isSaving = true
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                isSaving = false
                saveMessage = String(localized: "Allow Photos access to save this video.")
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: export.url)
                }
                saveMessage = String(localized: "Saved to Photos.")
            } catch {
                saveMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

struct ArchivedRollsView: View {
    @Bindable var store: RollStore
    @State private var actionArchive: RollArchive?
    @State private var deleteArchive: RollArchive?
    @State private var imageExport: RollImageExport?
    @State private var openArchive: OpenArchive?
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.archives.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NO DEVELOPED ROLLS")
                            .pocketFont(8, weight: .bold, design: .monospaced)
                            .tracking(2)
                            .foregroundStyle(CameraTheme.muted)
                        Text("Completed Pocket Rolls will stay here.")
                            .pocketFont(13)
                            .foregroundStyle(CameraTheme.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                }
                ForEach(store.archives) { archive in
                    archiveCard(archive)
                }
            }
            .padding(16)
        }
        .background(CameraTheme.background)
        .tint(CameraTheme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { PocketDismissBar() }
        .pocketSwipeBack()
        .fullScreenCover(item: $imageExport) { export in
            RollImageExportPreview(export: export)
        }
        .fullScreenCover(item: $openArchive) { opened in
            PocketRollView(store: store, archive: opened.archive)
        }
        .overlay {
            PocketSheet("ARCHIVE", isPresented: Binding(
                get: { actionArchive != nil },
                set: { if !$0 { actionArchive = nil } }
            )) {
                if let archive = actionArchive {
                    ExportPresetRows(isExporting: isExporting) { preset in
                        actionArchive = nil
                        exportArchive(archive, format: preset)
                    }
                    PocketSheetDivider()
                    PocketActionRow(title: "Delete roll", symbol: "trash", destructive: true) {
                        deleteArchive = archive
                        actionArchive = nil
                    }
                }
            }
        }
        .overlay {
            PocketSheet("DELETE THIS ROLL?", isPresented: Binding(
                get: { deleteArchive != nil },
                set: { if !$0 { deleteArchive = nil } }
            )) {
                Text("This permanently removes every photo in this archived roll from Pocket CCD.")
                    .pocketFont(11)
                    .foregroundStyle(CameraTheme.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                PocketSheetDivider()
                PocketActionRow(title: "Delete roll", symbol: "trash", destructive: true) {
                    if let deleteArchive { store.deleteArchive(deleteArchive) }
                    deleteArchive = nil
                }
            }
        }
        .overlay {
            if isExporting {
                ProgressView()
                    .tint(CameraTheme.accent)
                    .padding(18)
                    .background(CameraTheme.panel)
                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
            }
        }
        .overlay {
            PocketAlert(
                title: "POCKETCCD",
                message: exportError ?? "",
                isPresented: Binding(
                    get: { exportError != nil },
                    set: { if !$0 { exportError = nil } }
                )
            )
        }
    }

    private func exportArchive(_ archive: RollArchive, format: ExportPreset) {
        guard !isExporting else { return }
        isExporting = true
        let urls = archive.entries.map { store.thumbnailURL(for: $0) }
        let entries = archive.entries
        Task {
            // Up to 24 thumbnail decodes plus the sheet render used to run on
            // the main thread and froze the archive page.
            let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let images = urls.compactMap { RollThumbnailCache.thumbnail(url: $0, maxPixel: 1200) }
                return ContactSheetRenderer.render(images: images, entries: entries, format: format)
            }.value
            isExporting = false
            if let image {
                imageExport = RollImageExport(
                    image: image,
                    title: String(localized: format.title)
                )
            } else {
                exportError = String(localized: "Couldn’t create this contact sheet. Try again.")
            }
        }
    }

    private func archiveCard(_ archive: RollArchive) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if let title = archive.title {
                        Text(title)
                            .pocketFont(16, weight: .bold)
                            .foregroundStyle(CameraTheme.ink)
                    }
                    Text(archive.createdAt, format: .dateTime.year().month().day())
                        .pocketFont(11)
                        .foregroundStyle(CameraTheme.muted)
                    Text(verbatim: "\(archive.entries.count) EXPOSURES")
                        .pocketFont(8, weight: .bold, design: .monospaced)
                        .tracking(1.2)
                        .foregroundStyle(CameraTheme.muted)
                    if let note = archive.note {
                        Text(note)
                            .pocketFont(11)
                            .foregroundStyle(CameraTheme.muted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { actionArchive = archive }
                } label: {
                    Image(systemName: "ellipsis")
                        .pocketFont(13, weight: .semibold)
                        .foregroundStyle(CameraTheme.muted)
                        .frame(width: CameraTheme.hit, height: CameraTheme.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(archive.entries.prefix(8)) { entry in
                        RollThumbnailView(url: store.thumbnailURL(for: entry), maxPixel: 240)
                            .frame(width: 64, height: 50)
                            .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .background(CameraTheme.cameraWell)
        .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !archive.entries.isEmpty else { return }
            openArchive = OpenArchive(archive: archive)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Opens this archived roll"))
    }
}

/// Reopening a developed roll is read-only: it reuses the same pager as the
/// current roll, so archived frames keep swipe, save and share for free.
private struct OpenArchive: Identifiable {
    let archive: RollArchive
    var id: UUID { archive.id }
}

struct SensorPassportView: View {
    let look: CCDLook
    let identity: SensorIdentity

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(look.rawValue)
                        .pocketFont(26, weight: .bold)
                        .foregroundStyle(CameraTheme.ink)
                    Text(identity.serial.uppercased())
                        .pocketFont(10, weight: .bold, design: .monospaced)
                        .tracking(1.4)
                        .foregroundStyle(CameraTheme.accent)
                    Text(look.summary)
                        .pocketFont(12.5)
                        .foregroundStyle(CameraTheme.muted)
                }

                PocketGroup("SENSOR CHARACTER") {
                    passportRow("Fixed pattern", value: "0x\(String(identity.seed, radix: 16).uppercased().suffix(8))")
                    divider
                    passportRow("Shadow response", value: shadowResponse)
                    divider
                    passportRow("Highlight behavior", value: highlightResponse)
                    divider
                    passportRow("Banding tendency", value: bandingResponse)
                    divider
                    passportRow("JPEG character", value: jpegResponse)
                    divider
                    passportRow("White balance", value: whiteBalanceResponse)
                }

                PocketFootnote("This passport is not decorative metadata: its stable seed and camera response are used by both the live preview and exported photo.")
            }
            .padding(16)
        }
        .background(CameraTheme.background)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { PocketDismissBar() }
        .pocketSwipeBack()
    }

    private var divider: some View {
        Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
    }

    private func passportRow(_ title: LocalizedStringResource, value: String) -> some View {
        PocketLabeledRow(title: title, value: value.uppercased())
    }

    private var shadowResponse: String {
        switch look { case .amber: "Warm amber drift"; case .party: "Neutral flash falloff"; case .chrome: "Cool cyan crunch"; case .night: "Green-magenta noise"
        case .negative: "Teal base shadow lift"
        case .mono: String(localized: "Neutral silver shadows")
        }
    }
    private var highlightResponse: String {
        switch look { case .amber: "Soft warm bloom"; case .party: "Clipped white core"; case .chrome: "Fast channel clip"; case .night: "Soft clip, glowing halos"
        case .negative: "Creamy highlight shoulder"
        case .mono: String(localized: "Soft silver shoulder")
        }
    }
    private var bandingResponse: String {
        switch look { case .amber: "Low"; case .party: "Medium"; case .chrome: "Medium"; case .night: "Visible at night"
        case .negative: "Fine film grain"
        case .mono: String(localized: "Fine neutral grain")
        }
    }
    private var jpegResponse: String {
        switch look { case .amber: "Soft family compact"; case .party: "Direct-flash party compact"; case .chrome: "Crisp budget CCD"; case .night: "Noisy night compact"
        case .negative: "Negative film stock compact"
        case .mono: String(localized: "Silver monochrome compact")
        }
    }
    private var whiteBalanceResponse: String {
        switch look { case .amber: "Warm skin bias"; case .party: "Neutral flash bias"; case .chrome: "Cool daylight bias"; case .night: "Green shadow bias"
        case .negative: "Subtle cyan-teal bias"
        case .mono: String(localized: "Neutral monochrome")
        }
    }
}


private final class ZoomableScrollView: UIScrollView {
    weak var imageView: UIImageView?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let imageView, zoomScale <= minimumZoomScale + 0.01 else { return }
        if imageView.frame != bounds {
            imageView.frame = bounds
            contentSize = bounds.size
        }
    }
}

/// Photo viewer with real pinch-zoom: anchored double-tap, panning while zoomed,
/// and rubber-banding back to fit. Backed by UIScrollView so the image fills the
/// screen instead of growing past clipped bounds.
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    var maximumZoom: CGFloat = 6
    var shouldResetZoom: Bool = false
    var onZoomIn: (() -> Void)? = nil

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = ZoomableScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = maximumZoom
        scroll.bouncesZoom = true
        scroll.alwaysBounceHorizontal = false
        scroll.alwaysBounceVertical = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        scroll.addSubview(imageView)
        scroll.imageView = imageView
        context.coordinator.imageView = imageView
        context.coordinator.onZoomIn = onZoomIn

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.onZoomIn = onZoomIn
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
        if shouldResetZoom, scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
            scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
            context.coordinator.didNotifyZoomIn = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var onZoomIn: (() -> Void)?
        var didNotifyZoomIn = false

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if scrollView.zoomScale > 1.5, !didNotifyZoomIn {
                didNotifyZoomIn = true
                onZoomIn?()
            } else if scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 {
                didNotifyZoomIn = false
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView, let imageView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
                return
            }
            let point = gesture.location(in: imageView)
            let side = 1 / 3.0
            let rect = CGRect(
                x: point.x - imageView.bounds.width * side / 2,
                y: point.y - imageView.bounds.height * side / 2,
                width: imageView.bounds.width * side,
                height: imageView.bounds.height * side
            )
            scroll.zoom(to: rect, animated: true)
        }
    }
}

/// Dedicated pre-decoded cache for full-screen roll preview pages so swiping
/// left/right never blocks the main thread on JPEG decompression or re-decodes
/// recently viewed neighbours.
private enum RollPreviewImageCache {
    static let maxPixel: CGFloat = 1600

    private final class Storage: @unchecked Sendable {
        let cache: NSCache<NSString, UIImage>
        private var memoryObserver: NSObjectProtocol?

        init() {
            let cache = NSCache<NSString, UIImage>()
            cache.countLimit = 12
            cache.totalCostLimit = 96 * 1024 * 1024
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

    static func cached(url: URL) -> UIImage? {
        storage.cache.object(forKey: url.lastPathComponent as NSString)
    }

    static func decode(url: URL) -> UIImage? {
        let key = url.lastPathComponent as NSString
        if let hit = storage.cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let raw = UIImage(cgImage: cg)
        let prepared = raw.preparingForDisplay() ?? raw
        let cost = cg.bytesPerRow * cg.height
        storage.cache.setObject(prepared, forKey: key, cost: cost)
        return prepared
    }
}

/// Full-screen view of one frame in the roll. A paged TabView gives the swipe
/// its own tracking and settle animation instead of swapping the image on a
/// gesture end.
private struct RollPhotoPreview: View {
    let store: RollStore
    let archiveID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var items: [RollEntry]
    @State private var selectedID: UUID
    @State private var sharePayload: RollSharePayload?
    @State private var note: String?
    @State private var noteTask: Task<Void, Never>?
    @State private var prefetchTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var savedIDs: Set<UUID> = []
    @State private var showDeleteConfirm = false

    init(entries: [RollEntry], start: RollEntry, store: RollStore, archiveID: UUID? = nil) {
        self.store = store
        self.archiveID = archiveID
        _items = State(initialValue: entries)
        _selectedID = State(initialValue: start.id)
    }

    private var currentIndex: Int {
        items.firstIndex(where: { $0.id == selectedID }) ?? 0
    }

    private var currentEntry: RollEntry? {
        guard !items.isEmpty else { return nil }
        return items[currentIndex]
    }

    var body: some View {
        ZStack {
            CameraTheme.background.ignoresSafeArea()
            if let entry = currentEntry {
                let isSaved = savedIDs.contains(entry.id)
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .pocketFont(13, weight: .semibold)
                                .foregroundStyle(CameraTheme.ink)
                                .frame(width: CameraTheme.control, height: CameraTheme.control)
                                .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                                .frame(width: CameraTheme.hit, height: CameraTheme.hit)
                                .contentShape(Rectangle())
                        }
                        Spacer(minLength: 4)
                        VStack(spacing: 2) {
                            Text(verbatim: "\(entry.cameraRawValue)  \(min(currentIndex + 1, items.count))/\(items.count)")
                                .foregroundStyle(CameraTheme.ink)
                            Text(entry.createdAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                                .foregroundStyle(CameraTheme.muted)
                        }
                        .pocketFont(9, weight: .bold, design: .monospaced)
                        .tracking(1)
                        Spacer(minLength: 4)
                        Color.clear.frame(width: CameraTheme.hit, height: CameraTheme.hit)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 54)
                    .background(CameraTheme.panel)
                    .overlay(alignment: .bottom) { Rectangle().fill(CameraTheme.line).frame(height: 0.5) }

                    TabView(selection: $selectedID) {
                        ForEach(items) { item in
                            RollPreviewPage(
                                url: store.thumbnailURL(for: item),
                                isCurrent: item.id == selectedID
                            )
                            .equatable()
                            .tag(item.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            Button { save(entry) } label: {
                                HStack(spacing: 6) {
                                    if isSaving {
                                        ProgressView().controlSize(.mini).tint(.black)
                                    } else {
                                        Image(systemName: isSaved ? "checkmark" : "square.and.arrow.down")
                                            .pocketFont(12, weight: .bold)
                                    }
                                    Text(isSaved ? "SAVED TO PHOTOS" : "SAVE TO PHOTOS")
                                        .pocketFont(9, weight: .bold, design: .monospaced)
                                        .tracking(1.4)
                                }
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .background(CameraTheme.accent)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving)

                            Button { share(entry) } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .pocketFont(14, weight: .semibold)
                                    .foregroundStyle(CameraTheme.ink)
                                    .frame(width: 46, height: 46)
                                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Share photo")

                            Button {
                                withAnimation(.easeOut(duration: 0.16)) { showDeleteConfirm = true }
                            } label: {
                                Image(systemName: "trash")
                                    .pocketFont(14, weight: .semibold)
                                    .foregroundStyle(CameraTheme.record)
                                    .frame(width: 46, height: 46)
                                    .overlay { Rectangle().stroke(CameraTheme.record.opacity(0.45), lineWidth: 1) }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete photo")
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 14)
                    }
                    .background(CameraTheme.panel)
                    .overlay(alignment: .top) { Rectangle().fill(CameraTheme.line).frame(height: 0.5) }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { prefetchNeighbours(around: currentIndex) }
        .onChange(of: selectedID) { _, _ in prefetchNeighbours(around: currentIndex) }
        .onDisappear { prefetchTask?.cancel() }
        .sheet(item: $sharePayload) { payload in
            ActivityShareSheet(items: payload.items, onComplete: { _ in sharePayload = nil })
        }
        .overlay {
            PocketSheet("DELETE PHOTO?", isPresented: $showDeleteConfirm) {
                Text("This removes the photo from the roll on this iPhone.")
                    .pocketFont(11)
                    .foregroundStyle(CameraTheme.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                PocketSheetDivider()
                PocketActionRow(title: "Delete photo", symbol: "trash", destructive: true) {
                    showDeleteConfirm = false
                    deleteCurrent()
                }
                PocketSheetDivider()
                PocketActionRow(title: "Cancel", symbol: "xmark") {
                    showDeleteConfirm = false
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let note {
                Text(note)
                    .pocketFont(10, weight: .bold, design: .monospaced)
                    .tracking(0.8)
                    .foregroundStyle(CameraTheme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(CameraTheme.panel)
                    .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
                    .padding(.bottom, 84)
            }
        }
    }

    private func fullImage(for entry: RollEntry) -> UIImage? {
        UIImage(contentsOfFile: store.thumbnailURL(for: entry).path)
    }

    private func share(_ entry: RollEntry) {
        guard let image = fullImage(for: entry) else { return }
        sharePayload = RollSharePayload(items: [image])
    }

    private func save(_ entry: RollEntry) {
        guard !isSaving, let image = fullImage(for: entry) else { return }
        isSaving = true
        Task { @MainActor in
            let saved = await CameraController.saveToLibrary(image, capturedAt: entry.createdAt,
                                                             metadata: entry.metadata)
            isSaving = false
            if saved { savedIDs.insert(entry.id) }
            showNote(saved ? String(localized: "Saved to Photos") : String(localized: "Couldn’t save"))
        }
    }

    private func prefetchNeighbours(around center: Int) {
        prefetchTask?.cancel()
        let offsets = [0, 1, -1, 2, -2]
        let urls: [URL] = offsets.compactMap { delta in
            let idx = center + delta
            guard items.indices.contains(idx) else { return nil }
            let url = store.thumbnailURL(for: items[idx])
            return RollPreviewImageCache.cached(url: url) == nil ? url : nil
        }
        guard !urls.isEmpty else { return }
        prefetchTask = Task.detached(priority: .userInitiated) {
            for url in urls {
                if Task.isCancelled { break }
                _ = RollPreviewImageCache.decode(url: url)
            }
        }
    }

    private func deleteCurrent() {
        guard let entry = currentEntry else { return }
        let oldIndex = currentIndex
        store.deleteEntry(entry, in: archiveID)
        items.removeAll { $0.id == entry.id }
        if items.isEmpty {
            dismiss()
        } else {
            let nextIndex = min(oldIndex, items.count - 1)
            selectedID = items[nextIndex].id
            showNote(String(localized: "Photo deleted"))
        }
    }

    private func showNote(_ message: String) {
        noteTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) { note = message }
        noteTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { note = nil }
        }
    }
}

/// One page of the roll preview. Downsampled on load: a full 12 MP decode is
/// ~48 MB per page and a paged view keeps neighbours alive.
private struct RollPreviewPage: View, Equatable {
    let url: URL
    let isCurrent: Bool
    @State private var image: UIImage?
    @State private var isPreviewReady = false
    @State private var isOriginalLoaded = false
    @State private var fullLoadTask: Task<Void, Never>?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.isCurrent == rhs.isCurrent
    }

    init(url: URL, isCurrent: Bool) {
        self.url = url
        self.isCurrent = isCurrent
        if let full = RollPreviewImageCache.cached(url: url) {
            _image = State(initialValue: full)
            _isPreviewReady = State(initialValue: true)
        } else if let thumb = RollThumbnailCache.cached(url: url, maxPixel: 720) {
            _image = State(initialValue: thumb)
            _isPreviewReady = State(initialValue: false)
        } else {
            _image = State(initialValue: nil)
            _isPreviewReady = State(initialValue: false)
        }
    }

    var body: some View {
        Group {
            if let image {
                ZoomableImage(
                    image: image,
                    maximumZoom: 5,
                    shouldResetZoom: !isCurrent,
                    onZoomIn: loadOriginalForZoom
                )
                .padding(10)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { fullLoadTask?.cancel() }
        .task(id: url) {
            if isPreviewReady { return }
            if let cached = RollPreviewImageCache.cached(url: url) {
                image = cached
                isPreviewReady = true
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                RollPreviewImageCache.decode(url: url)
            }.value
            if let decoded, !isOriginalLoaded {
                image = decoded
                isPreviewReady = true
            }
        }
    }

    /// Upgrade from the 1600 px swipe-optimized image to full resolution only
    /// when the user actually zooms in past 1.5x, keeping 1x swiping instant.
    private func loadOriginalForZoom() {
        guard !isOriginalLoaded, fullLoadTask == nil else { return }
        let targetURL = url
        fullLoadTask = Task {
            let full = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let raw = UIImage(contentsOfFile: targetURL.path) else { return nil }
                return raw.preparingForDisplay() ?? raw
            }.value
            guard !Task.isCancelled else { return }
            if let full {
                image = full
                isOriginalLoaded = true
                isPreviewReady = true
            }
            fullLoadTask = nil
        }
    }
}
