import Observation
import StoreKit
import SwiftUI

enum PocketProduct {
    static let fullUnlock = "work.doublenine.pocketccd.full"
}

enum ProductAccess {
    static func canUse(_ look: CCDLook, isFullUnlocked: Bool) -> Bool {
        look.isFree || isFullUnlocked
    }
}

/// What StoreKit could tell us about the entitlement on this check.
enum EntitlementEvidence: Equatable {
    /// A verified, unrevoked transaction for the product.
    case active
    /// The product exists in purchase history but was refunded or revoked.
    case revoked
    /// No record of the product at all.
    case none
}

/// Whether the App Store answered at all. An offline or failing check proves
/// nothing about a purchase, so it must never overwrite a paying user's cached
/// unlock — while an explicit revocation always wins.
enum StoreAvailability: Equatable {
    case reachable
    case unreachable
}

enum EntitlementPolicy {
    static func isUnlocked(evidence: EntitlementEvidence, availability: StoreAvailability, cached: Bool) -> Bool {
        switch evidence {
        case .active: true
        case .revoked: false
        // "No record" only means "never bought" when the store actually
        // answered; otherwise the last known state stands.
        case .none: availability == .reachable ? false : cached
        }
    }
}

enum ProductEvent: String, CaseIterable {
    case onboardingCompleted
    case captureCompleted
    case resultShared
    case paywallViewed
    case purchaseCompleted
}

/// Privacy-first product metrics. Counts stay in this app's UserDefaults and are
/// never transmitted or linked to an identity.
enum ProductMetrics {
    private static let prefix = "productMetric."

    static func record(_ event: ProductEvent) {
        let key = prefix + event.rawValue
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }

    static func count(_ event: ProductEvent) -> Int {
        UserDefaults.standard.integer(forKey: prefix + event.rawValue)
    }
}

@MainActor
@Observable
final class PurchaseStore {
    static let shared = PurchaseStore()

    private(set) var fullProduct: Product?
    private(set) var isFullUnlocked = false
    private(set) var isLoading = false
    private(set) var isRestoring = false
    private(set) var isPurchasing = false
    /// `nil` until the store has answered once. A failed product request proves
    /// nothing about entitlements, so it must not be read as "no purchase".
    private(set) var storeReachable: Bool?
    private(set) var purchaseMessage: String?
    private var updatesTask: Task<Void, Never>?
    private static let unlockCacheKey = "pocketCCD.lastKnownUnlock"

