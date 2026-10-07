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
    ///
    /// **Declared and never used.** Recorded rather than deleted: the stop path
    /// has the same unbounded shape as the start path, and someone thought about
    /// it once. `stopRunning()` is documented to block until the session stops, so
    /// this number has a job to do whenever that gets fixed.
    private static let stopTimeout: TimeInterval = 1.0

    /// How long to wait for `startRunning()` to return.
    ///
    /// ## Why this one is not like the other two
    ///
    /// `frameWaitTimeout` and `photoWaitTimeout` are both armed with
    /// `queue.asyncAfter` — **on the session queue** — because both wait for
    /// something that will hand the continuation back. That works: the queue is
    /// idle, and whichever of callback-or-deadline arrives first clears the
    /// pending slot and resumes it once.
    ///
    /// **`startRunning()` is not idle.** It *occupies* the session queue and
    /// blocks there. A deadline scheduled on that queue cannot run until
    /// `startRunning()` returns, which is precisely the case the deadline exists
    /// to catch. So this deadline is armed on a different queue and arbitrated by
    /// `ResumeGate` instead of by a queue-confined pending slot.
    ///
    /// ## The measurement, and why 5 seconds
    ///
    /// A device gate ran **eighteen minutes** without printing a summary.
    /// `startRunning()` against a wedged capture daemon never returned, and
    /// because it was holding the serial queue, every later capture operation
    /// queued behind it forever. The camera screen was not slow — it was
    /// permanently unresponsive, with no error and no way out.
    ///
    /// Five seconds is the frame wait's figure for the same measured reason: an
    /// idle swap-and-wait runs a median of 0.472s and a maximum of 0.815s across
    /// forty swaps on an iPhone 17, and a photo capture adds a little more. Six
    /// times the worst observation is not a number anyone tunes — it is a number
    /// chosen so that being wrong means the daemon is genuinely gone.
    private static let startTimeout: TimeInterval = 5.0

    /// The queue the start deadline runs on, because the session queue cannot.
    ///
    /// A single shared queue rather than a fresh one per call: a timer that has
    /// already fired does nothing, and these fire at most once per camera-screen
    /// opening. The alternative — `DispatchQueue.global()` — would put app work
    /// next to a five-second sleep on a shared thread, for no benefit.
    private static let startDeadlineQueue =
        DispatchQueue(label: "capture.start.deadline", qos: .userInitiated)

    // MARK: - Isolated state

    private let queue = DispatchQueue(label: CaptureSessionController.queueLabel)

    /// `var` only because `rebuildSession` replaces it wholesale when
    /// `mediaServicesWereReset` fires. Never reassigned anywhere else, and
    /// every access is on `queue` except the one documented on `previewSurface`.
    private var session = AVCaptureSession()

    private var photoOutput = AVCapturePhotoOutput()

    /// Frame signal only. Its pixel buffers are counted, never read.
    /// Replaced wholesale by `rebuildSession`, because an output cannot be
    /// moved between sessions — see there. `var` for that reason alone.
    private var videoOutput = AVCaptureVideoDataOutput()

    /// The Behind-the-Scenes output, when BTS is on. `nil` when it is off.
    ///
    /// ## Attached once and left alone, like the other outputs
    ///
    /// Not added and removed per capture. Session churn is the thing this phase
    /// has already measured as dangerous — 40 swaps in six minutes is what the
    /// capture daemon does not survive — and a movie output that came and went
    /// with each moment would be the most churn of anything in the file.
    ///
    /// So BTS being *on* attaches it for the session's life, and turning BTS off
    /// means it was never there. `SessionRebuildInvariantTests` fails the build if
    /// `rebuildSession` does not replace it, because that is the exact defect
    /// this file shipped once already with `videoOutput`.
    private var movieOutput: AVCaptureMovieFileOutput?

    /// Whether BTS has asked for a movie output on this session.
    ///
    /// Set once, before the session is configured, and read by
    /// `configureSession`. **A `var` and not a parameter** because the session is
    /// configured in six places and threading a flag through all of them is how
    /// the "camera works exactly once per launch" defect happened.
    private var wantsMovieOutput = false

    /// Asks for a Behind-the-Scenes output, for sessions started after this call.
    ///
    /// **Call before `startSession`.** It configures *future* sessions rather
    /// than mutating a running one, because attaching an output to a running
    /// session means another `beginConfiguration` cycle — more churn, on the one
    /// subsystem this project has measured as fragile.
    func enableMovieOutput() async {
        await withCheckedContinuation { c in
            queue.async {
                self.wantsMovieOutput = true
                c.resume()
            }
        }
    }

    /// The movie output, once a session has been configured with one.
    ///
    /// **`nil` until `enableMovieOutput` has been called *and* a session has been
    /// configured**, and reading it is how `LiveBTSRecorder` tells the difference
    /// between "BTS is off" and "BTS is on and the output failed to attach".
    var movieFileOutput: AVCaptureMovieFileOutput? {
        movieOutput
    }

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

    /// How many times `rebuildSession()` has run. Diagnostic only — see
    /// `sessionRebuildCount()`. Confined to `queue` like everything else here.
    private var rebuilds = 0

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
    /// `framesSeen` settled the first question — the output delivers *nothing*,
    /// it is not being missed. The fields below settle the second, and the one
    /// that matters is `sessionWasRunning`.
    ///
    /// ## The three causes, and which field separates them
    ///
    /// All three look identical from outside: `seen=0`, deadline, `noDeliveredFrame`.
    ///
    /// - **AVFoundation parked the session.** It thinks it is running and is not
    ///   calling us. `sessionWasRunning == true`, `framesSinceLast > 0`.
    /// - **The session really stopped.** `sessionWasRunning == false`. The fix is
    ///   to restart it, which is cheap and already proven to work.
    /// - **Frames arrive but the delegate is never called.** A stale connection
    ///   after the reconfiguration, so the hardware is fine and nothing fires.
    ///   `sessionWasRunning == true`, but `framesSinceLast` is *also* large —
    ///   which looks like the first case, and is the reason the connection check
    ///   below exists.
    ///
    /// `connectionIsLive` is what distinguishes the first from the third: after a
    /// reconfiguration the output's connection object can be replaced, and a
    /// delegate bound to the old one is never called again while the session
    /// happily reports itself as running. **That failure is invisible from
    /// `isRunning` alone**, which is why it gets its own field rather than being
    /// folded into the session state.
    struct FrameWaitOutcome: CustomStringConvertible {
        let target: CameraPosition
        let from: CameraPosition
        let duration: TimeInterval
        /// Frames the port check refused.
        let rejectedFrames: Int
        /// Frames that arrived *at all* during the wait, including rejects.
        let framesSeen: Int
        let timedOut: Bool

        /// `AVCaptureSession.isRunning` when the wait completed.
        let sessionWasRunning: Bool
        /// Seconds since *any* frame last arrived — not just during this wait.
        ///
        /// **The field that dates the stall.** If this is much larger than
        /// `duration`, the output had already gone quiet before this swap began,
        /// which moves the cause somewhere else entirely.
        let framesSinceLast: TimeInterval
        /// Whether the video output still has a usable video connection.
        let connectionIsLive: Bool
        /// How many inputs the session holds when the wait completed.
        let inputCount: Int

        var description: String {
            let outcome = timedOut ? "TIMEOUT" : "ok"
            var line = "\(from.rawValue)->\(target.rawValue) \(outcome) "
                + String(format: "%.3fs", duration)
                + " seen=\(framesSeen)"
            if timedOut {
                // Only the failure rows carry the state, because that is all they
                // are for — a wall of `isRunning=true` on nineteen healthy rows
                // is noise that hides the one row that matters.
                line += " running=\(sessionWasRunning)"
                    + " idle=\(String(format: "%.2fs", framesSinceLast))"
                    + " connLive=\(connectionIsLive)"
                    + " inputs=\(inputCount)"
            }
            if rejectedFrames > 0 { line += " rejected=\(rejectedFrames)" }
            return line
        }
    }

    /// When a frame last arrived at all, on any queue. Sampled inside
    /// `deliverFrame`, so it is the honest "last time the hardware spoke" rather
    /// than "last time a wait was satisfied".
    private var lastFrameAt: DispatchTime?

    /// The state fields, sampled once on `queue` so they agree with each other.
    private func snapshot(_ wait: FrameWait) -> FrameWaitOutcome {
        FrameWaitOutcome(
            target: activePosition,
            from: positionBeforeSwap,
            duration: seconds(since: wait.armedAt),
            rejectedFrames: framesRejectedDuringWait,
            framesSeen: totalFramesDelivered - framesAtArmTime,
            timedOut: false,
            sessionWasRunning: session.isRunning,
            framesSinceLast: lastFrameAt.map { seconds(since: $0) } ?? -1,
            connectionIsLive: videoOutput.connection(with: .video) != nil,
            inputCount: session.inputs.count
        )
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

    /// How many times the session has been destroyed and rebuilt.
    ///
    /// **On the controller rather than counted by the caller**, because two
    /// callers rebuild for two different reasons and a gate that needs to know
    /// whether the recovery fired cannot otherwise tell an intended rebuild from
    /// an accidental one. `SequentialCaptureService` rebuilds on a failed swap
    /// and, since the capture-path fix, on a dead subsystem — so "the camera
    /// recovered" and "the camera was rebuilt twice for one failure" are
    /// different facts and only the controller can distinguish them.
    func sessionRebuildCount() async -> Int {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.rebuilds) }
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

    private var sessionObservers: [NSObjectProtocol] = []

    deinit {
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

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

        sessionObservers = [
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: nil,
                queue: nil
            ) { [weak self] note in
                guard let self else { return }
                self.queue.async {
                    guard (note.object as? AVCaptureSession) === self.session else { return }
                    if self.state == .running {
                        self.state = .interrupted
                    }
                }
            },
            NotificationCenter.default.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: nil,
                queue: nil
            ) { [weak self] note in
                guard let self else { return }
                self.queue.async {
                    guard (note.object as? AVCaptureSession) === self.session else { return }
                    if self.state == .interrupted {
                        self.state = .running
                    }
                }
            }
        ]
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

        let gate = ResumeGate()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // **Armed before the queue is asked to do anything**, so the deadline
            // is already counting while `configureSession` runs. A gate armed
            // inside the queue closure could not fire until `startRunning()`
            // returned — which is the case it exists to catch.
            gate.arm(
                c,
                timeout: Self.startTimeout,
                on: Self.startDeadlineQueue,
                timeoutError: {
                    CaptureError.configurationFailed(
                        "the camera did not start within \(Int(Self.startTimeout)) seconds"
                    )
                }
            )

            queue.async { [self] in
                do {
                    try configureSession(startingAt: position)
                    session.startRunning()
                    state = .running
                    gate.succeed()
                } catch {
                    state = .failed(Self.map(error, at: self.activePosition))
                    gate.fail(with: Self.map(error, at: self.activePosition))
                }
            }
        }
    }

    func stopSession() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                session.stopRunning()
                state = .idle
                if let wait = self.frameWait {
                    self.frameWait = nil
                    wait.continuation.resume(throwing: CaptureError.sessionReset)
                }
                if let photoWait = self.photoWait {
                    let delegate = self.pendingPhotoDelegate
                    self.photoWait = nil
                    self.pendingPhotoDelegate = nil
                    delegate?.cancel(with: CaptureError.sessionReset)
                }
                // **The coordinator and its observations are torn down with the
                // session.** They hold the device, and the camera screen is a
                // cover that opens and closes constantly — leaving a coordinator
                // alive per opening is a leak per opening, and a live one that
                // still rotates connections belonging to a stopped session.
                self.removeRotationObservations()
                self.rotationCoordinator = nil
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
                rebuilds += 1
                if let wait = self.frameWait {
                    self.frameWait = nil
                    wait.continuation.resume(throwing: CaptureError.sessionReset)
                }
                if let photoWait = self.photoWait {
                    let delegate = self.pendingPhotoDelegate
                    self.photoWait = nil
                    self.pendingPhotoDelegate = nil
                    delegate?.cancel(with: CaptureError.sessionReset)
                }
                // Detach the preview from the doomed session before dropping it,
                // or the layer keeps a strong reference to a dead object.
                previewSurface.session = nil

                let replacement = AVCaptureSession()
                previewSurface.session = replacement

                // The old session is unreachable once this returns; every
                // output, input and continuation it owned goes with it.
                session = replacement

                // **Both outputs are replaced, and an output cannot be migrated
                // between sessions.**
                //
                // `photoOutput` was always rebuilt here and `videoOutput` was not,
                // which looked like an oversight and behaved like one. The
                // frame-signal output stayed attached to the doomed session, so
                // `canAddOutput` on the replacement returned **false** — and
                // because nothing ever replaced the object, every subsequent
                // `configureSession` threw `frame-signal output rejected` for the
                // life of the process. One dead capture subsystem turned into a
                // permanently bricked camera, which is precisely the failure
                // `rebuildSession` exists to end.
                //
                // **Found by a device gate at 8/20**, on the run where the daemon
                // dropped twice and so rebuilt twice: the first rebuild worked, the
                // second left the camera dead in a different way. An
                // `AVCaptureOutput` belongs to exactly one session for its whole
                // life; replacing the session means replacing everything attached
                // to it.
                photoOutput = AVCapturePhotoOutput()
                videoOutput = AVCaptureVideoDataOutput()
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(
                    self, queue: DispatchQueue(label: "capture.frames")
                )
                // **The movie output too, and this is the third time this shape
                // has bitten.** An output cannot be migrated between sessions: the
                // old one stays attached to the doomed session, `canAddOutput`
                // returns false on the replacement, and every later
                // `configureSession` throws for the life of the process. It cost a
                // 20-moment device run to find with `videoOutput` — which is why
                // `SessionRebuildInvariantTests` now names every output the
                // controller owns rather than the one that happened to break.
                movieOutput = nil
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
                    let delegate = self.pendingPhotoDelegate
                    self.photoWait = nil
                    self.pendingPhotoDelegate = nil
                    delegate?.cancel(with: CaptureError.photoDataUnavailable(position))
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
                    // `timedOut: true`, and the state snapshot taken **here** —
                    // at the deadline, on `queue`, while the session is in
                    // whatever state it stalled in. Sampling it later would
                    // sample a session something else has already touched.
                    var row = self.snapshot(wait)
                    row = FrameWaitOutcome(
                        target: row.target,
                        from: row.from,
                        duration: row.duration,
                        rejectedFrames: row.rejectedFrames,
                        framesSeen: row.framesSeen,
                        timedOut: true,
                        sessionWasRunning: row.sessionWasRunning,
                        framesSinceLast: row.framesSinceLast,
                        connectionIsLive: row.connectionIsLive,
                        inputCount: row.inputCount
                    )
                    self.record(row)

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
            // Stamped unconditionally, for the same reason: `framesSinceLast` is
            // only meaningful if it records every frame, including ones with no
            // wait armed and ones that go on to be rejected.
            self.lastFrameAt = DispatchTime.now()

            guard let wait = self.frameWait, let input = self.activeInput else { return }
            guard let expectedPort = input.ports.first(where: { $0.mediaType == .video }) ?? input.ports.first else {
                self.frameWait = nil
                self.record(self.snapshot(wait))
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
            self.record(self.snapshot(wait))
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

        // **Created here rather than stored, so a rebuilt session gets a new
        // one.** An `AVCaptureOutput` belongs to exactly one session for its whole
        // life — the defect `rebuildSession` shipped once with `videoOutput`, and
        // the invariant that now catches it names this output too.
        if wantsMovieOutput, movieOutput == nil {
            movieOutput = AVCaptureMovieFileOutput()
        }
        if let movieOutput {
            try attach(movieOutput, rejection: "movie output rejected")
        }

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

    /// The device to open for `position` at `zoom`.
    ///
    /// ## Rear: one virtual device for the whole range
    ///
    /// **The rear's 0.5×, 1× and 2× are all the same physical input** — the
    /// virtual dual-wide device, with `videoZoomFactor` selecting among them. So
    /// changing the rear's zoom never touches the session graph.
    ///
    /// ## Front: 0.5× is a different lens
    ///
    /// **There is no virtual device at the front** — the device survey found
    /// `.builtInDualWideCamera` only at the back — so front 0.5× attaches the
    /// front's ultra-wide lens, and 1× attaches the front's wide one. That is a
    /// `removeInput`/`addInput` pair, which is the stop-reconfigure-start cycle
    /// ADR-003 measured. `CameraZoom.requiresItsOwnDevice(on:)` is what tells the
    /// caller this is not a cheap write.
    ///
    /// ## Every fallback is checked for 3:4 rather than assumed
    ///
    /// It is the same question `applyFormat` is about to ask anyway, and answering
    /// it here means a phone without one of these devices opens *something* rather
    /// than reporting `noInputAvailable` — the error that once sent the diagnosis
    /// towards permissions and hardware instead of towards the ratio.
    static func captureDevice(
        for position: CameraPosition,
        zoom: CameraZoom
    ) -> AVCaptureDevice? {
        if position == .front {
            let type: AVCaptureDevice.DeviceType = zoom.requiresItsOwnDevice(on: position)
                ? .builtInUltraWideCamera
                : .builtInWideAngleCamera
            let device = AVCaptureDevice.default(type, for: .video, position: .front)
            if let device, CaptureFormatSelector.selectFormat(for: device) != nil {
                return device
            }
            return CaptureFormatSelector.wideAngleDevice(for: position)
        }

        let dualWide = AVCaptureDevice.default(
            .builtInDualWideCamera,
            for: .video,
            position: .back
        )
        if let dualWide, CaptureFormatSelector.selectFormat(for: dualWide) != nil {
            return dualWide
        }
        return CaptureFormatSelector.wideAngleDevice(for: position)
    }

    /// Opens and attaches the input for `position`. Must run on `queue`.
    ///
    /// ## The rear attaches a **virtual dual-wide device**, not a lens
    ///
    /// A device survey measured the two facts the zoom control rests on: every
    /// lens offers 3:4, and `.builtInDualWideCamera` reports a **switch-over
    /// factor at 2.00** — the zoom at which AVFoundation hands off from the
    /// ultra-wide to the wide camera on its own.
    ///
    /// So all three zoom buttons are one `videoZoomFactor` write and **no session
    /// restart at all**. That is the entire reason for a virtual device rather than
    /// three physical lenses: switching lenses the obvious way is
    /// `removeInput`/`addInput` on a running session, which is exactly the
    /// operation ADR-003 measured four times to be the thing that leaves the frame
    /// output dead. Zoom must not add another instance of it mid-moment.
    ///
    /// **The front keeps a single physical lens**, because there is only one, and
    /// a virtual device there would add cost and a failure surface for no reach.
    ///
    /// Falls back to the wide lens if the virtual device reports no 3:4 format,
    /// so a phone without one still captures rather than failing.
    private func attachInput(at position: CameraPosition) throws {
        guard let device = Self.captureDevice(for: position, zoom: currentZoom) else {
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
        // **What was actually attached**, not what was asked for — the fallback
        // above may have substituted the wide lens for an absent ultra-wide, and
        // a later zoom must compare against reality rather than intent.
        attachedLens = (position == .front && device.deviceType == .builtInUltraWideCamera)
            ? .ultraWide
            : nil
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
        configureRotationCoordinator()
        // **Zoom is reapplied here, not just on a button press.** The input has
        // just been rebuilt and comes back at 1.0, so a user who chose 0.5× would
        // otherwise get a wide photograph for one half of their moment.
        try? applyZoomOnDevice(currentZoom)
    }

    // MARK: - Focus

    /// Moves focus and exposure to a tapped point.
    ///
    /// ## The conversion happens here and nowhere else
    ///
    /// The caller has a point in **view** coordinates, 0…1. Turning that into a
    /// sensor point needs `captureDevicePointConverted(fromLayerPoint:)` on the
    /// preview layer, and `Features/` cannot import AVFoundation (`AGENTS.md`
    /// §3). So the service owns the whole conversion, which is why the protocol
    /// takes a normalised point rather than a device point.
    ///
    /// **Focus and exposure are set together**, as the stock camera does, because
    /// a tap that focuses but does not expose produces a correctly-focused photo
    /// of the wrong brightness, which reads as a focus bug rather than as two
    /// decisions.
    func focus(atNormalizedPoint point: CGPoint) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { c.resume() }
                guard let device = activeInput?.device else { return }

                // A zero-sized preview would divide by zero and produce a NaN
                // point, which AVFoundation rejects by throwing.
                let size = previewSurface.bounds.size
                guard size.width > 0, size.height > 0 else { return }

                let layerPoint = CGPoint(x: point.x * size.width, y: point.y * size.height)
                let devicePoint = previewSurface
                    .captureDevicePointConverted(fromLayerPoint: layerPoint)

                guard device.isFocusPointOfInterestSupported
                        || device.isExposurePointOfInterestSupported
                else { return }

                do {
                    try device.lockForConfiguration()
                } catch {
                    // **Never unlocked here.** A failed lock means we do not hold
                    // it, and unlocking a device we never locked is how a
                    // configuration deadlock starts.
                    return
                }
                defer { device.unlockForConfiguration() }

                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    // `.autoFocus` rather than continuous: a tap is a request to
                    // focus *there*, and a one-shot lock is what stops the camera
                    // immediately drifting back off the subject.
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    // MARK: - Zoom

    /// The zoom the user chose, kept across the front↔rear swap.
    ///
    /// **Remembered rather than reapplied, because the swap is invisible to it.**
    /// ADR-021 tears the input down and rebuilds it between the two shutter
    /// presses, and a device comes back at 1.0. Without this, a user who picked
    /// 0.5× gets two photographs of one moment at two different framings, and the
    /// composite puts them side by side — which reads as a rendering bug rather
    /// than as zoom resetting.
    private var currentZoom: CameraZoom = .wide

    /// Which lens is physically attached right now, or `nil` for the rear.
    ///
    /// **Only the front ever has a value**, because only the front changes lens
    /// with zoom — the rear is one virtual device for its whole range. It is set
    /// in `attachInput`, which is the only place that knows which device it
    /// actually attached rather than which one it asked for.
    ///
    /// Queue-confined, like everything else here.
    private var attachedLens: CameraZoom?

    /// Applies a zoom, and remembers it.
    ///
    /// ## Two costs, and which one you pay depends on the camera
    ///
    /// **The rear is a property write.** Every rear zoom is the same virtual
    /// dual-wide input with a different `videoZoomFactor`, so this is one line
    /// under `lockForConfiguration` and the frame output is never touched.
    ///
    /// **The front's 0.5× is a lens change.** There is no virtual device at the
    /// front, so this is `stopRunning` → `removeInput` → `addInput` →
    /// `startRunning` → wait for a delivered frame — the same cycle as the
    /// front↔rear swap, which is the *known-good* shape. **Reconfiguring while
    /// running is the one that kills the frame output**, so this deliberately
    /// stops first.
    ///
    /// ## Refuses rather than clamps
    ///
    /// 2× does not exist on the front, and pressing a button that cannot work
    /// should do nothing rather than quietly become 1×.
    func applyZoom(_ zoom: CameraZoom) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard zoom.isAvailable(on: activePosition) else {
                    c.resume(throwing: CaptureError.zoomUnavailable(zoom, activePosition))
                    return
                }

                // The rear is never here: it is one virtual device for its whole
                // range, so every rear zoom is a property write.
                let needsNewLens = zoom.requiresItsOwnDevice(on: activePosition)
                    && attachedLens != zoom
                    && activeInput != nil
                currentZoom = zoom

                do {
                    if needsNewLens {
                        // **Stopped first**, like every other reconfiguration
                        // here. The frame output dies if this runs while running.
                        session.stopRunning()
                        try attachInput(at: activePosition)
                        try applyFormat(for: activePosition)
                        session.startRunning()
                    } else {
                        try applyZoomOnDevice(zoom)
                    }
                    c.resume()
                } catch {
                    // Leave the session running whatever happened, so a refused
                    // zoom cannot present a frozen preview with no error.
                    if state == .running { session.startRunning() }
                    c.resume(throwing: Self.map(error, at: self.activePosition))
                }
            }
        }
    }

    /// Writes `videoZoomFactor` under `lockForConfiguration`.
    ///
    /// **The one place zoom touches the device**, and it is deliberately not
    /// `session.beginConfiguration()`: a zoom change is a device property, not a
    /// session graph change, and reconfiguring a *running* session is what
    /// ADR-003 measured to be fatal to the frame output.
    private func applyZoomOnDevice(_ zoom: CameraZoom) throws {
        guard let device = activeInput?.device else { return }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        // **Clamped to the format's own ceiling**, which is per-format rather than
        // per-device and therefore has to be read *after* `activeFormat` is set.
        // The device survey measured a ceiling of 189× on the rear, so an
        // unclamped write would be accepted by AVFoundation and produce a
        // rectangle of pixels.
        let ceiling = device.activeFormat.videoMaxZoomFactor
        // A virtual dual-wide camera's 1.0 is its ultra-wide lens, so wide 1x sits
        // at 2.0 (virtualDeviceZoomFactor). On front cameras and single-lens devices,
        // 1.0 is already native 1x, so applying 2.0 was a 2x digital zoom crop.
        let requested: CGFloat
        if device.deviceType == .builtInDualWideCamera {
            requested = zoom.virtualDeviceZoomFactor
        } else {
            requested = zoom.factor
        }
        device.videoZoomFactor = min(max(requested, device.minAvailableVideoZoomFactor), ceiling)
    }

    /// The zoom in force, for the buttons and for tests.
    func currentCameraZoom() async -> CameraZoom {
        await withCheckedContinuation { (c: CheckedContinuation<CameraZoom, Never>) in
            queue.async { [self] in c.resume(returning: currentZoom) }
        }
    }

    // MARK: - Orientation

    /// The rotation currently applied to both connections, or `nil` if none has been.
    ///
    /// Read and written only on `queue`. `nil` is a real answer meaning "the
    /// connections are exactly as AVFoundation set them", and it is what
    /// `currentRotation()` reports before a coordinator exists.
    private var appliedOrientation: CaptureOrientation?

    /// AVFoundation's own answer to "how far is the phone turned".
    ///
    /// ## Why this and not a table
    ///
    /// The first version kept a hand-written table from `UIDevice.orientation` to
    /// an angle. **It did not work**, and the reason is the kind that no amount of
    /// careful table-writing can fix: `UIDevice.orientation` returns `.portrait`
    /// *forever* when the user has rotation lock on. Every sideways photograph was
    /// therefore given a quarter turn and saved as a portrait one — which is
    /// exactly the bug this replaced.
    ///
    /// `AVCaptureDevice.RotationCoordinator` reads the device's **physical**
    /// orientation and returns an angle relative to gravity, so it is correct
    /// regardless of the rotation lock, and it knows each model's sensor mounting
    /// rather than assuming one.
    ///
    /// ## Why it is rebuilt on every input swap
    ///
    /// **A coordinator belongs to one `AVCaptureDevice`.** ADR-021 swaps the input
    /// mid-moment, and a coordinator watching the old device keeps reporting the
    /// old sensor's angles — so the front camera would be rotated by the rear's
    /// mounting. It is torn down and rebuilt with the new one, and the observer is
    /// moved with it.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    /// Key-value observations on the coordinator's two angles.
    ///
    /// **Removed before a new coordinator is observed**, or every swap leaks a
    /// pair of observations on a coordinator that is still alive somewhere. The
    /// coordinator is not retained by the observation, so the leak is in the
    /// observation itself and grows with every shutter press.
    private var rotationObservations: [NSKeyValueObservation] = []

    /// Rebuilds the rotation coordinator for the attached device and observes it.
    ///
    /// Runs on `queue`. The coordinator is constructed here rather than reused,
    /// because the device it watches is the one that just changed.
    private func configureRotationCoordinator() {
        removeRotationObservations()

        // ## **No `state` check here, and that was the bug.**
        //
        // This briefly guarded on `state == .running`, on the reasoning that a
        // coordinator belongs to a live session. It does — but the only call site
        // is inside `configureSession`, which runs **before** `startRunning()` and
        // before `state` is set. So the guard failed every single time, no
        // coordinator was ever created, and `configureOrientation` fell back to
        // its start-up quarter turn.
        //
        // **A permanent quarter turn on every photograph.** Which makes a portrait
        // shot come out right — a landscape sensor buffer rotated a quarter turn
        // *is* a portrait image — and a landscape shot come out wrong, since it
        // needs no rotation at all. That is precisely the symptom, and it
        // survived two rounds of fixing the plumbing because the plumbing was
        // never reached.
        //
        // A coordinator watching a device before `startRunning()` is harmless: it
        // reads the device, not the session.
        guard let device = activeInput?.device else {
            rotationCoordinator = nil
            return
        }

        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            // The preview layer is passed so the coordinator can compute a
            // *preview* angle, which is not the capture angle: the layer's own
            // aspect and the sensor's differ.
            previewLayer: previewSurface
        )
        rotationCoordinator = coordinator

        // AVFoundation notifies on the main queue. This class is queue-confined
        // and must never be touched from there, so every update hops. The hop is
        // the whole reason the observation is not simply `configureOrientation`.
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                options: [.new]) { [weak self] _, _ in
                self?.rotationCoordinatorDidUpdate()
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                options: [.new]) { [weak self] _, _ in
                self?.rotationCoordinatorDidUpdate()
            }
        ]

        // Applied once immediately. The coordinator's first value can arrive a
        // moment after construction, and a session that opened sideways would
        // otherwise save its first photograph unrotated.
        configureOrientation()
    }

    private func rotationCoordinatorDidUpdate() {
        queue.async { [weak self] in self?.configureOrientation() }
    }

    private func removeRotationObservations() {
        rotationObservations.forEach { $0.invalidate() }
        rotationObservations.removeAll()
    }

    /// Applies the coordinator's current angles to both connections.
    ///
    /// Runs on `queue`, like every other configuration call (`AGENTS.md` §5).
    ///
    /// **Both connections, every time.** Neither had an orientation set at all
    /// before this, so both sat at the AVFoundation default and every photograph
    /// was saved in the sensor's native landscape regardless of how it was held.
    ///
    /// Called from three places, because each covers a case the others do not:
    /// session start (so the *first* frame is right rather than visibly
    /// rotating), every input swap (the connections are new objects back at the
    /// default), and every coordinator update while live.
    private func configureOrientation() {
        // **No coordinator means apply nothing — not a default.**
        //
        // The first version fell back to a portrait quarter turn, on the reasoning
        // that a wrong rotation is worse than a missing one. It is the other way
        // round: a *missing* rotation leaves the photograph in the sensor's native
        // orientation, which is a real, self-consistent image, while a *wrong*
        // rotation is a photograph that displays as something the user never
        // photographed. And "apply nothing" is exactly the state the app shipped
        // in for its whole life, which is a known quantity.
        //
        // This is the same mistake as defaulting `lastReportedOrientation` to
        // `.portrait`: asserting a rotation nobody asked for, in a place where
        // nothing can notice it being wrong.
        guard let coordinator = rotationCoordinator else { return }
        configureOrientation(CaptureOrientation(
            previewAngle: coordinator.videoRotationAngleForHorizonLevelPreview,
            captureAngle: coordinator.videoRotationAngleForHorizonLevelCapture
        ))
    }

    /// Applies specific angles, skipping any the connection will not accept.
    ///
    /// `isVideoRotationAngleSupported` is checked rather than assumed: setting an
    /// unsupported angle throws `NSInvalidArgumentException`, which is a crash,
    /// and only 0/90/180/270 are ever legal. A connection that refuses one is
    /// left alone rather than taking the whole camera down over a preview.
    private func configureOrientation(_ orientation: CaptureOrientation) {
        guard CaptureOrientation.isSupported(orientation.previewAngle),
              CaptureOrientation.isSupported(orientation.captureAngle)
        else { return }

        if let previewConnection = previewSurface.connection,
           previewConnection.isVideoRotationAngleSupported(orientation.previewAngle) {
            previewConnection.videoRotationAngle = orientation.previewAngle
        }
        if let photoConnection = photoOutput.connection(with: .video),
           photoConnection.isVideoRotationAngleSupported(orientation.captureAngle) {
            photoConnection.videoRotationAngle = orientation.captureAngle
        }
        if let movieConnection = movieOutput?.connection(with: .video) {
            if movieConnection.isVideoRotationAngleSupported(orientation.captureAngle) {
                movieConnection.videoRotationAngle = orientation.captureAngle
            } else if movieConnection.isVideoOrientationSupported {
                switch orientation.captureAngle {
                case 90:  movieConnection.videoOrientation = .portrait
                case 180: movieConnection.videoOrientation = .landscapeLeft
                case 270: movieConnection.videoOrientation = .portraitUpsideDown
                default:  movieConnection.videoOrientation = .landscapeRight
                }
            }
        }

        appliedOrientation = orientation
    }

    /// The rotation in force, for diagnostics and for the tests that assert on it.
    ///
    /// **Also hops.** `appliedOrientation` is written on `queue` by
    /// `configureOrientation`, and a computed property reading it from the caller
    /// would be a race against a camera swap — the one thing in this class that
    /// is not allowed, and the reason the whole type is queue-confined rather
    /// than lock-guarded.
    func currentOrientation() async -> CaptureOrientation? {
        await withCheckedContinuation { (c: CheckedContinuation<CaptureOrientation?, Never>) in
            queue.async { [self] in c.resume(returning: appliedOrientation) }
        }
    }

    /// Swaps the attached input to `position` and waits for it to deliver.
    ///
    /// **Step 7 of docs/TRD.md §5.2, and the one that is not optional.**
    /// Capturing before the new sensor has delivered a frame yields a black or
    /// green image. The wait is a real frame signal, not a sleep.
    ///
    /// ## The session is stopped, reconfigured, and restarted
    ///
    /// **Not because that is the safe way to do it in general — because it is the
    /// only way that has ever worked here, and that was measured four times.**
    ///
    /// The gate ran 16/20, then 1/20, then 6/20, then 14 waits with 3 timeouts.
    /// The instrumented run settled what a timeout means: **`seen=0`, every time.**
    /// Zero frames delivered in five full seconds, while healthy waits were
    /// satisfied by the *first* frame in 2-27ms. Not a slow sensor and not a
    /// matching bug — the video output simply stopped.
    ///
    /// Every failure was the swap path. `startSession` has never failed, and the
    /// difference between the two is exactly one thing: **`startSession` configures
    /// before `startRunning`, and the swap configured while running.** Reconfiguring
    /// a running `AVCaptureSession` is what leaves the output dead, and it leaves it
    /// dead in a way `rebuildSession` does not recover — one run spent its last five
    /// moments failing with `configurationFailed("frame-signal output rejected")`.
    ///
    /// So this now does the same sequence that works: stop, reconfigure, restart.
    /// The cost is the restart latency, roughly 0.3-1.0s, which is invisible to
    /// someone composing a photograph and is the right trade against a swap that
    /// silently stops the camera working.
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

                    // **Stopped first.** Both calls block, and both are on
                    // `queue` — never the main thread (AGENTS.md §5).
                    session.stopRunning()
                    try attachInput(at: position)
                    try applyFormat(for: position)
                    session.startRunning()

                    c.resume()
                } catch {
                    // A throw between stop and start leaves the session stopped.
                    // Bring it back rather than leaving the preview frozen with
                    // no error, which is the failure mode `mediaServicesWereReset`
                    // produces and the one thing the app must never do (TRD §5.5).
                    if state == .running { session.startRunning() }
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
        if let photoConnection = photoOutput.connection(with: .video),
           photoConnection.isVideoMirroringSupported {
            photoConnection.isVideoMirrored = (position == .front)
        }
        if let movieConnection = movieOutput?.connection(with: .video),
           movieConnection.isVideoMirroringSupported {
            movieConnection.isVideoMirrored = (position == .front)
        }
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

    /// Cancels the in-flight capture with an error, ensuring the continuation
    /// is resumed exactly once even if the delegate callback races against it.
    func cancel(with error: Error) {
        lock.lock()
        let alreadyResumed = hasResumed
        hasResumed = true
        lock.unlock()

        guard !alreadyResumed else { return }
        defer { completion() }
        continuation.resume(throwing: error)
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

// MARK: - Resume gate

/// Resumes exactly one continuation, whichever of two paths arrives first.
///
/// ## Why this exists rather than a pending slot
///
/// Every other wait in this file is arbitrated by a slot on the session queue,
/// which works because the queue is free to run the deadline. `startRunning()` is
/// not — it is *running on* that queue — so its two completion paths are on
/// **different queues** and cannot share one. That makes this a genuine
/// cross-queue race, and a `CheckedContinuation` resumed twice traps.
///
/// ## `@unchecked Sendable`, and why a lock rather than a queue
///
/// Confinement is an `NSLock` because the two racing paths do not share a queue
/// to be confined to. Every mutable field is guarded by it, and the only thing
/// handed out is a `CheckedContinuation`, which is safe to resume once. This is
/// the shape `AGENTS.md` §5 asks for — one primitive owning all the mutable
/// state, with the reason written down rather than implied.
final class ResumeGate: @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var isSettled = false

    /// Takes the continuation and arms the timeout.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait.
    ///   - queue: **Must not be the session queue.** Arming there defeats the
    ///     entire purpose — see `startTimeout`.
    ///   - error: Built only if the deadline actually fires, so the common path
    ///     allocates nothing.
    func arm(
        _ continuation: CheckedContinuation<Void, Error>,
        timeout: TimeInterval,
        on queue: DispatchQueue,
        timeoutError error: @escaping @Sendable () -> Error
    ) {
        lock.lock()
        precondition(!isSettled, "a resume gate is armed once")
        self.continuation = continuation
        lock.unlock()

        queue.asyncAfter(deadline: .now() + timeout) { [self] in
            fail(with: error())
        }
    }

    /// The work completed.
    func succeed() {
        settle(with: .success(()))
    }

    /// The work failed with `error`.
    func fail(with error: Error) {
        settle(with: .failure(error))
    }

    private func settle(with result: Result<Void, Error>) {
        lock.lock()
        // **Exactly once, and this check is the entire type.** The two paths race
        // by construction — the common case is that the deadline fires a moment
        // after the work returned — and resuming a continuation twice traps.
        guard !isSettled, let continuation else {
            lock.unlock()
            return
        }
        isSettled = true
        self.continuation = nil
        lock.unlock()

        continuation.resume(with: result)
    }
}
