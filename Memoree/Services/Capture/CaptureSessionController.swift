// `AVFoundation` predates `Sendable` and is not annotated for it. The session,
// its inputs, outputs and connections are all documented thread-safe for the
// operations used here and are only ever touched from `queue` or the
// video-output queue — never concurrently, and never from two isolation
// domains at once. Importing preconcurrency says exactly that, rather than
// scattering `@unchecked Sendable` box types through the file.
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

/// Owns the `AVCaptureSession` and everything attached to it.
///
/// ## Concurrency
///
/// `NSObject, @unchecked Sendable`: every mutable property below is confined to
/// `queue` and is only read or written from it, with the single documented
/// exception of `previewLayer`, which is immutable after construction and is
/// read from the main thread to install it into the view hierarchy (ADR-018).
/// The `AVCaptureSession` itself is not `Sendable`, which is why the whole type
/// is `@unchecked` rather than merely crossing actor boundaries (AGENTS.md §5).
///
/// **Nothing configures the session on the main thread.** Not once, not "just
/// for the preview". `beginConfiguration` and `commitConfiguration` block, and
/// doing that on the main thread during a live preview is visible as a dropped
/// frame; the code below routes every mutation through `queue`.
///
/// ## The frame wait
///
/// After an input swap, capturing immediately yields a black or green frame
/// because the sensor has not yet delivered anything. The obvious fix — a
/// `sleep` — is the first thing that will flake under load, and it is called
/// out as such in four places across the docs.
///
/// Instead, `AVCaptureVideoDataOutput` is used purely as a *frame signal*: a
/// `CheckedContinuation` is armed before the swap and resumed by the first
/// frame that arrives **after** it. The generation counter is what makes that
/// correct. Without it, a frame already in flight from the outgoing camera
/// satisfies the wait and the front photo comes out black — the exact failure
/// the sleep was meant to prevent, arriving through a different door.
final class CaptureSessionController: NSObject, @unchecked Sendable {

    // MARK: - Types

    /// What the session is doing, as observed by callers.
    enum State: Equatable, Sendable {
        case idle
        case running
        case interrupted
        case failed(CaptureError)
    }

    // MARK: - Constants

    /// The serial queue label, per docs/TRD.md §5.2.
    private static let queueLabel = "capture.session"

    /// How long to wait for a frame from a newly added input.
    ///
    /// Generous, because exceeding it produces a visible failure while
    /// shortening it produces a flaky one. A real sensor delivers in
    /// milliseconds; 2s is roughly a thousand times that, so this is a
    /// backstop against a genuinely dead input rather than a timing assumption.
    private static let frameWaitTimeout: TimeInterval = 2.0

    /// How long to wait for the session to stop after `stopSession`.
    private static let stopTimeout: TimeInterval = 1.0

    // MARK: - Isolated state

    private let queue = DispatchQueue(label: CaptureSessionController.queueLabel)

    /// `var` only because `rebuildSession` replaces it wholesale when
    /// `mediaServicesWereReset` fires. Never reassigned anywhere else, and
    /// every access is on `queue` except the one documented on `previewSurface`.
    private var session = AVCaptureSession()

    private var photoOutput = AVCapturePhotoOutput()

    /// Frame signal only. Its pixel buffers are counted, never read.
    private let videoOutput = AVCaptureVideoDataOutput()

    private var activeInput: AVCaptureDeviceInput?
    private var activePosition: CameraPosition = .default

    /// Incremented on every input swap.
    ///
    /// Used only for diagnostics and for rejecting a frame-wait that is
    /// already armed. Correctness of the wait itself rests on **port
    /// identity** — see `deliverFrame(from:)`.
    private var generation: UInt64 = 0

    /// An armed frame wait. Exactly one at a time.
    private struct FrameWait {
        let generation: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var frameWait: FrameWait?

    /// An armed photo capture. Exactly one at a time.
    private struct PhotoWait {
        let position: CameraPosition
        let continuation: CheckedContinuation<CapturedPhoto, Error>
    }

    private var photoWait: PhotoWait?

    private(set) var state: State = .idle

    /// The concrete preview layer, exposed as `CALayer` (ADR-018).
    ///
    /// Immutable after `init`, which is what makes reading it from the main
    /// thread safe despite the rest of the type being queue-confined.
    let previewSurface: AVCaptureVideoPreviewLayer

    // MARK: - Init

