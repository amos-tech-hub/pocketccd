import CoreGraphics
import CoreTransferable
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum CalibrationScene: String, CaseIterable, Codable, Identifiable {
    case daylight = "D01"
    case daylightShade = "D02"
    case backlitWindow = "D03"
    case goldenHour = "D04"
    case overcast = "D05"
    case middaySun = "D06"
    case whiteClothing = "D07"
    case foliageGreen = "D08"
    case indoorFlash = "F01"
    case closeFlash = "F02"
    case flashGroup = "F03"
    case lowCeiling = "F04"
    case tungstenRoom = "F05"
    case redWallBounce = "F06"
    case reflectiveGlass = "F07"
    case flashPortrait = "F08"
    case nightFlash = "N01"
    case nightAmbient = "N02"
    case neonSign = "N03"
    case sodiumStreet = "N04"
    case blueHour = "N05"
    case rainReflection = "N06"
    case concertHaze = "N07"
    case candleLight = "N08"
    case skinDaylight = "S01"
    case skinMixed = "S02"
    case splitLight = "P01"
    case flashDaylight = "P02"
    case screenGlow = "P03"
    case carInterior = "P04"

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .daylight: "Daylight color"
        case .daylightShade: "Daylight shade"
        case .backlitWindow: "Backlit window"
        case .goldenHour: "Golden hour"
        case .overcast: "Overcast"
        case .middaySun: "Midday sun"
        case .whiteClothing: "White clothing"
        case .foliageGreen: "Foliage green"
        case .indoorFlash: "Indoor direct flash"
        case .closeFlash: "Close-flash stress"
        case .flashGroup: "Group of three"
        case .lowCeiling: "Low ceiling"
        case .tungstenRoom: "Tungsten room"
        case .redWallBounce: "Red wall bounce"
        case .reflectiveGlass: "Reflective glass"
        case .flashPortrait: "Flash portrait"
        case .nightFlash: "Night street flash"
        case .nightAmbient: "Night available light"
        case .neonSign: "Neon sign"
        case .sodiumStreet: "Sodium street"
        case .blueHour: "Blue hour"
        case .rainReflection: "Rain reflection"
        case .concertHaze: "Concert haze"
        case .candleLight: "Candle light"
        case .skinDaylight: "Skin in daylight"
        case .skinMixed: "Skin in mixed light"
        case .splitLight: "Split light"
        case .flashDaylight: "Flash plus daylight"
        case .screenGlow: "Screen glow"
        case .carInterior: "Car interior"
        }
    }

    var instruction: LocalizedStringResource {
        switch self {
        case .daylight: "Include sky, foliage, a red object, and neutral grey."
        case .daylightShade: "Include a face, white clothing, and foliage in open shade."
        case .backlitWindow: "Frame a face against a bright window; keep it uncluttered."
        case .goldenHour: "Shoot a face and sky in low warm sun near sunset."
        case .overcast: "Include sky, a red object and neutral grey under flat cloud."
        case .middaySun: "Shoot a face and a hard shadow on pavement at noon."
        case .whiteClothing: "Include a white shirt and a face in open daylight."
        case .foliageGreen: "Include leaves, grass and a neutral grey card."
        case .indoorFlash: "Place a face 1.2 m away against a white wall and dark background."
        case .closeFlash: "Place a face or textured white object 0.55 m from the camera."
        case .flashGroup: "Place three faces 1.5 m away with flash on and a dark background."
        case .lowCeiling: "Shoot a face in a small room with flash on and a low ceiling."
        case .tungstenRoom: "Shoot a face lit by warm bulbs with flash on."
        case .redWallBounce: "Shoot a face 0.8 m from a red or orange wall with flash on."
        case .reflectiveGlass: "Include glass or a mirror and a face with flash on."
        case .flashPortrait: "Frame one face at arm's length with flash on at night."
        case .nightFlash: "Include a face, LED or sodium light, and black sky with flash on."
        case .nightAmbient: "Include a storefront, shadow texture, and point lights with flash off."
        case .neonSign: "Include a neon sign, a face and wet pavement with flash off."
        case .sodiumStreet: "Shoot a street lit by sodium lamps with a face and flash off."
        case .blueHour: "Capture skyline and a face just after sunset with flash off."
        case .rainReflection: "Include reflections on wet ground and one light source with flash off."
        case .concertHaze: "Shoot a lit stage or crowd with haze and point lights, flash off."
        case .candleLight: "Frame a face lit only by candles with flash off."
        case .skinDaylight: "Frame a face and neutral grey reference in indirect daylight."
        case .skinMixed: "Frame a face and white shirt under window light plus a warm lamp."
        case .splitLight: "Half the face in window light, half in shadow."
        case .flashDaylight: "Shoot a face outdoors with flash on to balance the sun."
        case .screenGlow: "Light a face only by a phone or monitor with flash off."
        case .carInterior: "Shoot a face inside a car at night with flash on."
        }
    }

    var suggestedLook: CCDLook {
        switch self {
        case .daylight: .amber
        case .daylightShade: .chrome
        case .backlitWindow: .amber
        case .goldenHour: .amber
        case .overcast: .chrome
        case .middaySun: .chrome
        case .whiteClothing: .amber
        case .foliageGreen: .chrome
        case .indoorFlash: .amber
        case .closeFlash: .chrome
        case .flashGroup: .amber
        case .lowCeiling: .amber
        case .tungstenRoom: .amber
        case .redWallBounce: .amber
        case .reflectiveGlass: .amber
        case .flashPortrait: .amber
        case .nightFlash: .night
        case .nightAmbient: .night
        case .neonSign: .night
        case .sodiumStreet: .night
        case .blueHour: .night
        case .rainReflection: .night
        case .concertHaze: .night
        case .candleLight: .night
        case .skinDaylight: .amber
        case .skinMixed: .amber
        case .splitLight: .chrome
        case .flashDaylight: .amber
        case .screenGlow: .night
        case .carInterior: .amber
        }
    }
}

