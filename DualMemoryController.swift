@preconcurrency import AVFoundation
import CoreImage
import UIKit

/// All mutable capture state is confined to `queue`. The unchecked conformance
/// bridges AVFoundation/GCD APIs that do not yet express that executor contract.
final class DualMemoryController: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    static var isSimultaneousSupported: Bool { AVCaptureMultiCamSession.isMultiCamSupported }

    private let queue = DispatchQueue(label: "app.pocketccd.dualmemory")
    private var session: AVCaptureMultiCamSession?
    private var rearOutput: AVCapturePhotoOutput?
    private var frontOutput: AVCapturePhotoOutput?
    private var rearRequestID: Int64?
    private var frontRequestID: Int64?
    private var rearPhoto: CapturedPhoto?
    private var frontPhoto: CapturedPhoto?
    private var continuation: CheckedContinuation<(rear: CapturedPhoto, front: CapturedPhoto), Error>?
    private var isCapturing = false

    private nonisolated static let captureContext = ImagingColorPipeline.makeContext()

    func capture() async throws -> (rear: CapturedPhoto, front: CapturedPhoto) {
        guard Self.isSimultaneousSupported else { throw CameraIssue.configurationFailed }
        let accepted = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !isCapturing else {
                    continuation.resume(returning: false)
                    return
                }
                isCapturing = true
                continuation.resume(returning: true)
            }
        }
        guard accepted else { throw CameraIssue.captureFailed }
        do {
            try await configureAndStart()
        } catch {
            queue.async { [self] in isCapturing = false }
            throw error
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                self.rearPhoto = nil
                self.frontPhoto = nil
                guard let rearOutput, let frontOutput else {
                    finish(with: .failure(CameraIssue.configurationFailed))
                    return
                }
                let rearSettings = AVCapturePhotoSettings()
                let frontSettings = AVCapturePhotoSettings()
                let requestID = rearSettings.uniqueID
                self.rearRequestID = requestID
                self.frontRequestID = frontSettings.uniqueID
                queue.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, self.rearRequestID == requestID else { return }
                    self.finish(with: .failure(CameraIssue.captureFailed))
                }
                rearOutput.capturePhoto(with: rearSettings, delegate: self)
                frontOutput.capturePhoto(with: frontSettings, delegate: self)
            }
        }
    }

    private func configureAndStart() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let existing = self.session,
                   self.rearOutput != nil,
                   self.frontOutput != nil {
                    if !existing.isRunning { existing.startRunning() }
                    if existing.isRunning {
                        continuation.resume()
                        return
                    }
                    // Media services may have invalidated the cached fixture.
                    self.session = nil
                    self.rearOutput = nil
                    self.frontOutput = nil
                }

                let session = AVCaptureMultiCamSession()
                session.beginConfiguration()
                session.sessionPreset = .photo

                // Every failure path must commit the open configuration and
                // leave the cached fields empty; the old code kept a broken
                // fixture that made the next attempt fail forever.
                func abort() {
                    session.commitConfiguration()
                    self.session = nil
                    self.rearOutput = nil
                    self.frontOutput = nil
                    continuation.resume(throwing: CameraIssue.configurationFailed)
                }

                guard
                    let rearDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                    let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                    let rearInput = try? AVCaptureDeviceInput(device: rearDevice),
                    let frontInput = try? AVCaptureDeviceInput(device: frontDevice)
                else {
                    abort()
                    return
                }

                let rearOutput = AVCapturePhotoOutput()
                let frontOutput = AVCapturePhotoOutput()
                guard session.canAddInput(rearInput), session.canAddInput(frontInput),
                      session.canAddOutput(rearOutput), session.canAddOutput(frontOutput) else {
                    abort()
                    return
                }
                session.addInputWithNoConnections(rearInput)
                session.addInputWithNoConnections(frontInput)
                session.addOutputWithNoConnections(rearOutput)
                session.addOutputWithNoConnections(frontOutput)

                guard let rearPort = rearInput.ports.first(where: { $0.mediaType == .video }),
                      let frontPort = frontInput.ports.first(where: { $0.mediaType == .video }) else {
                    abort()
                    return
                }
                let rearConnection = AVCaptureConnection(inputPorts: [rearPort], output: rearOutput)
                let frontConnection = AVCaptureConnection(inputPorts: [frontPort], output: frontOutput)
                guard session.canAddConnection(rearConnection), session.canAddConnection(frontConnection) else {
                    abort()
                    return
                }
                session.addConnection(rearConnection)
                session.addConnection(frontConnection)

                // Commit before starting. MultiCam evaluates the configuration
                // as a whole, and an over-budget session can throw an ObjC
                // exception that Swift cannot catch. Check the advertised costs
                // and fall back to the sequential path instead of crashing.
                session.commitConfiguration()
                guard session.hardwareCost < 1.0, session.systemPressureCost < 1.0 else {
                    self.session = nil
                    self.rearOutput = nil
                    self.frontOutput = nil
                    continuation.resume(throwing: CameraIssue.configurationFailed)
                    return
                }

                session.startRunning()
                guard session.isRunning else {
                    session.stopRunning()
                    self.session = nil
                    self.rearOutput = nil
                    self.frontOutput = nil
                    continuation.resume(throwing: CameraIssue.configurationFailed)
                    return
                }
                self.session = session
                self.rearOutput = rearOutput
                self.frontOutput = frontOutput
                continuation.resume()
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        queue.async { [self] in
            let requestID = photo.resolvedSettings.uniqueID
            let isRear = output === rearOutput && rearRequestID == requestID
            let isFront = output === frontOutput && frontRequestID == requestID
            guard isRear || isFront else { return }
            if let error { finish(with: .failure(error)); return }
            let encoded = photo.fileDataRepresentation()
            let decoded: UIImage? = photo.pixelBuffer.flatMap { buffer in
                let orientation = (photo.metadata[kCGImagePropertyOrientation as String] as? NSNumber)
                    .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .right
                let source = CIImage(cvPixelBuffer: buffer).oriented(orientation)
                guard let cgImage = ImagingColorPipeline.displayImage(source, using: Self.captureContext) else { return nil }
                return UIImage(cgImage: cgImage)
            }
            guard let image = decoded ?? encoded.flatMap({ UIImage(data: $0) }) else {
                finish(with: .failure(CameraIssue.captureFailed)); return
            }
            let captured = CapturedPhoto(image: image, originalData: encoded, metadata: PhotoFrameMetadata(photo.metadata))
            if isRear { rearPhoto = captured }
            if isFront { frontPhoto = captured }
            if let rearPhoto, let frontPhoto { finish(with: .success((rearPhoto, frontPhoto))) }
        }
    }

    private func finish(with result: Result<(rear: CapturedPhoto, front: CapturedPhoto), Error>) {
        rearRequestID = nil
        frontRequestID = nil
        session?.stopRunning()
        isCapturing = false
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// The fallback is a transaction: restore the caller's camera before returning
/// either the photos or an error, including cancellation during settling.
@MainActor
enum SequentialDualCapture {
    static func capture<Photo>(
        initialPosition: AVCaptureDevice.Position,
        switchTo: @MainActor (AVCaptureDevice.Position) async throws -> Void,
        capturePhoto: @MainActor () async throws -> Photo,
        rearCaptured: @MainActor () -> Void = {},
        waitForCamera: @MainActor () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(500))
        }
    ) async throws -> (rear: Photo, front: Photo) {
        guard initialPosition == .back || initialPosition == .front else { throw CameraIssue.configurationFailed }
        let outcome: Result<(rear: Photo, front: Photo), Error>
        do {
            try Task.checkCancellation()
            try await switchTo(.back)
            if initialPosition != .back { try await waitForCamera() }
            let rear = try await capturePhoto()
            rearCaptured()
            try Task.checkCancellation()
            try await switchTo(.front)
            try await waitForCamera()
            try Task.checkCancellation()
            let front = try await capturePhoto()
            outcome = .success((rear, front))
        } catch {
            outcome = .failure(error)
        }
        // Do not put restoration in an unawaited Task or cancelled sleep.
        try await switchTo(initialPosition)
        return try outcome.get()
    }
}
