import MultipeerConnectivity
import Observation
import SwiftUI

/// MultipeerConnectivity predates Swift concurrency annotations. Delegate
/// values are immutable for each callback and cross exactly one actor hop.
private final class PeerCallbackValue<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
@Observable
final class PairedCaptureService: NSObject {
    private static let serviceType = "pocketccd-shot"
    @ObservationIgnored private let localPeer: MCPeerID
    @ObservationIgnored private let session: MCSession
    @ObservationIgnored private let advertiser: MCNearbyServiceAdvertiser
    @ObservationIgnored private let browser: MCNearbyServiceBrowser
    private(set) var discoveredPeers: [MCPeerID] = []
    private(set) var connectedPeers: [MCPeerID] = []
    /// Why pairing is not moving. MultipeerConnectivity fails silently when
    /// Local Network access was denied; without this the screen just sits on
    /// "No paired camera" and looks broken.
    private(set) var pairingHint: String?
    private(set) var receivedImage: UIImage?
    private(set) var pendingInvitation: PendingInvitation?
    var onRemoteShutter: (() -> Void)?

    struct PendingInvitation {
        let peerName: String
        fileprivate let respond: (Bool, MCSession?) -> Void
    }

    /// Accepting a nearby device is a user decision, never automatic.
    func acceptPendingInvitation() {
        guard let pending = pendingInvitation else { return }
        pendingInvitation = nil
        pending.respond(true, session)
        // The inbound half can complete without the session ever reaching
        // .connected (seen on two same-model phones): if nothing is connected
        // shortly after accepting, dial back to the peer ourselves.
        acceptFallbackTask?.cancel()
        acceptFallbackTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, let self,
                  connectedPeers.isEmpty, let peer = discoveredPeers.first else { return }
            browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
        }
    }

    func declinePendingInvitation() {
        guard let pending = pendingInvitation else { return }
        pendingInvitation = nil
        pending.respond(false, nil)
    }

    override init() {
        // Two iPhones almost always share the display name "iPhone", and
        // MultipeerConnectivity cannot complete a session between peers with
        // the same name: the invitation arrives, accept does nothing. A short
        // vendor suffix keeps the names unique without asking the user to
        // rename a device.
        let suffix = String((UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString).prefix(4))
        let peer = MCPeerID(displayName: "\(UIDevice.current.name) \(suffix)")
        localPeer = peer
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .optional)
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: "pocketccd-shot")
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: "pocketccd-shot")
        super.init()
        session.delegate = self; advertiser.delegate = self; browser.delegate = self
    }
    func start() {
        pairingHint = nil
        acceptFallbackTask?.cancel()
        acceptFallbackTask = nil
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        startHintTask?.cancel()
        startHintTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, let self,
                  discoveredPeers.isEmpty, connectedPeers.isEmpty else { return }
            pairingHint = String(localized: "No nearby phone found. Check Local Network access in Settings, and keep both phones on this screen.")
        }
    }
    /// Leaves the page means leaving the pairing. Without `disconnect()` the
    /// session stayed live after dismissal: the other phone could still push a
    /// shutter press or an image into this app.
    func stop() {
        connectTimeout?.cancel()
        connectTimeout = nil
        startHintTask?.cancel()
        startHintTask = nil
        acceptFallbackTask?.cancel()
        acceptFallbackTask = nil
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        // `connectedPeers` can still be empty while the session is
        // `.connecting`; disconnect unconditionally so no handshake survives
        // the page being dismissed.
        session.disconnect()
        connectedPeers = []
        discoveredPeers = []
        receivedImage = nil
        pairingHint = nil
    }
    private var connectTimeout: Task<Void, Never>?
    private var startHintTask: Task<Void, Never>?
    private var acceptFallbackTask: Task<Void, Never>?

    func connect(to peer: MCPeerID) {
        pairingHint = String(localized: "Waiting for the other phone to accept…")
        invite(peer, attempts: 2)
    }

    /// A single invitation can be accepted on the far side and still never
    /// produce a connected session (the other phone may still run an older
    /// build). Retrying once from this side is the fallback that does not
    /// require the other phone to update.
    private func invite(_ peer: MCPeerID, attempts: Int) {
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
        connectTimeout?.cancel()
        connectTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(22)) } catch { return }
            guard !Task.isCancelled, let self, connectedPeers.isEmpty else { return }
            if attempts > 1 {
                self.invite(peer, attempts: attempts - 1)
            } else {
                self.pairingHint = String(localized: "No answer. Keep both phones on this screen and try again.")
            }
        }
    }
    func triggerRemote() {
        receivedImage = nil
        send(Data("shutter".utf8))
    }
    func send(image: UIImage) {
        guard !session.connectedPeers.isEmpty else { return }
        Task { @MainActor [weak self] in
            let jpeg = await Task.detached(priority: .utility) { [image] in
                image.pairingCopy(maxPixel: 1600).jpegData(compressionQuality: 0.82)
            }.value
            guard let self, let jpeg else { return }
            var payload = Data("image".utf8)
            payload.append(jpeg)
            send(payload)
        }
    }
    private func send(_ data: Data) {
        guard !session.connectedPeers.isEmpty else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
}