    private init() {
        // Avoid a locked-looking launch frame for a paying user while StoreKit
        // verifies the entitlement in the background.
        isFullUnlocked = UserDefaults.standard.bool(forKey: Self.unlockCacheKey)
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await self?.handle(transaction)
                await transaction.finish()
            }
        }
        Task { [weak self] in
            // Entitlements first: a slow or failing product request must never
            // keep a paying user locked out (or show the paywall again).
            await self?.refreshEntitlements()
            await self?.loadProduct()
            // Once the store has answered, the entitlement check becomes
            // authoritative — this is where a refund gets caught.
            await self?.refreshEntitlements()
        }
    }

    /// A revocation can arrive at any time as a transaction update. Revoke
    /// immediately instead of waiting for the next entitlement sweep.
    private func handle(_ transaction: StoreKit.Transaction) async {
        if transaction.productID == PocketProduct.fullUnlock, transaction.revocationDate != nil {
            isFullUnlocked = false
            UserDefaults.standard.set(false, forKey: Self.unlockCacheKey)
        }
        await refreshEntitlements()
    }

    func loadProduct() async {
        guard fullProduct == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let products = try await Product.products(for: [PocketProduct.fullUnlock])
            fullProduct = products.first
            storeReachable = true
            if fullProduct == nil {
                // Reachable but empty: the product is not configured in App
                // Store Connect yet. A different problem from being offline.
                purchaseMessage = String(localized: "Pocket CCD Full isn't available in the store yet.")
            }
        } catch {
            storeReachable = false
            purchaseMessage = String(
                localized: "The store is temporarily unavailable. Check your connection and try again."
            )
        }
    }

    func refreshEntitlements() async {
        let evidence = await Self.entitlementEvidence()
        // "The store answered" means the product request succeeded *and*
        // returned a product. A reachable store with an empty product list
        // (configuration lag, account switch) proves nothing about ownership.
        let availability: StoreAvailability = (storeReachable == true && fullProduct != nil)
            ? .reachable : .unreachable
        let cached = UserDefaults.standard.bool(forKey: Self.unlockCacheKey)
        let unlocked = EntitlementPolicy.isUnlocked(
            evidence: evidence,
            availability: availability,
            cached: cached
        )
        isFullUnlocked = unlocked
        // Only an explicit revocation, or a verified active purchase, may
        // rewrite the cache. A transient empty `currentEntitlements` used to
        // lock paying users out and destroy their last known state.
        if unlocked || evidence == .revoked {
            UserDefaults.standard.set(unlocked, forKey: Self.unlockCacheKey)
        }
    }

    private static func entitlementEvidence() async -> EntitlementEvidence {
        var sawRevoked = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == PocketProduct.fullUnlock else { continue }
            if transaction.revocationDate == nil { return .active }
            sawRevoked = true
        }
        if sawRevoked { return .revoked }
        // `currentEntitlements` only lists active purchases, so a refunded one
        // has to be looked up in the full transaction history.
        for await result in StoreKit.Transaction.all {
            guard case .verified(let transaction) = result,
                  transaction.productID == PocketProduct.fullUnlock else { continue }
            if transaction.revocationDate != nil { return .revoked }
        }
        return .none
    }

    func purchaseFullUnlock() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        if fullProduct == nil { await loadProduct() }
        guard let fullProduct else {
            if storeReachable != true {
                // The failure came from an unreachable store, so the message is
                // already set by loadProduct; don't claim the product is missing.
                return
            }
            purchaseMessage = String(localized: "Pocket CCD Full isn't available in the store yet.")
            return
        }
        do {
            switch try await fullProduct.purchase() {
            case .success(.verified(let transaction)):
                isFullUnlocked = true
                UserDefaults.standard.set(true, forKey: Self.unlockCacheKey)
                ProductMetrics.record(.purchaseCompleted)
                await transaction.finish()
                purchaseMessage = String(localized: "Pocket CCD Full is unlocked.")
            case .success(.unverified):
                purchaseMessage = String(localized: "The purchase couldn't be verified.")
            case .pending:
                purchaseMessage = String(localized: "The purchase is waiting for approval.")
            case .userCancelled:
                break
            @unknown default:
                purchaseMessage = String(localized: "The purchase couldn't be completed.")
            }
        } catch {
            // StoreKit's raw error is usually English system copy and often
            // says nothing actionable; keep the user-facing message localized.
            purchaseMessage = String(localized: "The purchase couldn't be completed. Check your connection and try again.")
        }
    }

    func restorePurchases() async {
        // AppStore.sync() is expensive and shows a system prompt; a double tap
        // used to start two overlapping syncs.
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            await loadProduct()
            await refreshEntitlements()
            purchaseMessage = isFullUnlocked
                ? String(localized: "Your purchase was restored.")
                : String(localized: "No previous Pocket CCD Full purchase was found.")
        } catch {
            purchaseMessage = String(localized: "Couldn't restore purchases. Check your connection and try again.")
        }
    }

    func dismissMessage() {
        purchaseMessage = nil
    }

    func canUse(_ look: CCDLook) -> Bool {
        ProductAccess.canUse(look, isFullUnlocked: isFullUnlocked)
    }
}

struct PocketOnboardingView: View {
    let completion: () -> Void
    @State private var page = 0