    override init() {
        previewSurface = AVCaptureVideoPreviewLayer(session: session)
        super.init()

        // The service owns presentation decisions, because they are capture
        // concerns rather than layout ones (ADR-018).
        previewSurface.videoGravity = .resizeAspectFill

        videoOutput.alwaysDiscardsLateVideoFrames = true
        // A dedicated queue, not the session queue: frame delivery must not
        // block session configuration, or the wait it feeds would deadlock
        // against the swap that armed it.
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "capture.frames"))
    }

    // MARK: - Preview

    var previewLayer: CALayer { previewSurface }

    // MARK: - Authorisation

    func authorizationStatus() -> CameraAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestAuthorization() async -> CameraAuthorizationStatus {
        // Never blocks indefinitely: `requestAccess` completes on a queue, and
        // the caller is free to ignore the result. A denied answer is a
        // supported state, not an error (AGENTS.md §9).
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { _ in
                continuation.resume(returning: self.authorizationStatus())
            }
        }
    }

    // MARK: - Lifecycle

    func startSession() async throws {
        let status = authorizationStatus()
        guard status == .authorized || status == .notDetermined else {
            throw status == .restricted ? CaptureError.restricted : CaptureError.permissionDenied
        }
        guard status == .authorized else { throw CaptureError.permissionDenied }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try configureSession()
                    session.startRunning()
                    state = .running
                    c.resume()
                } catch {
                    state = .failed(Self.map(error))
                    c.resume(throwing: Self.map(error))
                }
            }
        }
    }

    func stopSession() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                session.stopRunning()
                state = .idle
                c.resume()
            }
        }
    }

    /// Destroys the session and builds a new one.
    ///
    /// The recovery path for `mediaServicesWereReset`, which raises no error
    /// and fires no delegate callback — the preview simply freezes, and it is
    /// the single most common cause of "my camera app froze" in the field
    /// (TRD §5.5). There is nothing to retry, so the session is replaced.
    func rebuildSession() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                session.stopRunning()
                // Detach the preview from the doomed session before dropping it,
                // or the layer keeps a strong reference to a dead object.
                previewSurface.session = nil

                let replacement = AVCaptureSession()
                previewSurface.session = replacement

                // The old session is unreachable once this returns; every
                // output, input and continuation it owned goes with it.
                session = replacement
                photoOutput = AVCapturePhotoOutput()
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(
                    self, queue: DispatchQueue(label: "capture.frames")
                )
                activeInput = nil

                do {
                    try configureSession()
                    session.startRunning()
                    state = .running
                    c.resume()
                } catch {
                    state = .failed(Self.map(error))
                    c.resume(throwing: Self.map(error))
                }
            }
        }
    }

    /// Applies `.inputPriority` and the chosen 3:4 format.
    ///
    /// Must be called after **every** input swap: `sessionPreset` is not
    /// reliable across one, and front and rear support different format lists
    /// (TRD §5.3).
    func configureFormat(for position: CameraPosition) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try applyFormat(for: position)
                    c.resume()
                } catch {
                    c.resume(throwing: Self.map(error))
                }
            }
        }
    }

    // MARK: - Capture

    /// Captures one photograph from the input already attached at `position`.
    ///
    /// Does not swap inputs — `SequentialCaptureService` owns the ordering,
    /// because the swap and the frame-wait are one indivisible step.
    func capturePhoto(at position: CameraPosition) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard state == .running else {
                    continuation.resume(throwing: CaptureError.sessionReset)
                    return
                }
                guard activePosition == position, activeInput != nil else {
                    continuation.resume(throwing: CaptureError.noInputAvailable(position))
                    return
                }
                guard photoWait == nil else {
                    // One capture at a time. A second concurrent request would
                    // silently overwrite the first continuation and hang it.
                    continuation.resume(throwing: CaptureError.configurationFailed(
                        "a capture is already in flight"
                    ))
                    return
                }

                let settings = Self.photoSettings(for: position)

                // A fresh delegate per capture, released immediately after.
                // Reusing one would retain the session through the delegate
                // and keep every captured frame buffer alive (AGENTS.md §5).
                let delegate = SingleShotPhotoDelegate(
                    position: position,
                    dimensions: settings.dimensions,
                    continuation: continuation,
                    completion: { [weak self] in self?.clearPendingPhoto(for: position) }
                )
                pendingPhotoDelegate = delegate
                photoWait = PhotoWait(position: position, continuation: continuation)
                photoOutput.capturePhoto(with: settings.settings, delegate: delegate)
            }
        }
    }

    /// Retained for exactly the duration of one capture. See the comment at the
    /// call site for why a fresh delegate is created rather than reused.
    private var pendingPhotoDelegate: SingleShotPhotoDelegate?

    private func clearPendingPhoto(for position: CameraPosition) {
        guard photoWait?.position == position else { return }
        photoWait = nil
        pendingPhotoDelegate = nil
    }

    // MARK: - The frame wait

    /// Arms a wait for the first frame delivered by the currently attached input.
    ///
    /// Frames arrive on the video-output queue at 30–60fps, so resuming through
    /// the session queue costs one hop of a few hundred microseconds — only
    /// during a swap, never in steady state. Cheaper than a lock, and it has no
    /// timeout task, so there is no timing assumption to be wrong about.
    func waitForDeliveredFrame() async throws {
        // Spelled out with a local rather than a trailing closure: assigning a
        // stored tuple containing a continuation makes this compiler version
        // fail to produce a diagnostic for the expression. The named
        // `FrameWait` and the explicit local also make the "resumed exactly
        // once" contract visible at the point of arming.
        try await withCheckedThrowingContinuation { (armed: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard self.activeInput != nil else {
                    armed.resume(throwing: CaptureError.noInputAvailable(self.activePosition))
                    return
                }
                guard self.frameWait == nil else {
                    armed.resume(throwing: CaptureError.configurationFailed(
                        "a frame wait is already armed"
                    ))
                    return
                }
                self.frameWait = FrameWait(generation: self.generation, continuation: armed)
            }
        }
    }

    /// Resumes an armed frame wait when a frame from the **current** input lands.
    ///
    /// Called on the video-output queue. The port-identity check is what makes
    /// this correct rather than merely plausible.
    ///
    /// A generation counter alone does not work, and the reason is worth
    /// recording: a frame from the *outgoing* camera, already in flight when
    /// the swap happened, is delivered afterwards. Reading "the current
    /// generation" on the delivery callback returns the *new* generation,
    /// because that is what the counter says by then — so the stale frame is
    /// accepted and the front photo comes out black or green. That is the exact
    /// failure a `sleep` was meant to prevent, arriving through another door.
    ///
    /// `AVCaptureConnection.inputPorts` names the input a frame actually came
    /// from, and that does not change retroactively. Comparing it against the
    /// port of the input attached *now* distinguishes a genuine new-camera
    /// frame from an old one, whatever order they arrive in.
    private func deliverFrame(from connection: AVCaptureConnection) {
        queue.async { [self] in
            guard let wait = self.frameWait, let input = self.activeInput else { return }
            guard let expectedPort = input.ports.first else {
                self.frameWait = nil
                wait.continuation.resume(throwing: CaptureError.noInputAvailable(self.activePosition))
                return
            }
            guard connection.inputPorts.contains(where: { $0 === expectedPort }) else {
                // A frame from the camera we just removed. Correctly ignored.
                return
            }
            self.frameWait = nil
            wait.continuation.resume()
        }
    }

    /// Increments the generation, on the session queue.
    private func beginSwapGeneration() async -> UInt64 {
        await withCheckedContinuation { c in
            queue.async { [self] in
                self.generation &+= 1
                c.resume(returning: self.generation)
            }
        }
    }

    // MARK: - Configuration

    /// Builds inputs and outputs. Must run on `queue`.
    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // `.inputPriority` rather than a preset: a preset is a hint the session
        // may reinterpret when inputs change, so the format in use after a swap
        // would not be the one that was asked for (TRD §5.3).
        session.sessionPreset = .inputPriority

        guard session.canAddOutput(photoOutput) else {
            throw CaptureError.configurationFailed("photo output rejected")
        }
        session.addOutput(photoOutput)

        guard session.canAddOutput(videoOutput) else {
            throw CaptureError.configurationFailed("frame-signal output rejected")
        }
        session.addOutput(videoOutput)

        try attachInput(at: .default)
        try applyFormat(for: activePosition)
    }

    /// Opens and attaches the input for `position`. Must run on `queue`.
    private func attachInput(at position: CameraPosition) throws {
        guard let device = CaptureFormatSelector.wideAngleDevice(for: position) else {
            throw CaptureError.noInputAvailable(position)
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        if let existing = activeInput {
            session.removeInput(existing)
        }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.noInputAvailable(position)
        }
        session.addInput(input)
        session.commitConfiguration()

        activeInput = input
        activePosition = position
    }

    /// Applies the 3:4 format to the active input. Runs on `queue`.
    private func applyFormat(for position: CameraPosition) throws {
        guard let input = activeInput else {
            throw CaptureError.noInputAvailable(position)
        }
        let device = input.device
        guard let format = CaptureFormatSelector.selectFormat(for: device) else {
            // No 3:4 format means the geometry cannot be honoured. Failing
            // loudly beats saving moments at the wrong aspect ratio forever.
            throw CaptureError.noInputAvailable(position)
        }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = format
        // Pin the frame duration rather than leaving it to the format default,
        // so a swap cannot land on a different rate than the one selected.
        let duration = CMTime(
            value: 1,
            timescale: CMTimeScale(CaptureFormatSelector.minimumFrameRate)
        )
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration

        configureMirroring(for: position)
    }

    /// Swaps the attached input to `position` and waits for it to deliver.
    ///
    /// **Step 7 of docs/TRD.md §5.2, and the one that is not optional.**
    /// Capturing before the new sensor has delivered a frame yields a black or
    /// green image. The wait is a real frame signal, not a sleep.
    func swapInput(to position: CameraPosition) async throws {
        // Bump the generation first: a frame-wait armed before the swap must
        // not be satisfied by anything the old input produced.
        _ = await beginSwapGeneration()

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try attachInput(at: position)
                    try applyFormat(for: position)
                    c.resume()
                } catch {
                    c.resume(throwing: Self.map(error))
                }
            }
        }

        try await waitForDeliveredFrame()
    }

    /// Mirrors the front camera on its connection.
    ///
    /// Set on the connection rather than by transforming pixels, so
    /// `fileDataRepresentation()` already reflects it (TRD §5.4). Getting this
    /// wrong is instantly visible: a selfie that reads as a photograph of a
    /// photograph rather than a mirror.
    private func configureMirroring(for position: CameraPosition) {
        guard let connection = photoOutput.connection(with: .video) else { return }
        guard connection.isVideoMirroringSupported else { return }
        connection.isVideoMirrored = (position == .front)
    }

    // MARK: - Photo settings

    private struct PhotoSettings {
        let settings: AVCapturePhotoSettings
        let dimensions: CMVideoDimensions
    }

    private static func photoSettings(for position: CameraPosition) -> PhotoSettings {
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .speed

        // `maxPhotoDimensions` replaced the deprecated
        // `isHighResolutionPhotoEnabled` on iOS 16 (TRD §5.3). Left at the
        // output default when no 3:4 format was found, since a zero-sized
        // maximum is meaningless and would fail at capture time rather than
        // here.
        guard let device = CaptureFormatSelector.wideAngleDevice(for: position),
              let format = CaptureFormatSelector.selectFormat(for: device)
        else {
            return PhotoSettings(
                settings: settings,
                dimensions: CMVideoDimensions(width: 0, height: 0)
            )
        }

        let dimensions = CaptureFormatSelector.dimensions(of: format)
        settings.maxPhotoDimensions = dimensions
        return PhotoSettings(settings: settings, dimensions: dimensions)
    }

    // MARK: - Errors

    /// Normalises anything thrown inside the session into a `CaptureError`.
    static func map(_ error: Error) -> CaptureError {
        if let captureError = error as? CaptureError { return captureError }

        let nsError = error as NSError
        guard nsError.domain == AVFoundationErrorDomain else {
            return .configurationFailed(nsError.localizedDescription)
        }

        switch nsError.code {
        case AVError.deviceInUseByAnotherApplication.rawValue:
            return .inUseByAnotherApp
        case AVError.deviceNotConnected.rawValue:
            return .noInputAvailable(.default)
        default:
            return .configurationFailed(nsError.localizedDescription)
        }
    }
}