extension PairedCaptureService: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peers = PeerCallbackValue(session.connectedPeers)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.connectedPeers = peers.value
            if !peers.value.isEmpty {
                self.pairingHint = nil
                self.connectTimeout?.cancel()
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Decode the reduced peer preview before hopping to the UI actor.
        let isShutter = data == Data("shutter".utf8)
        let image = data.starts(with: Data("image".utf8))
            ? UIImage(data: data.dropFirst(5))
            : nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            if isShutter {
                receivedImage = nil
                onRemoteShutter?()
            } else if let image {
                receivedImage = image
            }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) { }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let peerName = peerID.displayName
        let response = PeerCallbackValue(invitationHandler)
        Task { @MainActor [weak self] in
            guard let self else {
                response.value(false, nil)
                return
            }
            guard pendingInvitation == nil else {
                // One request at a time; decline extras instead of stacking them.
                response.value(false, nil)
                return
            }
            pairingHint = String(localized: "Incoming pairing request. Accept it on this phone.")
            pendingInvitation = PendingInvitation(
                peerName: peerName,
                respond: response.value
            )
        }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor [weak self] in
            self?.pairingHint = String(localized: "Local Network access is off. Turn it on in Settings, then try again.")
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let peer = PeerCallbackValue(peerID)
        Task { @MainActor [weak self] in
            guard let self, !discoveredPeers.contains(peer.value) else { return }
            discoveredPeers.append(peer.value)
            if connectedPeers.isEmpty {
                pairingHint = nil
            }
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let peer = PeerCallbackValue(peerID)
        Task { @MainActor [weak self] in self?.discoveredPeers.removeAll { $0 == peer.value } }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor [weak self] in
            self?.pairingHint = String(localized: "Local Network access is off. Turn it on in Settings, then try again.")
        }
    }
}

struct PairedCaptureView: View {
    @Bindable var service: PairedCaptureService
    let onLocalShutter: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PocketPageTitle(
                    title: "Paired Capture",
                    subtitle: "Two phones, one shutter, both viewpoints kept locally."
                )

                PocketGroup("CONNECTED") {
                    if service.connectedPeers.isEmpty {
                        PocketLabeledRow(title: "No paired camera", symbol: "antenna.radiowaves.left.and.right.slash")
                    } else {
                        ForEach(service.connectedPeers, id: \.self) { peer in
                            PocketLabeledRow(title: LocalizedStringResource(stringLiteral: peer.displayName), symbol: "checkmark.circle.fill")
                        }
                    }
                    Rectangle().fill(CameraTheme.line.opacity(0.7)).frame(height: 1)
                    Button {
                        service.triggerRemote()
                        onLocalShutter()
                    } label: {
                        Text("CAPTURE BOTH VIEWPOINTS")
                            .pocketFont(9, weight: .bold, design: .monospaced)
                            .tracking(1.4)
                            .foregroundStyle(service.connectedPeers.isEmpty ? CameraTheme.muted : CameraTheme.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: 50)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(service.connectedPeers.isEmpty)
                }

                if !service.discoveredPeers.isEmpty {
                    PocketGroup("NEARBY") {
                        ForEach(service.discoveredPeers, id: \.self) { peer in
                            Button {
                                service.connect(to: peer)
                            } label: {
                                HStack(spacing: 8) {
                                    Text("Connect to \(peer.displayName)")
                                        .pocketFont(12.5)
                                        .foregroundStyle(CameraTheme.ink)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .pocketFont(9, weight: .bold)
                                        .foregroundStyle(CameraTheme.muted)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 50)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let image = service.receivedImage {
                    PocketGroup("OTHER VIEWPOINT") {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    }
                }

                if let hint = service.pairingHint {
                    Text(hint)
                        .pocketFont(12)
                        .foregroundStyle(CameraTheme.accent)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay { Rectangle().stroke(CameraTheme.accent.opacity(0.4), lineWidth: 1) }
                }

                PocketFootnote("Both phones keep their full-resolution photo. A reduced copy is exchanged locally for pairing; no account or cloud is used.")
            }
            .padding(16)
        }
        .background(CameraTheme.background)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) { PocketDismissBar() }
        .pocketSwipeBack()
        .onAppear { service.start() }
        .onDisappear {
            service.declinePendingInvitation()
            service.stop()
        }
        .overlay {
            PocketSheet("PAIRING REQUEST", isPresented: Binding(
                get: { service.pendingInvitation != nil },
                set: { if !$0 { service.declinePendingInvitation() } }
            )) {
                if let invitation = service.pendingInvitation {
                    PocketActionRow(title: "Connect to \(invitation.peerName)", symbol: "link") {
                        service.acceptPendingInvitation()
                    }
                    PocketSheetDivider()
                    PocketActionRow(title: "Decline", symbol: "xmark", destructive: true) {
                        service.declinePendingInvitation()
                    }
                }
            }
        }
    }
}


private extension UIImage {
    /// The peer only needs a reference viewpoint; sending the 12 MP original
    /// bloats a reliable MCSession message and contradicts the in-app copy.
    func pairingCopy(maxPixel: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxPixel else { return self }
        let scale = maxPixel / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