    private let pages: [(LocalizedStringKey, LocalizedStringKey)] = [
        ("Pick a camera, not a filter", "A7 is warm, C1 is crisp, and N2 owns the night. Each keeps the same character from preview to photo."),
        ("One shutter, five ways to remember", "Take one photo, start Flash Party, make a flash pair, capture a three-beat sequence, or save a two-second Pocket Moment."),
        ("Your photos become a Pocket Roll", "Every capture joins a 24-frame roll. Add a note, make a contact sheet, or turn the day into a short memory film.")
    ]

    var body: some View {
        ZStack {
            CameraTheme.background.ignoresSafeArea()
            VStack(spacing: 26) {
                HStack {
                    Text("POCKET CCD")
                        .pocketFont(9, weight: .bold, design: .monospaced)
                        .tracking(2.4)
                        .foregroundStyle(CameraTheme.ink)
                    Spacer()
                    Button {
                        ProductMetrics.record(.onboardingCompleted)
                        completion()
                    } label: {
                        Text("SKIP")
                            .pocketFont(8.5, weight: .bold, design: .monospaced)
                            .tracking(1.2)
                            .foregroundStyle(CameraTheme.muted)
                            .frame(width: CameraTheme.hit, height: CameraTheme.hit)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)

                Spacer(minLength: 4)
                OnboardingArtwork(page: page)
                    .frame(height: 250)
                VStack(alignment: .leading, spacing: 10) {
                    Text(pages[page].0)
                        .pocketFont(30, weight: .bold)
                        .foregroundStyle(CameraTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(pages[page].1)
                        .pocketFont(13)
                        .foregroundStyle(CameraTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { index in
                        Rectangle()
                            .fill(index == page ? CameraTheme.accent : CameraTheme.line)
                            .frame(width: index == page ? 26 : 8, height: 2)
                    }
                    Spacer(minLength: 0)
                }

                PocketButton(title: page == pages.count - 1 ? "START SHOOTING" : "CONTINUE", filled: true) {
                    if page == pages.count - 1 {
                        ProductMetrics.record(.onboardingCompleted)
                        completion()
                    } else {
                        withAnimation(.snappy) { page += 1 }
                    }
                }
                .padding(.bottom, 30)
            }
            .padding(.horizontal, 22)
            // Duo / iPad width: a 1540 pt text column is unreadable. Cap the
            // onboarding copy and keep it centred.
            .frame(maxWidth: 640)
        }
        .preferredColorScheme(.dark)
    }
}

private struct OnboardingArtwork: View {
    let page: Int
    private let amber = Color(red: 0.94, green: 0.68, blue: 0.24)

    var body: some View {
        ZStack {
            Rectangle()
                .fill(CameraTheme.panel)
                .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
            switch page {
            case 0: cameraDeck
            case 1: captureBeats
            default: pocketRoll
            }
        }
        .animation(.easeInOut(duration: 0.25), value: page)
        .accessibilityHidden(true)
    }

    private var cameraDeck: some View {
        // Free bodies sit in the middle; paid bodies fan out symmetrically, so a
        // newly added body shows up here without touching this view.
        let free = CCDLook.allCases.filter(\.isFree)
        let paid = CCDLook.allCases.filter { !$0.isFree }
        let split = paid.count / 2
        let ordered = Array(paid.prefix(split)) + free + Array(paid.dropFirst(split))
        let centre = Double(ordered.count - 1) / 2
        return HStack(spacing: -22) {
            ForEach(Array(ordered.enumerated()), id: \.element) { index, look in
                cameraCard(
                    name: look.shortName,
                    color: CameraTheme.color(for: look.accent),
                    rotation: (Double(index) - centre) * 3.4
                )
                .zIndex(look.isFree ? 1 : 0)
            }
        }
        .scaleEffect(0.82)
    }

    private func cameraCard(name: String, color: Color, rotation: Double) -> some View {
        VStack(spacing: 18) {
            HStack {
                Text("POCKET").pocketFont(8, weight: .bold, design: .monospaced)
                Spacer()
                Circle().fill(.red).frame(width: 5, height: 5)
            }
            ZStack {
                Circle().stroke(.white.opacity(0.22), lineWidth: 8)
                Circle().fill(.black).padding(9)
                Circle().stroke(color, lineWidth: 3).padding(17)
            }
            Text(name).font(.headline.monospaced().weight(.black)).foregroundStyle(color)
        }
        .padding(12)
        .frame(width: 96, height: 158)
        .background(CameraTheme.cameraWell)
        .overlay { Rectangle().stroke(CameraTheme.line, lineWidth: 1) }
        .rotationEffect(.degrees(rotation))
    }

    private var captureBeats: some View {
        HStack(spacing: 12) {
            ForEach(0..<3) { index in
                Rectangle()
                    .fill(index == 1 ? amber : CameraTheme.line)
                    .frame(width: 72, height: 112)
                    .overlay {
                        Image(systemName: index == 1 ? "bolt.fill" : "person.2.fill")
                            .font(.title2)
                            .foregroundStyle(index == 1 ? .black : .white.opacity(0.65))
                    }
                    .offset(y: index == 1 ? -12 : 8)
            }
        }
        .overlay(alignment: .bottom) {
            Text("AMBIENT   FLASH   REACTION")
                .pocketFont(9, weight: .bold, design: .monospaced)
                .tracking(1)
                .foregroundStyle(.secondary)
                .offset(y: 34)
        }
    }

    private var pocketRoll: some View {
        VStack(spacing: 12) {
            HStack {
                Text("POCKET ROLL 01").font(.caption.monospaced().bold())
                Spacer()
                Text("06 / 24").font(.caption.monospacedDigit()).foregroundStyle(amber)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                ForEach(0..<6) { index in
                    ZStack {
                        Rectangle().fill(index == 4 ? amber.opacity(0.85) : .white.opacity(0.13 + Double(index) * 0.025))
                        Image(systemName: index == 4 ? "sparkles" : "photo")
                            .foregroundStyle(index == 4 ? .black : .white.opacity(0.45))
                    }
                    .aspectRatio(1.25, contentMode: .fit)
                }
            }
        }
        .padding(22)
    }
}

struct UpgradeView: View {
    @Bindable var store: PurchaseStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CameraTheme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        LookPreviewDeck(isFullUnlocked: store.isFullUnlocked)
                            .frame(maxWidth: .infinity)

                        PocketPageTitle(
                            title: "Pocket CCD Full",
                            subtitle: "A7 and A8 stay free forever. One purchase unlocks every other camera body."
                        )

                        PocketGroup("INCLUDED") {
                            PocketLabeledRow(title: "Every other camera body", symbol: "camera.filters")
                            Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                            PocketLabeledRow(title: "Including bodies added in future updates", symbol: "sparkles")
                            Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                            PocketLabeledRow(title: "One purchase, no subscription", symbol: "infinity")
                        }

                        PocketGroup("ALWAYS FREE") {
                            ForEach(Array(CCDLook.allCases.filter(\.isFree).enumerated()), id: \.element) { index, look in
                                if index > 0 {
                                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                                }
                                PocketLabeledRow(
                                    title: LocalizedStringResource("Pocket \(look.shortName)"),
                                    detail: look.summary,
                                    symbol: "camera"
                                )
                            }
                            Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                            PocketLabeledRow(title: "Pocket Roll, notes and sharing", symbol: "film.stack")
                        }

                        if store.isFullUnlocked {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(CameraTheme.accent)
                                Text("Pocket CCD Full unlocked")
                                    .pocketFont(10, weight: .bold, design: .monospaced)
                                    .tracking(1.2)
                                    .foregroundStyle(CameraTheme.ink)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 48)
                            .overlay { Rectangle().stroke(CameraTheme.accent, lineWidth: 1) }
                        } else {
                            VStack(spacing: 10) {
                                PocketButton(title: purchaseTitle, filled: true) {
                                    Task { await store.purchaseFullUnlock() }
                                }
                                .disabled(store.isLoading || store.isPurchasing)
                                Button {
                                    Task { await store.restorePurchases() }
                                } label: {
                                    HStack(spacing: 6) {
                                        if store.isRestoring {
                                            ProgressView()
                                                .controlSize(.mini)
                                                .tint(CameraTheme.muted)
                                        }
                                        Text(store.isRestoring
                                             ? String(localized: "RESTORING…")
                                             : String(localized: "RESTORE PURCHASES"))
                                            .pocketFont(8.5, weight: .bold, design: .monospaced)
                                            .tracking(1.4)
                                            .foregroundStyle(CameraTheme.muted)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(store.isRestoring || store.isLoading)
                            }
                        }

                        PocketFootnote("Payment is charged to your Apple Account. This non-consumable purchase does not expire.")
                    }
                    .padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) { PocketDismissBar(label: "DONE") }
            .pocketSwipeBack()
        }
        .task {
            ProductMetrics.record(.paywallViewed)
            await store.loadProduct()
            await store.refreshEntitlements()
        }
        .overlay {
            PocketAlert(
                title: "POCKETCCD",
                message: store.purchaseMessage ?? "",
                isPresented: Binding(
                    get: { store.purchaseMessage != nil },
                    set: { if !$0 { store.dismissMessage() } }
                )
            )
        }
    }

