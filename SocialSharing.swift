import SwiftUI
import UIKit

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onComplete(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

enum InstagramStoriesSharer {
    /// Why the handoff failed. A plain Bool could not tell "this build has no
    /// Meta app ID" apart from "Instagram is not installed", so a missing app ID
    /// sent people to the App Store for a bug they could not fix.
    enum Failure: Equatable, Sendable {
        case notConfigured
        case instagramUnavailable
        case imageEncodingFailed
    }

    private static var configuredAppID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PocketCCDInstagramAppID") as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Instagram has required a Meta app ID for third-party Stories handoff
    /// since 30 January 2023. The ID travels both in the pasteboard item and in
    /// the URL because Instagram releases have validated different ones.
    static func shareURL(appID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "instagram-stories"
        components.host = "share"
        components.queryItems = [URLQueryItem(name: "source_application", value: appID)]
        return components.url
    }

    @MainActor
    static var isAvailable: Bool {
        guard let appID = configuredAppID, let url = shareURL(appID: appID) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Returns nil once Instagram opened with the image already on the
    /// pasteboard; every other outcome carries the reason for the alert.
    @MainActor
    static func share(_ image: UIImage) async -> Failure? {
        guard let appID = configuredAppID, let url = shareURL(appID: appID) else {
            return .notConfigured
        }
        guard UIApplication.shared.canOpenURL(url) else { return .instagramUnavailable }
        let data = await Task.detached(priority: .userInitiated) { [image] in
            ImagingColorPipeline.exportImage(image)?.jpegData(compressionQuality: 0.95)
        }.value
        guard let data else { return .imageEncodingFailed }

        let item: [String: Any] = [
            "com.instagram.sharedSticker.backgroundImage": data,
            "com.instagram.sharedSticker.source_application": appID
        ]
        UIPasteboard.general.setItems(
            [item],
            options: [.expirationDate: Date().addingTimeInterval(5 * 60)]
        )
        let opened = await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
        if !opened {
            // The handoff failed, so do not leave the finished photo on the
            // general pasteboard for the rest of the expiry window.
            UIPasteboard.general.items = []
        }
        return opened ? nil : .instagramUnavailable
    }
}

extension InstagramStoriesSharer.Failure {
    var title: LocalizedStringResource {
        switch self {
        case .notConfigured: "INSTAGRAM NOT ENABLED"
        case .instagramUnavailable: "INSTAGRAM UNAVAILABLE"
        case .imageEncodingFailed: "PHOTO NOT READY"
        }
    }

    var message: String {
        switch self {
        case .notConfigured:
            String(localized: "This build has no Meta app ID, so Instagram Story sharing is off. Use the system share sheet instead.")
        case .instagramUnavailable:
            String(localized: "Install or update Instagram, or use the system share sheet instead.")
        case .imageEncodingFailed:
            String(localized: "This photo couldn't be prepared for Instagram. Use the system share sheet instead.")
        }
    }
}