// MARK: - Frame signal

extension CaptureSessionController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // The sample buffer is never read. Its arrival, and the connection it
        // arrived on, are the entire signal.
        deliverFrame(from: connection)
    }
}

// MARK: - Single-shot photo delegate

/// Receives exactly one `AVCapturePhoto` callback, then releases.
///
/// A fresh instance per capture. `AVCapturePhotoOutput` retains its delegate
/// until the callback fires, and a long-lived delegate would keep the
/// continuation — and everything the caller captured it for — alive across
/// sessions (AGENTS.md §5).
private final class SingleShotPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    private let position: CameraPosition
    private let dimensions: CMVideoDimensions
    private let continuation: CheckedContinuation<CapturedPhoto, Error>
    private let completion: () -> Void

    private var hasResumed = false
    private let lock = NSLock()

    init(
        position: CameraPosition,
        dimensions: CMVideoDimensions,
        continuation: CheckedContinuation<CapturedPhoto, Error>,
        completion: @escaping () -> Void
    ) {
        self.position = position
        self.dimensions = dimensions
        self.continuation = continuation
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        // Locked because the delegate contract permits both
        // `didFinishProcessingPhoto` and `didFinishCaptureFor` to arrive, and
        // the continuation must be resumed exactly once (AGENTS.md §5).
        lock.lock()
        let alreadyResumed = hasResumed
        hasResumed = true
        lock.unlock()

        guard !alreadyResumed else { return }

        defer { completion() }

        if let error {
            continuation.resume(throwing: CaptureSessionController.map(error))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            continuation.resume(throwing: CaptureError.photoDataUnavailable(position))
            return
        }

        continuation.resume(returning: CapturedPhoto(
            data: data,
            pixelWidth: Int(dimensions.width),
            pixelHeight: Int(dimensions.height),
            position: position
        ))
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        // Nothing to do. `didFinishProcessingPhoto` carries the data and
        // already resumed; this exists so the delegate conforms fully and so
        // the ordering of the two callbacks is explicit rather than implied.
    }
}