    private var purchaseTitle: String {
        if let product = store.fullProduct {
            return String(localized: "UNLOCK FOREVER · \(product.displayPrice)")
        }
        if store.isLoading { return String(localized: "CHECKING…") }
        // A failed request means "we couldn't reach the store", not "the
        // product is missing" — offer a retry instead of a dead end.
        if store.storeReachable == false { return String(localized: "TRY AGAIN") }
        return String(localized: "CHECK AVAILABILITY")
    }
}

private struct LookPreviewDeck: View {
    let isFullUnlocked: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(CCDLook.allCases) { look in
                LookPreviewCard(
                    look: look,
                    isLocked: !ProductAccess.canUse(look, isFullUnlocked: isFullUnlocked)
                ).frame(width: 82)
            }
        }
        }
        .scrollIndicators(.hidden)
        .animation(.easeOut(duration: 0.2), value: isFullUnlocked)
    }
}

private struct LookPreviewCard: View {
    let look: CCDLook
    let isLocked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Rectangle().fill(gradient)
                Rectangle().stroke(.white.opacity(0.14), lineWidth: 1)
                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        Text(verbatim: "05 11 ’26")
                            .pocketFont(6, weight: .bold, design: .monospaced)
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer(minLength: 0)
                    }
                }
                .padding(7)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .pocketFont(11, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(7)
                        .background(.black.opacity(0.35))
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipped()

            Text(look.shortName)
                .pocketFont(9, weight: .bold, design: .monospaced)
                .tracking(1)
                .foregroundStyle(isLocked ? CameraTheme.muted : CameraTheme.ink)
            Text(look.personality)
                .pocketFont(6.5, weight: .semibold, design: .monospaced)
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(CameraTheme.muted)
        }
    }

    private var gradient: LinearGradient {
        switch look {
        case .amber:
            LinearGradient(
                colors: [Color(red: 0.98, green: 0.74, blue: 0.38), Color(red: 0.34, green: 0.17, blue: 0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .party:
            // Harsh flash: a hot white core falling to black.
            LinearGradient(
                colors: [Color(red: 0.96, green: 0.95, blue: 0.92), Color(red: 0.16, green: 0.03, blue: 0.05)],
                startPoint: .top, endPoint: .bottom
            )
        case .chrome:
            LinearGradient(
                colors: [Color(red: 0.66, green: 0.84, blue: 0.96), Color(red: 0.10, green: 0.16, blue: 0.22)],
                startPoint: .top, endPoint: .bottom
            )
        case .night:
            LinearGradient(
                colors: [Color(red: 0.88, green: 0.36, blue: 0.58), Color(red: 0.06, green: 0.10, blue: 0.09)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .negative:
            LinearGradient(
                colors: [Color(red: 0.22, green: 0.78, blue: 0.72), Color(red: 0.08, green: 0.24, blue: 0.28)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .mono:
            LinearGradient(colors: [Color(white: 0.88), Color(white: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct PocketPrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PocketPageTitle(
                    title: "Privacy",
                    subtitle: "On-device by default. No account, no ad SDKs."
                )
                PocketGroup("YOUR PHOTOS") {
                    PocketLabeledRow(title: "Camera processing happens on this device", symbol: "iphone", showsChevron: false)
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    PocketLabeledRow(title: "Pocket CCD uses add-only access when saving to Photos", symbol: "photo.badge.plus")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    PocketLabeledRow(title: "Local backups stay in files you choose", symbol: "externaldrive")
                }
                PocketGroup("DATA") {
                    VStack(alignment: .leading, spacing: 10) {
                        PocketFootnote("Pocket CCD does not create an account, run advertising SDKs, or send product analytics to a server. Onboarding, capture, sharing, and purchase counters are stored only on this device.")
                        PocketFootnote("Purchases are processed by Apple. Pocket CCD reads the current entitlement only to unlock Pocket CCD Full.")
                    }
                    .padding(12)
                }
                PocketGroup("PERMISSIONS") {
                    VStack(alignment: .leading, spacing: 10) {
                        PocketFootnote("Camera is required for capture. Microphone is used only for a Pocket Moment with sound. Local Network is used only when you start paired capture.")
                        PocketFootnote("Location is written to a photo only when the Location tag switch is on.")
                    }
                    .padding(12)
                }
            }
            .padding(16)
        }
        .background(CameraTheme.background)
        .tint(CameraTheme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { PocketDismissBar() }
        .pocketSwipeBack()
    }
}

struct PocketCameraGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PocketPageTitle(
                    title: "Camera Guide",
                    subtitle: "Every body, its own character — one roll."
                )
                PocketGroup("CAMERAS") {
                    ForEach(Array(CCDLook.allCases.enumerated()), id: \.element) { index, look in
                        if index > 0 {
                            Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                        }
                        guideRow(
                            LocalizedStringResource("Pocket \(look.shortName)"),
                            LocalizedStringResource("\(String(localized: look.personality)) — \(String(localized: look.summary))"),
                            look.guideSymbol
                        )
                    }
                }
                PocketGroup("SHOOTING MODES") {
                    guideRow("Standard", "One photo with the active camera", "camera.fill")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    guideRow("Flash Party", "A short burst that recommends the best face and eyes", "bolt.fill")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    guideRow("Flash Pair", "An ambient frame and a flash frame", "rectangle.split.2x1")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    guideRow("Flash Sequence", "Ambient, flash, and reaction as a three-beat memory", "square.stack.3d.up.fill")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    guideRow("Pocket Moment", "A two-second clip with three selectable stills", "video.fill")
                }
                PocketGroup("MEMORIES") {
                    guideRow("Pocket Roll", "Collect 24 photos, notes, and an optional delayed reveal", "film.stack")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    guideRow("Contact Sheet", "Share a square or Story-ready roll summary", "square.grid.3x3")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    guideRow("Pocket Day", "Turn the current roll into a short vertical film", "play.rectangle.fill")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    guideRow("Camera Receipt", "Share camera and capture details without marking the original", "doc.text.image")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    guideRow("Digital negative", "Every shot keeps the camera's untouched file, so you can re-develop it later", "square.stack.3d.down.right")
                }
                PocketGroup("SHORTCUTS") {
                    guideRow("Tap", "Focus anywhere in the viewfinder", "viewfinder")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    guideRow("Pinch", "Zoom without leaving the viewfinder", "arrow.up.left.and.arrow.down.right")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    guideRow("Volume button", "Use a physical shutter on supported devices", "speaker.wave.2.fill")
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    guideRow("Open hand", "Start a visible timer countdown for group photos", "hand.raised.fill")
                }
            }
            .padding(16)
        }
        .background(CameraTheme.background)
        .tint(CameraTheme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { PocketDismissBar() }
        .pocketSwipeBack()
    }

    private func guideRow(_ title: LocalizedStringResource, _ detail: LocalizedStringResource, _ symbol: String) -> some View {
        PocketLabeledRow(title: title, detail: detail, symbol: symbol)
    }
}

struct PocketAboutView: View {
    @Environment(\.requestReview) private var requestReview

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "camera.aperture")
                        .pocketFont(40, weight: .light)
                        .foregroundStyle(CameraTheme.accent)
                    Text("Pocket CCD")
                        .pocketFont(26, weight: .bold)
                        .foregroundStyle(CameraTheme.ink)
                    Text("A small camera with a long memory.")
                        .pocketFont(12.5)
                        .foregroundStyle(CameraTheme.muted)
                    Text(verbatim: version)
                        .pocketFont(9, weight: .bold, design: .monospaced)
                        .tracking(1.2)
                        .foregroundStyle(CameraTheme.muted)
                }
                .padding(.vertical, 6)

                PocketGroup("CAMERAS") {
                    ForEach(Array(CCDLook.allCases.enumerated()), id: \.element) { index, look in
                        if index > 0 {
                            Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                        }
                        PocketLabeledRow(
                            title: LocalizedStringResource("Pocket \(look.shortName)"),
                            value: look.isFree ? "\(look.characterCode) · FREE" : look.characterCode
                        )
                    }
                }
                PocketGroup("LEGAL") {
                    Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                        PocketLabeledRow(title: "Terms of Use", symbol: "doc.text", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    Link(destination: URL(string: "https://pocketccd.doublenine.work/privacy.html")!) {
                        PocketLabeledRow(title: "Privacy Policy", symbol: "hand.raised", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                }
                PocketGroup("MORE") {
                    NavigationLink {
                        PocketPrivacyView()
                    } label: {
                        PocketLabeledRow(title: "Privacy", symbol: "hand.raised", showsChevron: true)
                    }
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    Button {
                        requestReview()
                    } label: {
                        PocketLabeledRow(title: "Rate Pocket CCD", symbol: "star")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(CameraTheme.background)
        .tint(CameraTheme.accent)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { PocketDismissBar() }
        .pocketSwipeBack()
    }
}
import UIKit


/// Free-space policy. The numbers are scaled to what this app writes: a
/// rendered frame is 3–6 MB, a 24-frame roll ~120 MB, and an original frame is
/// roughly four times the rendered one.
///
/// `unknown` is deliberately treated as `.ok`: a failed volume query must never
/// stop a shutter in the middle of a party.
enum StorageGuard {
    /// Below this the next roll or an original-frame burst may not fit.
    static let lowBytes: Int64 = 600_000_000
    /// Below this a write can fail mid-capture, so the shutter is blocked.
    static let criticalBytes: Int64 = 150_000_000

    enum Level: Equatable {
        case ok, low, critical
    }

    static func level(availableBytes: Int64?) -> Level {
        guard let availableBytes else { return .ok }
        if availableBytes < criticalBytes { return .critical }
        if availableBytes < lowBytes { return .low }
        return .ok
    }

    /// `volumeAvailableCapacityForImportantUsage` is the number iOS itself uses
    /// when it decides whether a write may proceed; the plain volume capacity
    /// over-reports by the purgeable margin.
    static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static func level(at url: URL) -> Level {
        level(availableBytes: availableBytes(at: url))
    }

    /// The app's own storage volume, used by callers that have no directory
    /// handle of their own.
    static var appLevel: Level {
        level(at: URL.applicationSupportDirectory)
    }
}
