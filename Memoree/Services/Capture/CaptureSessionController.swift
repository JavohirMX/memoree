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
    /// Set from measurement, not taste. `FrameWaitDiagnostics` performs 40
    /// swaps on a real iPhone 17 with no photo capture in between:
    ///
    /// ```
    /// min 0.421s · median 0.472s · p90 0.809s · max 0.815s · 0 failures
    /// ```
    ///
    /// So an idle swap-and-wait is half a second and never approaches a
    /// two-second deadline. But in the real sequence the swap follows a
    /// **photo capture**, and `AVCapturePhotoOutput` and
    /// `AVCaptureVideoDataOutput` share the session — frames pause while a
    /// photo is being processed, and the first frames after a swap arrive
    /// later than they do from an idle session. That is precisely where the
    /// reliability loop timed out: 2 failures in 20 iterations, against 0 in
    /// 40 isolated swaps.
    ///
    /// Five seconds is roughly six times the worst idle observation, so a
    /// post-capture pause has real headroom. The cost is paid only when the
    /// camera is genuinely dead, and it is a user waiting a few seconds longer
    /// to see an error message — a cheap trade against a black photograph that
    /// looks fine and is wrong forever.
    ///
    /// Implemented as a deadline **inside** the session queue, not as a
    /// cancellable sibling task. A `ThrowingTaskGroup` racing this wait and
    /// cancelling the loser cannot work: the wait is a continuation resumed
    /// only by a frame arriving on the video-output queue, so cancelling the
    /// task abandons it and the caller never returns. A deadline scheduled on
    /// the same queue that arms the wait can resume it exactly once, whichever
    /// of frame-or-deadline arrives first.
    private static let frameWaitTimeout: TimeInterval = 5.0

    /// How long to wait for a photo delegate to call back.
    ///
    /// Same reasoning as `frameWaitTimeout`. `AVCapturePhotoOutput` normally
    /// calls back promptly, including on failure, but "normally" is not a
    /// guarantee, and an un-resumed continuation hangs the app rather than
    /// failing it.
    private static let photoWaitTimeout: TimeInterval = 10.0

    /// The frame-wait deadline, exposed for the device diagnostic that measures
    /// how close real waits run to it. Read-only; the deadline itself is set
    /// above and not configurable, because a configurable one invites tuning it
    /// until the test passes rather than until the camera is reliable.
    static var frameWaitTimeoutForDiagnostics: TimeInterval { frameWaitTimeout }

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

    /// The live camera, once a session is configured.
    ///
    /// Starts as `.back` and that is a placeholder, never an observation: it is
    /// only read from paths that run after `startSession(on:)` has set it, and
    /// from `map(_:at:)` during a configuration that is already failing. Making
    /// it optional would mean guarding every read for nil in exchange for a
    /// state the type cannot represent — there is no "no camera" moment inside a
    /// running session, because one is attached before anything is captured.
    private var activePosition: CameraPosition = .back

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
        /// When the wait was armed, for the diagnostic below.
        let armedAt: DispatchTime
    }

    private var frameWait: FrameWait?

    // MARK: - Frame-wait diagnostics

    /// Total frames the video output has delivered since the last reset.
    ///
    /// ## Why this is counted at all
    ///
    /// The gate has failed three times with three different rates — 4/20, then
    /// 1/20, then 6/20 — and in every failure the frame wait hit its 5s deadline
    /// with `rejected=0`. `rejected=0` only says *no frame was rejected*; it
    /// cannot distinguish "no frame arrived" from "frames arrived while no wait
    /// was armed", because both increment nothing.
    ///
    /// This is the measurement that separates them. Sampled at the moment the
    /// deadline fires:
    ///
    /// - **Counter has not moved** → the output is genuinely silent. The session
    ///   is not producing, and the frame signal this code depends on has nothing
    ///   to signal.
    /// - **Counter has moved a lot** → frames *are* flowing and the wait is
    ///   failing to see them, which puts the bug in the matching logic rather
    ///   than in the camera.
    ///
    /// One number, sampled at the exact moment that matters, and it splits the
    /// problem in half. Everything else here is bookkeeping; this is the test.
    private var totalFramesDelivered = 0

    /// The counter when the current wait was armed, so a timeout can report the
    /// difference rather than the total.
    private var framesAtArmTime = 0

    /// Frames seen and dropped by the port check during the *current* wait.
    private var framesRejectedDuringWait = 0

    /// The camera the last swap came from, so a recorded wait can say
    /// `front->back` rather than just `back`.
    private var positionBeforeSwap: CameraPosition = .back

    /// Frames delivered during the last completed wait, and the wait's outcome.
    ///
    /// The second field is the whole point of the first. See `totalFramesDelivered`.
    struct FrameWaitOutcome: CustomStringConvertible {
        let target: CameraPosition
        let from: CameraPosition
        let duration: TimeInterval
        /// Frames the port check refused.
        let rejectedFrames: Int
        /// Frames that arrived *at all* during the wait, including rejects.
        let framesSeen: Int
        let timedOut: Bool

        var description: String {
            let outcome = timedOut ? "TIMEOUT" : "ok"
            return "\(from.rawValue)->\(target.rawValue) \(outcome) "
                + String(format: "%.3fs", duration)
                + " seen=\(framesSeen)"
                + (rejectedFrames > 0 ? " rejected=\(rejectedFrames)" : "")
        }
    }

    /// The last few waits, newest last. Bounded: the gate needs the history and
    /// a user taking four hundred photographs does not.
    private static let diagnosticCapacity = 24
    private var diagnostics: [FrameWaitOutcome] = []

    private func record(_ outcome: FrameWaitOutcome) {
        diagnostics.append(outcome)
        if diagnostics.count > Self.diagnosticCapacity {
            diagnostics.removeFirst(diagnostics.count - Self.diagnosticCapacity)
        }
    }

    private func seconds(since start: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// The recorded waits.
    func frameWaitDiagnostics() async -> [FrameWaitOutcome] {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.diagnostics) }
        }
    }

    /// Clears the history and the frame counter, so one run measures one thing.
    func resetFrameWaitDiagnostics() async {
        await withCheckedContinuation { c in
            queue.async {
                self.diagnostics = []
                self.totalFramesDelivered = 0
                c.resume()
            }
        }
    }

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

    func startSession(on position: CameraPosition) async throws {
        let status = authorizationStatus()
        guard status == .authorized || status == .notDetermined else {
            throw status == .restricted ? CaptureError.restricted : CaptureError.permissionDenied
        }
        guard status == .authorized else { throw CaptureError.permissionDenied }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try configureSession(startingAt: position)
                    session.startRunning()
                    state = .running
                    c.resume()
                } catch {
                    state = .failed(Self.map(error, at: self.activePosition))
                    c.resume(throwing: Self.map(error, at: self.activePosition))
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
                    // Reopens on whichever camera is live, so a rebuild after a
                    // failed swap restores the camera the user was composing
                    // with rather than a default.
                    try configureSession(startingAt: activePosition)
                    session.startRunning()
                    state = .running
                    c.resume()
                } catch {
                    state = .failed(Self.map(error, at: self.activePosition))
                    c.resume(throwing: Self.map(error, at: self.activePosition))
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
                    c.resume(throwing: Self.map(error, at: self.activePosition))
                }
            }
        }
    }

    // MARK: - Capture

    /// Captures one photograph from the camera currently live.
    ///
    /// No position parameter, deliberately: the session is already on the
    /// camera the user is composing with, and accepting a position separately
    /// would let a caller ask for a camera that is not attached.
    func captureCurrentPhoto() async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard state == .running else {
                    continuation.resume(throwing: CaptureError.sessionReset)
                    return
                }
                let position = activePosition
                guard activeInput != nil else {
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

                // From the attached input, not a fresh device lookup — see
                // `photoSettings(for:device:)`.
                let settings = Self.photoSettings(for: position, device: activeInput?.device)

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

                // Deadline, for the same reason as the frame wait: the photo
                // delegate is an external callback and "normally prompt" is not
                // a guarantee. Without this, a delegate that never fires leaves
                // `photoWait` set, and every subsequent capture fails with
                // "a capture is already in flight" — the controller is then
                // permanently wedged rather than merely slow.
                queue.asyncAfter(deadline: .now() + Self.photoWaitTimeout) {
                    // Position identifies the wait: `photoWait` is only ever
                    // nil-or-mine while this capture is in flight, and a
                    // deadline firing after a later capture began must not
                    // steal that one.
                    guard let wait = self.photoWait, wait.position == position else { return }
                    self.photoWait = nil
                    self.pendingPhotoDelegate = nil
                    wait.continuation.resume(
                        throwing: CaptureError.photoDataUnavailable(position)
                    )
                }
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
                let armedAt = DispatchTime.now()
                self.frameWait = FrameWait(
                    generation: self.generation,
                    continuation: armed,
                    armedAt: armedAt
                )
                self.framesRejectedDuringWait = 0
                self.framesAtArmTime = self.totalFramesDelivered

                // The deadline, armed on the same queue as the wait and
                // resuming it exactly once. Whichever of frame or deadline
                // lands first clears `frameWait`, so the other becomes a no-op
                // rather than a double-resume. The `generation` check is what
                // distinguishes "my wait" from a later one: `frameWait` is only
                // ever nil-or-mine at this point, and a deadline that fires
                // after a *subsequent* wait was armed must not steal it.
                let armedGeneration = self.generation
                queue.asyncAfter(deadline: .now() + Self.frameWaitTimeout) {
                    guard let wait = self.frameWait,
                          wait.generation == armedGeneration
                    else { return }
                    self.frameWait = nil

                    // **The diagnostic that matters most.** A timeout here and a
                    // timeout caused by the port check rejecting every arriving
                    // frame are indistinguishable to the caller — both are
                    // `noDeliveredFrame` — and they have opposite fixes. So the
                    // rejection count is the whole point of this record.
                    self.record(FrameWaitOutcome(
                        target: self.activePosition,
                        from: self.positionBeforeSwap,
                        duration: self.seconds(since: wait.armedAt),
                        rejectedFrames: self.framesRejectedDuringWait,
                        framesSeen: self.totalFramesDelivered - self.framesAtArmTime,
                        timedOut: true
                    ))

                    wait.continuation.resume(throwing: CaptureError.noDeliveredFrame(
                        self.activePosition
                    ))
                }
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
            // **Counted before anything else, and counted unconditionally.** The
            // whole question is whether frames are arriving at all during a wait
            // that is timing out, so the count has to include frames that arrive
            // with no wait armed and frames that go on to be rejected. Anything
            // less and the measurement cannot answer its own question.
            self.totalFramesDelivered += 1

            guard let wait = self.frameWait, let input = self.activeInput else { return }
            guard let expectedPort = input.ports.first else {
                self.frameWait = nil
                self.record(FrameWaitOutcome(
                    target: self.activePosition,
                    from: self.positionBeforeSwap,
                    duration: self.seconds(since: wait.armedAt),
                    rejectedFrames: self.framesRejectedDuringWait,
                    framesSeen: self.totalFramesDelivered - self.framesAtArmTime,
                    timedOut: false
                ))
                // **`noInputAvailable`, not `noDeliveredFrame` — unchanged.** An
                // attached input with no ports is a missing camera, and the two
                // errors say different things to the user: one is "this phone has
                // no camera", the other is "the camera went quiet". Recording the
                // diagnostic here is worth it; quietly reclassifying the error is
                // not, and it is the kind of change that gets made while looking
                // for something else.
                wait.continuation.resume(throwing: CaptureError.noInputAvailable(
                    self.activePosition
                ))
                return
            }
            guard connection.inputPorts.contains(where: { $0 === expectedPort }) else {
                // A frame from the camera we just removed. Correctly ignored.
                //
                // **Counted, because "correctly" is a claim this diagnostic is
                // here to test.** If a swap into the back camera is failing
                // because every frame arrives on the wrong port, this counter is
                // what says so — and a handful of rejects is the healthy case,
                // since frames in flight at the swap always arrive late.
                self.framesRejectedDuringWait += 1
                return
            }
            self.frameWait = nil
            self.record(FrameWaitOutcome(
                target: self.activePosition,
                from: self.positionBeforeSwap,
                duration: self.seconds(since: wait.armedAt),
                rejectedFrames: self.framesRejectedDuringWait,
                framesSeen: self.totalFramesDelivered - self.framesAtArmTime,
                timedOut: false
            ))
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

    /// Builds inputs and outputs, opening on `position`. Must run on `queue`.
    private func configureSession(startingAt position: CameraPosition) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // `.inputPriority` rather than a preset: a preset is a hint the session
        // may reinterpret when inputs change, so the format in use after a swap
        // would not be the one that was asked for (TRD §5.3).
        session.sessionPreset = .inputPriority

        // Outputs are attached **once** and left alone.
        //
        // `stopSession` stops the session; it does not remove outputs, and
        // `AppEnvironment.captureService` is a single cached instance for the
        // life of the process. So this method runs again the *second* time the
        // camera screen is opened — and by then both outputs are already
        // attached, at which point `canAddOutput` returns **false** and the
        // guard below threw `configurationFailed("photo output rejected")`.
        //
        // The consequence in the field was that the camera worked exactly once
        // per app launch. A 20-iteration device loop found it on iteration 2;
        // no simulator test could, because the simulator has no camera and never
        // re-enters this path. The inputs were already handled correctly —
        // `attachInput` removes the outgoing one — so the asymmetry was
        // invisible until somebody counted sessions.
        try attach(photoOutput, rejection: "photo output rejected")
        try attach(videoOutput, rejection: "frame-signal output rejected")

        try attachInput(at: position)
        try applyFormat(for: activePosition)
    }

    /// Adds `output` to the session, unless it is already there.
    ///
    /// `session.outputs` is `[Any]`, so the containment check is an identity
    /// comparison rather than `Equatable` — these are the same objects, not
    /// equal values.
    private func attach(_ output: AVCaptureOutput, rejection: String) throws {
        let alreadyAttached = session.outputs.contains { ($0 as AnyObject) === output }
        guard !alreadyAttached else { return }

        guard session.canAddOutput(output) else {
            throw CaptureError.configurationFailed(rejection)
        }
        session.addOutput(output)
    }

    /// Opens and attaches the input for `position`. Must run on `queue`.
    private func attachInput(at position: CameraPosition) throws {
        guard let device = CaptureFormatSelector.wideAngleDevice(for: position) else {
            throw CaptureError.noInputAvailable(position)
        }
        let input = try AVCaptureDeviceInput(device: device)

        // Order established on hardware, and both arrangements fail loudly
        // enough to be worth recording.
        //
        // `canAddInput` must be evaluated **inside** the configuration block —
        // called while the session is running and outside
        // `beginConfiguration`, it returns NO for the front camera every time.
        //
        // It must be evaluated **after** the outgoing input is removed, too.
        // Checking first — the "leave the session untouched on refusal"
        // intuition — returns NO on every attempt, because a session already
        // holding one video input will not accept a second from a different
        // device. That version reported `noInputAvailable(.front)` twenty
        // times out of twenty.
        //
        // The cost of this order is that a refused add leaves the session with
        // no input. That is recoverable here because `capturePair` rebuilds the
        // session whenever a capture throws, so a refusal costs one failed
        // capture rather than the rest of the run.
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
            // The camera is present and open, it just cannot honour Memoree's
            // geometry. Failing loudly beats saving moments at the wrong aspect
            // ratio forever — and the distinct error keeps this from reading as
            // a missing camera, which is what it did once (ADR-019).
            throw CaptureError.noThreeByFourFormat(position)
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
                    // Remember where the swap came from, so a recorded wait can
                    // say `front->back` rather than just `back`. Read here,
                    // before `attachInput` overwrites `activePosition`.
                    self.positionBeforeSwap = self.activePosition
                    try attachInput(at: position)
                    try applyFormat(for: position)
                    c.resume()
                } catch {
                    c.resume(throwing: Self.map(error, at: self.activePosition))
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

    /// Builds photo settings from the input that is **actually attached**.
    ///
    /// The dimensions must come from the active input's `activeFormat`, not
    /// from a fresh device lookup. `maxPhotoDimensions` is documented as:
    /// "The dimensions set must match one of the dimensions returned by
    /// `AVCaptureDeviceFormat.supportedMaxPhotoDimensions` for the currently
    /// configured format." A second lookup returns a *different*
    /// `AVCaptureDevice` whose widest-3:4 format is not necessarily the one
    /// `applyFormat` put on the attached input — and when it is not, every
    /// capture fails with "Cannot Record". That is exactly what the first
    /// device run showed: iteration 1 succeeded, then all 19 after it failed.
    ///
    /// Left unset when the active format does not advertise these dimensions,
    /// so the output falls back to its own default rather than being handed an
    /// invalid request.
    private static func photoSettings(
        for position: CameraPosition,
        device: AVCaptureDevice?
    ) -> PhotoSettings {
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .speed

        guard let device,
              let activeFormat = device.formats.first(where: {
                  CaptureFormatSelector.matches(
                      CaptureFormatSelector.dimensions(of: $0),
                      CaptureFormatSelector.dimensions(of: device.activeFormat)
                  )
              })
        else {
            return PhotoSettings(
                settings: settings,
                dimensions: CMVideoDimensions(width: 0, height: 0)
            )
        }

        // The recorded dimensions are always the active format's, whether or
        // not the request is set — `CapturedPhoto.isThreeByFour` asserts on
        // them, and reporting zero for a format that was simply not eligible
        // for `maxPhotoDimensions` would fail a capture that actually
        // succeeded.
        let dimensions = CaptureFormatSelector.dimensions(of: activeFormat)

        // Only *request* these dimensions if the active format advertises them
        // as a supported max photo size. The format's own resolution and its
        // supported max photo dimensions are related but not identical.
        if activeFormat.supportedMaxPhotoDimensions.contains(where: {
            CaptureFormatSelector.matches($0, dimensions)
        }) {
            settings.maxPhotoDimensions = dimensions
        }

        return PhotoSettings(settings: settings, dimensions: dimensions)
    }

    // MARK: - Errors

    /// Normalises anything thrown inside the session into a `CaptureError`.
    ///
    /// - Parameter position: **The camera that was live when the error happened,
    ///   and it is passed in rather than defaulted.** `deviceNotConnected` maps
    ///   to `noInputAvailable(position)`, and an earlier version supplied
    ///   `CameraPosition.default` — which reported a missing camera as a *rear*
    ///   camera problem even when the front sensor had dropped. The two demand
    ///   different responses, and the archive keeps whichever one this names
    ///   forever. ADR-019 is the same mistake one layer down: a plausible default
    ///   standing in for a fact the hardware alone knows.
    static func map(_ error: Error, at position: CameraPosition) -> CaptureError {
        if let captureError = error as? CaptureError { return captureError }

        let nsError = error as NSError
        guard nsError.domain == AVFoundationErrorDomain else {
            // The domain and code are kept, not just the prose. "Cannot Record"
            // is the localized description Apple chose for more than one
            // underlying error, so a sentence that could have come from three
            // different causes is a sentence you cannot act on. The numbers can
            // be looked up.
            return .configurationFailed(
                "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
            )
        }

        switch nsError.code {
        case AVError.deviceInUseByAnotherApplication.rawValue:
            return .inUseByAnotherApp
        case AVError.deviceNotConnected.rawValue:
            return .noInputAvailable(position)
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
            // `position`, not the controller's live camera: this delegate was
            // created for one specific capture, and by the time the error
            // arrives that camera is the one that is actually broken.
            continuation.resume(
                throwing: CaptureSessionController.map(error, at: position)
            )
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
