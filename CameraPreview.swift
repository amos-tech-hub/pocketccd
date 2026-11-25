import AVFoundation
@preconcurrency import CoreImage
import MetalKit
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let pipeline: LivePreviewPipeline
    let look: CCDLook
    let aspectRatio: CaptureAspectRatio
    var focalCrop: CGFloat = 1
    let flashMode: AVCaptureDevice.FlashMode
    let colorAnchor: CaptureColorAnchor?
    let consistencyStrength: CGFloat
    let onFocus: (CGPoint, CGPoint) -> Void
    let onLockAEAF: (CGPoint, CGPoint) -> Void
    let onZoom: (CGFloat) -> Void
    let onExposureDrag: (CGFloat, Bool) -> Void
    let canDragExposure: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onFocus: onFocus,
            onLockAEAF: onLockAEAF,
            onZoom: onZoom,
            onExposureDrag: onExposureDrag,
            canDragExposure: canDragExposure
        )
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.pipelineRef = pipeline
        pipeline.update(look: look)
        pipeline.update(aspectRatio: aspectRatio)
        pipeline.update(focalCrop: focalCrop)
        pipeline.update(flashMode: flashMode)
        pipeline.update(colorAnchor: colorAnchor, consistencyStrength: consistencyStrength)
        pipeline.setFrameHandler { [weak view] image, onComplete in
            guard let view else {
                onComplete(0, 0)
                return
            }
            view.display(image, onComplete: onComplete)
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.focus(_:)))
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.lockAEAF(_:)))
        longPress.minimumPressDuration = 0.45
        tap.require(toFail: longPress)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.zoom(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dragExposure(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(pan)
        context.coordinator.previewView = view
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onFocus = onFocus
        context.coordinator.onLockAEAF = onLockAEAF
        context.coordinator.onZoom = onZoom
        context.coordinator.onExposureDrag = onExposureDrag
        context.coordinator.canDragExposure = canDragExposure
        pipeline.update(look: look)
        pipeline.update(aspectRatio: aspectRatio)
        pipeline.update(focalCrop: focalCrop)
        pipeline.update(flashMode: flashMode)
        pipeline.update(colorAnchor: colorAnchor, consistencyStrength: consistencyStrength)
        // The handler is installed in `makeUIView` and dropped in
        // `dismantleUIView`; re-installing it here took the pipeline lock and
        // allocated a closure on every SwiftUI update (24 fps preview state
        // included), for a handler that points at the same view anyway.
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        // Leaving the camera page must stop the per-frame GPU work instead
        // of feeding a view that is no longer on screen.
        view.pipelineRef?.setFrameHandler(nil)
        view.clearFrame()
        coordinator.previewView = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var previewView: PreviewView?
        var onFocus: (CGPoint, CGPoint) -> Void
        var onLockAEAF: (CGPoint, CGPoint) -> Void
        var onZoom: (CGFloat) -> Void
        var onExposureDrag: (CGFloat, Bool) -> Void
        var canDragExposure: Bool

        init(
            onFocus: @escaping (CGPoint, CGPoint) -> Void,
            onLockAEAF: @escaping (CGPoint, CGPoint) -> Void,
            onZoom: @escaping (CGFloat) -> Void,
            onExposureDrag: @escaping (CGFloat, Bool) -> Void,
            canDragExposure: Bool
        ) {
            self.onFocus = onFocus
            self.onLockAEAF = onLockAEAF
            self.onZoom = onZoom
            self.onExposureDrag = onExposureDrag
            self.canDragExposure = canDragExposure
        }

        private func convertedPoints(from recognizer: UIGestureRecognizer) -> (CGPoint, CGPoint)? {
            guard let view = previewView else { return nil }
            let viewPoint = recognizer.location(in: view)
            let sensorPoint: CGPoint
            if let geometry = view.pipelineRef?.previewGeometry {
                guard let point = geometry.layerPoint(for: viewPoint, in: view.bounds) else { return nil }
                sensorPoint = point
            } else {
                sensorPoint = viewPoint
            }
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: sensorPoint)
            return (devicePoint, viewPoint)
        }

        @objc func focus(_ recognizer: UITapGestureRecognizer) {
            guard let (devicePoint, viewPoint) = convertedPoints(from: recognizer) else { return }
            onFocus(devicePoint, viewPoint)
        }

        @objc func lockAEAF(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let (devicePoint, viewPoint) = convertedPoints(from: recognizer) else { return }
            onLockAEAF(devicePoint, viewPoint)
        }

        @objc func zoom(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                previewView?.pipelineRef?.setInteraction(active: true)
            case .changed:
                onZoom(recognizer.scale)
                recognizer.scale = 1
            case .ended, .cancelled, .failed:
                previewView?.pipelineRef?.setInteraction(active: false)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            guard canDragExposure, let view = previewView else { return false }
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x) * 1.2
        }

        @objc func dragExposure(_ recognizer: UIPanGestureRecognizer) {
            guard let view = previewView else { return }
            switch recognizer.state {
            case .began:
                previewView?.pipelineRef?.setInteraction(active: true)
                onExposureDrag(0, true)
            case .changed:
                let deltaY = recognizer.translation(in: view).y
                recognizer.setTranslation(.zero, in: view)
                onExposureDrag(-deltaY / 140, true)
            case .ended, .cancelled, .failed:
                previewView?.pipelineRef?.setInteraction(active: false)
                onExposureDrag(0, false)
            default:
                break
            }
        }
    }
}

final class PreviewView: UIView, MTKViewDelegate {
    private static let backdropColor = CIColor(red: 0.043, green: 0.047, blue: 0.039, alpha: 1)