struct CalibrationMetrics: Codable {
    let meanLuma: Double
    let meanSaturation: Double
    let redMinusBlue: Double
    let clippingRatio: Double
    let blackRatio: Double
    let sharpnessProxy: Double
}

struct CalibrationRecord: Codable, Identifiable {
    let id: UUID
    let capturedAt: Date
    let scene: CalibrationScene
    let look: String
    let lens: String
    let exposureBias: Float
    let iso: Float
    let shutterSeconds: Double
    let whiteBalanceKelvin: Float
    let metrics: CalibrationMetrics
}

@MainActor
@Observable
final class CalibrationStore {
    static let shared = CalibrationStore()

    var activeScene: CalibrationScene?
    private(set) var records: [CalibrationRecord] = []

    private let defaultsKey = "pocketCCD.calibration.records.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([CalibrationRecord].self, from: data) {
            records = decoded
        }
    }

    func count(for scene: CalibrationScene) -> Int {
        records.lazy.filter { $0.scene == scene }.count
    }

    func record(
        image: UIImage,
        look: CCDLook,
        lens: CameraLens,
        exposureBias: Float,
        iso: Float,
        shutterSeconds: Double,
        whiteBalanceKelvin: Float
    ) -> CalibrationScene? {
        guard let activeScene, let metrics = CalibrationImageAnalyzer.measure(image) else { return nil }
        records.append(CalibrationRecord(
            id: UUID(),
            capturedAt: .now,
            scene: activeScene,
            look: look.rawValue,
            lens: lens.rawValue,
            exposureBias: exposureBias,
            iso: iso,
            shutterSeconds: shutterSeconds,
            whiteBalanceKelvin: whiteBalanceKelvin,
            metrics: metrics
        ))
        persist()
        return activeScene
    }

    func clear() {
        records = []
        activeScene = nil
        persist()
    }

    var report: CalibrationReport {
        CalibrationReport(records: records)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

struct CalibrationLabView: View {
    @Bindable var store: CalibrationStore
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PocketPageTitle(
                    title: "Imaging Benchmark",
                    subtitle: "Eight scenes, three runs each, recorded on this device."
                )
                CalibrationProgressSection(store: store)
                CalibrationScenesSection(store: store)
                CalibrationExportSection(store: store, confirmClear: $confirmClear)
            }
            .padding(16)
        }
        .background(CameraTheme.background)
        .tint(CameraTheme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { PocketDismissBar() }
        .pocketSwipeBack()
        .overlay {
            PocketSheet("CLEAR RECORDS?", isPresented: $confirmClear) {
                Text("Every benchmark record on this device will be removed.")
                    .pocketFont(11)
                    .foregroundStyle(CameraTheme.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                PocketSheetDivider()
                PocketActionRow(title: "Delete records", symbol: "trash", destructive: true) {
                    confirmClear = false
                    store.clear()
                }
            }
        }
    }
}

