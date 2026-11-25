import AVKit
import SwiftUI

struct HardwareShutterView: UIViewRepresentable {
    let isEnabled: Bool
    let onShutter: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onShutter: onShutter)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { event in
                guard event.phase == .ended else { return }
                context.coordinator.onShutter()
            }
            interaction.isEnabled = isEnabled
            view.addInteraction(interaction)
            context.coordinator.interaction = interaction
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onShutter = onShutter
        if #available(iOS 17.2, *),
           let interaction = context.coordinator.interaction as? AVCaptureEventInteraction {
            interaction.isEnabled = isEnabled
        }
    }

    final class Coordinator {
        var onShutter: () -> Void
        var interaction: AnyObject?

        init(onShutter: @escaping () -> Void) {
            self.onShutter = onShutter
        }
    }
}