    private let cameraLayer = AVCaptureVideoPreviewLayer()
    private let metalView: MTKView?
    private let commandQueue: MTLCommandQueue?
    private let ciContext: CIContext
    private let fallbackImageView: UIImageView?
    private var pendingImage: CIImage?
    private var pendingCompletion: (@Sendable (Int, Int) -> Void)?
    weak var pipelineRef: LivePreviewPipeline?

    var previewLayer: AVCaptureVideoPreviewLayer {
        cameraLayer
    }

    override init(frame: CGRect) {
        if let device = MTLCreateSystemDefaultDevice(),
           let queue = device.makeCommandQueue() {
            let mtk = MTKView(frame: frame, device: device)
            mtk.framebufferOnly = false
            mtk.colorPixelFormat = .bgra8Unorm
            mtk.isPaused = true
            mtk.enableSetNeedsDisplay = false
            mtk.clearColor = MTLClearColor(red: 0.043, green: 0.047, blue: 0.039, alpha: 1)
            mtk.isOpaque = true
            mtk.isUserInteractionEnabled = false
            self.metalView = mtk
            self.commandQueue = queue
            self.ciContext = ImagingColorPipeline.makeContext(commandQueue: queue)
            self.fallbackImageView = nil
        } else {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = false
            self.metalView = nil
            self.commandQueue = nil
            self.ciContext = ImagingColorPipeline.makeContext()
            self.fallbackImageView = imageView
        }
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.043, green: 0.047, blue: 0.039, alpha: 1)
        cameraLayer.videoGravity = .resizeAspect
        layer.addSublayer(cameraLayer)
        if let metalView {
            metalView.delegate = self
            metalView.isHidden = true
            addSubview(metalView)
        } else if let fallbackImageView {
            addSubview(fallbackImageView)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cameraLayer.frame = bounds
        CATransaction.commit()
        UIView.performWithoutAnimation {
            metalView?.frame = bounds
            fallbackImageView?.frame = bounds
        }
    }

    func display(_ image: CIImage, onComplete: @escaping @Sendable (Int, Int) -> Void) {
        if let metalView {
            // Release any superseded frame's backpressure immediately.
            pendingCompletion?(0, 0)
            pendingImage = image
            pendingCompletion = onComplete
            metalView.isHidden = false
            cameraLayer.isHidden = true
            metalView.draw()
        } else if let fallbackImageView {
            if let cgImage = ImagingColorPipeline.displayImage(image, using: ciContext) {
                fallbackImageView.image = UIImage(cgImage: cgImage)
                cameraLayer.isHidden = true
                onComplete(cgImage.width, cgImage.height)
            } else {
                onComplete(0, 0)
            }
        } else {
            onComplete(0, 0)
        }
    }

    func clearFrame() {
        pendingImage = nil
        if let completion = pendingCompletion {
            pendingCompletion = nil
            completion(0, 0)
        }
        metalView?.isHidden = true
        fallbackImageView?.image = nil
        // Show the native preview again if the filtered frame disappears.
        cameraLayer.isHidden = false
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let completion = pendingCompletion
        pendingCompletion = nil
        guard let image = pendingImage,
              let commandQueue,
              view.drawableSize.width > 0,
              view.drawableSize.height > 0,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion?(0, 0)
            return
        }
        let drawableSize = view.drawableSize
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            completion?(0, 0)
            return
        }
        let scale = min(drawableSize.width / extent.width, drawableSize.height / extent.height)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let offsetX = (drawableSize.width - scaledWidth) * 0.5
        let offsetY = (drawableSize.height - scaledHeight) * 0.5
        let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offsetX, y: offsetY))
        let targetBounds = CGRect(origin: .zero, size: drawableSize)
        var output = image.transformed(by: transform)
        if offsetX > 0.5 || offsetY > 0.5 {
            output = output.composited(over: CIImage(color: Self.backdropColor).cropped(to: targetBounds))
        }
        ciContext.render(
            output,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: targetBounds,
            colorSpace: ImagingColorPipeline.output
        )
        let width = drawable.texture.width
        let height = drawable.texture.height
        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { _ in
            completion?(width, height)
        }
        commandBuffer.commit()
    }
}

/// Convert a tap in the cropped filtered image into the full native preview
/// layer. The layer then applies its camera rotation and mirroring to the POI.
struct PreviewFrameGeometry {
    let sourceSize: CGSize
    let aspectRatio: CaptureAspectRatio
    let focalCrop: CGFloat

    func layerPoint(for point: CGPoint, in bounds: CGRect) -> CGPoint? {
        guard sourceSize.width > 0, sourceSize.height > 0,
              bounds.width > 0, bounds.height > 0,
              sourceSize.width.isFinite, sourceSize.height.isFinite else { return nil }
        let crop = aspectRatio.cropRect(in: CGRect(origin: .zero, size: sourceSize), focalCrop: focalCrop)
        func fitted(_ size: CGSize) -> CGRect {
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            return CGRect(x: bounds.midX - size.width * scale / 2,
                          y: bounds.midY - size.height * scale / 2,
                          width: size.width * scale, height: size.height * scale)
        }
        let displayed = fitted(crop.size)
        guard point.x >= displayed.minX, point.x <= displayed.maxX,
              point.y >= displayed.minY, point.y <= displayed.maxY else { return nil }
        let u = (crop.minX + (point.x - displayed.minX) / displayed.width * crop.width) / sourceSize.width
        let v = (crop.minY + (point.y - displayed.minY) / displayed.height * crop.height) / sourceSize.height
        let native = fitted(sourceSize)
        return CGPoint(x: native.minX + u * native.width, y: native.minY + v * native.height)
    }
}
