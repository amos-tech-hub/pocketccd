import SwiftUI

@main
struct PocketCCDApp: App {
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false

    init() {
        #if DEBUG
        // Launch breadcrumb: lets a review pull tell "app never started" apart
        // from "preview never ran" without a console attached.
        if let documents = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask).first {
            let stamp = ISO8601DateFormatter().string(from: Date())
            try? stamp.data(using: .utf8)?.write(to: documents.appendingPathComponent("app-launch.txt"))
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                CameraTheme.background.ignoresSafeArea()

                Group {
                    if didCompleteOnboarding {
                        NavigationStack {
                            CameraScreen()
                        }
                    } else {
                        PocketOnboardingView {
                            didCompleteOnboarding = true
                        }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}