private struct CalibrationProgressSection: View {
    let store: CalibrationStore

    var body: some View {
        PocketGroup("PROGRESS") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("COMPLETED SCENES")
                        .pocketFont(8, weight: .bold, design: .monospaced)
                        .tracking(1.2)
                        .foregroundStyle(CameraTheme.muted)
                    Spacer()
                    Text(verbatim: "\(completedCount)/\(CalibrationScene.allCases.count)")
                        .pocketFont(9, weight: .bold, design: .monospaced)
                        .tracking(1)
                        .foregroundStyle(CameraTheme.accent)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(CameraTheme.line).frame(height: 2)
                        Rectangle()
                            .fill(CameraTheme.accent)
                            .frame(width: max(2, proxy.size.width * CGFloat(completedCount) / CGFloat(CalibrationScene.allCases.count)), height: 2)
                    }
                }
                .frame(height: 2)
                PocketFootnote("Three Pocket CCD repetitions are required for each scene. Competitor references are analyzed separately during development and are never imported here.")
            }
            .padding(12)
        }
    }

    private var completedCount: Int {
        CalibrationScene.allCases.filter { store.count(for: $0) >= 3 }.count
    }
}

private struct CalibrationScenesSection: View {
    @Bindable var store: CalibrationStore

    var body: some View {
        PocketGroup("SCENES") {
            ForEach(Array(CalibrationScene.allCases.enumerated()), id: \.element.id) { index, scene in
                if index > 0 {
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                }
                Button {
                    store.activeScene = store.activeScene == scene ? nil : scene
                } label: {
                    CalibrationSceneRow(
                        scene: scene,
                        count: store.count(for: scene),
                        isActive: store.activeScene == scene
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct CalibrationSceneRow: View {
    let scene: CalibrationScene
    let count: Int
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: scene.rawValue)
                .pocketFont(9, weight: .bold, design: .monospaced)
                .foregroundStyle(isActive ? CameraTheme.accent : CameraTheme.muted)
                .frame(width: 34, height: 24)
                .overlay { Rectangle().stroke(isActive ? CameraTheme.accent : CameraTheme.line, lineWidth: 1) }
            VStack(alignment: .leading, spacing: 3) {
                Text(scene.title)
                    .pocketFont(12.5)
                    .foregroundStyle(CameraTheme.ink)
                Text(scene.instruction)
                    .pocketFont(10.5)
                    .foregroundStyle(CameraTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("TARGET \(scene.suggestedLook.shortName)")
                    .pocketFont(7.5, weight: .bold, design: .monospaced)
                    .tracking(1)
                    .foregroundStyle(CameraTheme.muted.opacity(0.8))
            }
            Spacer(minLength: 8)
            Text(count >= 3 ? String(localized: "DONE") : "\(min(count, 3))/3")
                .pocketFont(8.5, weight: .bold, design: .monospaced)
                .tracking(1)
                .foregroundStyle(count >= 3 ? CameraTheme.accent : CameraTheme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(minHeight: 54, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct CalibrationExportSection: View {
    let store: CalibrationStore
    @Binding var confirmClear: Bool

    var body: some View {
        PocketGroup("REPORT") {
            ShareLink(item: store.report, preview: SharePreview("Pocket CCD benchmark.csv")) {
                HStack(spacing: 8) {
                    Text("EXPORT CSV REPORT")
                        .pocketFont(9, weight: .bold, design: .monospaced)
                        .tracking(1.4)
                        .foregroundStyle(CameraTheme.accent)
                    Spacer(minLength: 0)
                    Image(systemName: "square.and.arrow.up")
                        .pocketFont(11, weight: .semibold)
                        .foregroundStyle(CameraTheme.accent)
                }
                .padding(.horizontal, 12)
                .frame(height: 50)
                .contentShape(Rectangle())
            }
            .disabled(store.records.isEmpty)

            Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)

            Button {
                confirmClear = true
            } label: {
                Text("CLEAR BENCHMARK RECORDS")
                    .pocketFont(9, weight: .bold, design: .monospaced)
                    .tracking(1.4)
                    .foregroundStyle(CameraTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(height: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.records.isEmpty)
        }
    }
}

struct CalibrationCaptureBadge: View {
    let scene: CalibrationScene
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("BENCHMARK \(scene.rawValue) · \(min(count + 1, 3))/3")
                .font(.caption2.monospaced().bold())
                .foregroundStyle(.orange)
            Text(scene.instruction)
                .font(.caption2)
                .lineLimit(2)
        }
        .padding(8)
        .background(.black.opacity(0.72))
        .overlay { Rectangle().stroke(CameraTheme.line.opacity(0.6), lineWidth: 1) }
        .padding(8)
        .allowsHitTesting(false)
    }
}

struct CalibrationReport: Transferable {
    let records: [CalibrationRecord]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { report in
            Data(report.csv.utf8)
        }
        .suggestedFileName("PocketCCD-benchmark.csv")
    }

    private var csv: String {
        let header = "scene,captured_at,look,lens,ev,iso,shutter_seconds,white_balance_k,mean_luma,mean_saturation,red_minus_blue,clip_ratio,black_ratio,sharpness_proxy"
        let formatter = ISO8601DateFormatter()
        let rows = records.map { record in
            [
                record.scene.rawValue,
                formatter.string(from: record.capturedAt),
                record.look,
                record.lens,
                String(format: "%.2f", record.exposureBias),
                String(format: "%.1f", record.iso),
                String(format: "%.6f", record.shutterSeconds),
                String(format: "%.0f", record.whiteBalanceKelvin),
                String(format: "%.5f", record.metrics.meanLuma),
                String(format: "%.5f", record.metrics.meanSaturation),
                String(format: "%.5f", record.metrics.redMinusBlue),
                String(format: "%.5f", record.metrics.clippingRatio),
                String(format: "%.5f", record.metrics.blackRatio),
                String(format: "%.5f", record.metrics.sharpnessProxy)
            ].map(csvEscaped).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n")
    }

    private func csvEscaped(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private enum CalibrationImageAnalyzer {
    static func measure(_ image: UIImage) -> CalibrationMetrics? {
        guard let source = image.cgImage else { return nil }
        let maximumDimension = 512
        let scale = min(1, CGFloat(maximumDimension) / CGFloat(max(source.width, source.height)))
        let width = max(1, Int(CGFloat(source.width) * scale))
        let height = max(1, Int(CGFloat(source.height) * scale))
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
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red = 0.0, green = 0.0, blue = 0.0, luma = 0.0, saturation = 0.0
        var clipped = 0, black = 0, edgeCount = 0
        var edgeDifference = 0.0
        var previousRow = [Double](repeating: 0, count: width)
        for y in 0 ..< height {
            var previousLuma = 0.0
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                let r = Double(pixels[index]) / 255
                let g = Double(pixels[index + 1]) / 255
                let b = Double(pixels[index + 2]) / 255
                let maximum = max(r, g, b)
                let minimum = min(r, g, b)
                let currentLuma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                red += r; green += g; blue += b; luma += currentLuma
                saturation += maximum == 0 ? 0 : (maximum - minimum) / maximum
                if max(pixels[index], pixels[index + 1], pixels[index + 2]) >= 250 { clipped += 1 }
                if currentLuma <= 0.04 { black += 1 }
                if x > 0 { edgeDifference += abs(currentLuma - previousLuma); edgeCount += 1 }
                if y > 0 { edgeDifference += abs(currentLuma - previousRow[x]); edgeCount += 1 }
                previousLuma = currentLuma
                previousRow[x] = currentLuma
            }
        }
        let count = Double(width * height)
        return CalibrationMetrics(
            meanLuma: luma / count,
            meanSaturation: saturation / count,
            redMinusBlue: (red - blue) / count,
            clippingRatio: Double(clipped) / count,
            blackRatio: Double(black) / count,
            sharpnessProxy: edgeDifference / Double(max(edgeCount, 1))
        )
    }
}

