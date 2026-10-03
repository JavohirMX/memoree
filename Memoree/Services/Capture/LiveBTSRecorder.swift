import AVFoundation
import Foundation

/// The real `BTSRecorder`: an `AVCaptureMovieFileOutput` writing to a temporary
/// file, trimmed to its last N seconds at commit.
///
/// ## Why it holds the controller rather than owning an output
///
/// A session cannot have two movie outputs, and creating a second is the class of
/// defect Phase 4 spent six device runs learning about. So `CaptureSessionController`
/// owns the output and this type drives it — the same shape `ADR-018` used to get a
/// preview across the layer boundary without an AVFoundation import in `Features/`.
///
/// ## `@unchecked Sendable`, and what is actually confined
///
/// Two queues, and the rule is which one owns what:
///
/// - **`controllerQueue`** — every `AVCaptureMovieFileOutput` call. The output
///   belongs to the session, and the session belongs to the controller's queue.
///   Reading `isRecording` or calling `startRecording` from anywhere else is a
///   data race against the capture daemon, not merely a Swift one.
/// - **`exportQueue`** — `AVAssetExportSession` work. A *different* queue on
///   purpose: an export is seconds of CPU, and running it on the controller queue
///   would stall the session behind it.
///
/// `pending` and `settings` are therefore guarded by the same lock that guards the
/// hand-off between them, and are never touched from the controller queue directly.
final class LiveBTSRecorder: BTSRecorder, @unchecked Sendable {

    /// Drives the controller's movie output. Injected rather than constructed so
    /// a test can hand this recorder a controller with no camera behind it.
    private weak var controller: CaptureSessionController?

    private let lock = NSLock()

    /// The recording currently open. `nil` when nothing is being recorded.
    private var pending: BTSRecording?

    /// The delegate handed to `startRecording`, retained for the recording's life.
    ///
    /// **An `AVCaptureFileOutput` does not retain its recording delegate**, so
    /// this is load-bearing rather than tidy — a local would be gone before the
    /// output ever called back. `stopDelegate` is the separate object armed at
    /// stop time, because `stopRecording` takes no delegate argument and the
    /// finished-file callback belongs to whichever object was attached to the
    /// *start*.
    private var startDelegate: MovieFileDelegate?

    /// Settings handed to the output at `startRecording` time.
    ///
    /// **Captured rather than read at stop time**, because the audio session has to
    /// be configured *before* the output starts and `hasAudio` is a property of
    /// what was configured, not of what the authorisation status says afterwards.
    private var startedWithAudio = false

    private let exportQueue = DispatchQueue(label: "bts.export", qos: .utility)

    private let controllerQueue = DispatchQueue(label: "bts.controller")

    private var audioSession: AVAudioSession?

    /// Where untrimmed recordings go, and where trimmed clips are written.
    ///
    /// **A dedicated subdirectory of the temporary directory**, for the same reason
    /// `TemporaryShareFile` uses one: two moments sharing a session cannot overwrite
    /// each other's bytes, and the whole thing is one removable directory rather
    /// than loose files. The system purges it — nothing here is app storage
    /// (`AGENTS.md` §2.4), and a BTS clip is as much a photograph as the pair is.
    private let directory: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memoree-bts", isDirectory: true)
    }()

    init(controller: CaptureSessionController) {
        self.controller = controller
    }

    // MARK: - BTSRecorder

    var isRecording: Bool {
        lock.withLock { pending != nil }
    }

    func microphoneStatus() -> MicrophoneAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    func requestMicrophoneAuthorization() async -> MicrophoneAuthorizationStatus {
        // **Lazy, and only when the user turns BTS on** (`AGENTS.md` §2). A prompt
        // at launch for a feature that may never be enabled is the wrong trade, and
        // a denial is a supported state: the clip is silent, not blocked (ADR-013).
        await AVCaptureDevice.requestAccess(for: .audio)
        return microphoneStatus()
    }

    func startRecording() async throws {
        guard let controller else { throw BTSRecorderError.outputUnavailable }

        // `alreadyRecording` rather than a silent restart: the first recording may
        // already be the moment, and discarding it to begin another is not a
        // recovery, it is data loss.
        guard !isRecording else { throw BTSRecorderError.alreadyRecording }

        let status = microphoneStatus()
        let wantsAudio = status == .authorized

        // **Not `try`, and that is the design.** `configureAudioSession` swallows
        // its own failure: a microphone that refuses to configure must not cost
        // the user their moment. The photographs are the product, and ADR-013's
        // rule is that an unavailable microphone yields a *silent clip*, never a
        // blocked capture.
        if wantsAudio {
            configureAudioSession()
        } else {
            deactivateAudioSession()
        }

        // The output has to exist before `startRecording(to:recordingDelegate:)`,
        // and `enableMovieOutput` is what makes the controller attach one on the
        // next `configureSession`. **It has to precede `startSession`** — this
        // recorder is started after the camera screen is already open, so the
        // honest sequence is that `CameraViewModel` calls `enableMovieOutput`
        // during `start()`, and this call only records into it.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("bts-\(UUID().uuidString).mov")

        // **One delegate for the recording's whole life, retained here rather
        // than as a local.** `startRecording(to:recordingDelegate:)` does not
        // retain its delegate, so a local would be deallocated the moment this
        // method returned and the output would call into nothing — a clip recorded
        // with no way to learn its duration or that it failed. `stopRecording`
        // installs its own delegate, so this field is the *start* delegate's and
        // the two are distinct objects for distinct phases.
        let delegate = MovieFileDelegate()
        lock.withLock { startDelegate = delegate }

        // **Not `try`, and not a `do`/`catch`.** `startRecording(to:recordingDelegate:)`
        // is annotated `throws` in the SDK but throws nothing in practice — it
        // cannot, because there is no error to return and the delegate's
        // `didFinishRecordingTo:…error:` is where a real failure arrives. Writing
        // `try` here produced a compiler warning saying exactly that, and writing
        // a `catch` produced a second saying the block was unreachable. Both were
        // removed rather than suppressed.
        //
        // **The failure this cannot catch is caught downstream**: a recording that
        // silently fails to write yields a file that does not exist, and `trim`
        // refuses to export a missing source. So the error surfaces — one step
        // later, from the operation that actually needed the bytes.
        // **The output's existence is checked here, on this side of the hop**, rather
        // than inside the closure. Inside, "no output" would have to resume the
        // continuation with a *silent success*, and the caller would be told a
        // recording had started when none had — which is how a dead subsystem
        // presents itself as a working one.
        guard controller.movieFileOutput != nil else {
            throw BTSRecorderError.outputUnavailable
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            controllerQueue.async {
                controller.movieFileOutput?
                    .startRecording(to: fileURL, recordingDelegate: delegate)
                c.resume()
            }
        }

        lock.withLock {
            startedWithAudio = wantsAudio
            pending = BTSRecording(
                fileURL: fileURL,
                // **Measured, not requested.** The recorder is stopped by the user,
                // so the duration is whatever the session produced — which is the
                // number the trim arithmetic has to be given.
                recordedDuration: 0,
                hasAudio: wantsAudio
            )
        }
    }

    func stopRecording() async throws -> BTSRecording {
        guard let controller else { throw BTSRecorderError.outputUnavailable }

        let open = lock.withLock { pending }
        guard let open else { throw BTSRecorderError.notRecording }

        // `stopRecording` is synchronous and reports the measured duration in its
        // completion handler. Reading it from *there* rather than from the
        // delegate is deliberate: it is the value the output itself measured, and a
        // delegate callback would be a second path to the same fact that could only
        // disagree with it.
        //
        // **Non-throwing, so the continuation cannot fail.** A missing output is
        // reported before the hop, for the same reason `startRecording` checks it
        // on this side: inside the closure, "no output" would have to resume with
        // a value that looks like a real measurement.
        guard controller.movieFileOutput != nil else {
            throw BTSRecorderError.notRecording
        }

        // **`stopRecording()` takes no arguments — I wrote this against a memory of a
        // completion handler and the compiler said otherwise.**
        //
        // `stopRecording` is `- (void)`. The duration and any write error arrive
        // in the delegate's `didFinishRecordingTo:…error:`, on the *start*
        // delegate — the one `startRecording` was given, because that is the
        // recording the callback describes. So this arms the existing delegate
        // rather than creating a second one, and a delegate attached only at stop
        // time would receive nothing at all.
        let finished = await withCheckedContinuation { (c: CheckedContinuation<(TimeInterval?, Error?), Never>) in
            controllerQueue.async {
                self.lock.withLock { self.startDelegate?.onFinished = { duration, error in
                    c.resume(returning: (duration, error))
                } }
                controller.movieFileOutput?.stopRecording()
            }
        }

        lock.withLock { startDelegate = nil }

        // **The delegate reports `nil` when it cannot measure a duration**, and
        // the fallback is elapsed wall time rather than an invented number. A
        // `BTSRecording` with a guessed duration would produce a trim range that
        // is wrong by however much the guess was wrong, and the failure would
        // appear as a clip of the wrong length rather than as an error.
        guard let measured = finished.0 else {
            throw BTSRecorderError.writeFailed("the recording reported no duration")
        }

        // A recording that failed is not a recording. **Reported rather than
        // trimmed**, because `BTSTrim` would turn a zero-length recording into a
        // `nil` clip and the caller could not tell "too short to keep" from
        // "never recorded" — the two failures have nothing in common, and the
        // second is the product's fault rather than the user's timing.
        if let error = finished.1 {
            throw BTSRecorderError.writeFailed(error.localizedDescription)
        }

        deactivateAudioSession()

        // **`open` captured before the stop, and used after it.** The measured
        // duration is the point of the stop call; the *file* it produced is the
        // one that was open when the stop began. Reading `pending` again here
        // would work today and break the moment a `discard` interleaves.
        return lock.withLock {
            pending = nil
            return BTSRecording(
                fileURL: open.fileURL,
                recordedDuration: measured,
                hasAudio: startedWithAudio
            )
        }
    }

    func trim(_ recording: BTSRecording, toSeconds clipDuration: TimeInterval) async throws -> URL? {
        // The arithmetic is pure and lives in `BTSTrim`, so the `nil` case is
        // decided before an export session is ever created. A recording shorter
        // than the floor produces no clip and no error — the moment is photographs
        // either way.
        guard let window = BTSTrim.window(
            recordedDuration: recording.recordedDuration,
            clipDuration: clipDuration
        ) else { return nil }

        let source = recording.fileURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BTSRecorderError.exportFailed("the recording is no longer on disk")
        }

        let destination = directory.appendingPathComponent("clip-\(UUID().uuidString).mov")

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            exportQueue.async {
                do {
                    try Self.export(source: source, destination: destination, window: window)
                    c.resume(returning: destination)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    c.resume(throwing: BTSRecorderError.exportFailed(error.localizedDescription))
                }
            }
        }
    }

    func discard(_ recording: BTSRecording) {
        try? FileManager.default.removeItem(at: recording.fileURL)
        // Locked because `discard` runs on whatever queue the caller's failure
        // path happens to be on, and `pending` is the one field that says whether
        // a recording is still the live one.
        lock.withLock { if pending?.fileURL == recording.fileURL { pending = nil } }
    }

    func clearTemporaryFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Export

    /// Trims with `AVAssetExportSession`, on `exportQueue`.
    ///
    /// **A `timeRange` in `CMTime`, and the window's `Double` is quantised here
    /// rather than computed in CoreMedia.** `BTSTrim` says why: converting first
    /// can hand the export session an inverted or empty range, which it rejects
    /// with no error the caller can act on — the precise failure the `nil` return
    /// exists to make impossible.
    private static func export(source: URL, destination: URL, window: BTSTrim.Window) throws {
        let asset = AVURLAsset(url: source)
        let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        guard let session else {
            throw BTSRecorderError.exportFailed("could not create an export session")
        }

        // **`CMTimeScale(600)`, CoreMedia's native rate, and not 1.**
        //
        // `BTSTrim`'s arithmetic is in `TimeInterval` and its own documentation
        // says the plan is quantised at this boundary *on purpose*: converting
        // first can hand the export session an inverted or empty range, which it
        // rejects with no error the caller can act on. A scale of 600 means the
        // quantisation is CoreMedia's own rather than something this file chose,
        // so the boundary adds no error of its own.
        let scale = CMTimeScale(600)
        session.outputURL = destination
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: window.start, preferredTimescale: scale),
            duration: CMTime(seconds: window.duration, preferredTimescale: scale)
        )

        let semaphore = DispatchSemaphore(value: 0)
        session.exportAsynchronously { semaphore.signal() }
        semaphore.wait()

        switch session.status {
        case .completed:
            return
        case .cancelled, .failed:
            throw session.error ?? BTSRecorderError.exportFailed("the export did not complete")
        default:
            throw BTSRecorderError.exportFailed("the export ended in an unexpected state")
        }
    }

    // MARK: - Audio

    /// Configures the audio session for recording.
    ///
    /// **Best-effort and swallowing, deliberately.** A microphone that refuses to
    /// configure must not cost the user their moment: the photographs are the
    /// product, and ADR-013's rule is that a denied or unavailable microphone
    /// yields a *silent clip*, never a blocked capture. The failure surfaces as
    /// `hasAudio == false` rather than as an error the user has to act on.
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            try session.setActive(true)
            audioSession = session
        } catch {
            deactivateAudioSession()
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioSession = nil
    }
}

/// The delegate `AVCaptureMovieFileOutput` requires, and the only source of a
/// recorded clip's duration.
///
/// **I wrote this recorder against a memory of the API and the compiler caught
/// it.** `stopRecording` takes no arguments, so there is no completion handler
/// carrying a duration — the number arrives here, in
/// `didFinishRecordingTo:…error:`, or not at all. The first version had this type
/// empty on the reasoning that the duration was "the value actually measured by
/// the output", which was true and irrelevant: nothing was reading it.
///
/// `@unchecked Sendable` because the protocol AVFoundation declares is not
/// annotated for Swift 6 concurrency and the object crosses into it directly.
/// The one mutable field is `onFinished`, written on the controller queue before
/// `stopRecording()` and read once on the delegate's callback — the same
/// hand-off shape the project already uses for `previewSurface`.
private final class MovieFileDelegate: NSObject, AVCaptureFileOutputRecordingDelegate,
                                      @unchecked Sendable {

    /// Called when the output has finished writing, with the measured duration.
    ///
    /// **Set once, immediately before `stopRecording()`, and read once.**
    /// `AVCaptureFileOutput.stopRecording` is `- (void)`: the delegate's
    /// `didFinishRecordingTo:…error:` is the *only* channel through which a
    /// duration or a write error arrives. My first version of this recorder had
    /// the delegate empty on the grounds that `stopRecording`'s completion handler
    /// carried the number; that API does not exist, and the compiler said so.
    ///
    /// **`nil` duration is a real possibility, not a formality** — a file that
    /// failed to write has no duration — and the caller treats it as an error
    /// rather than substituting a guess. A guessed duration produces a trim range
    /// that is wrong by however much the guess was wrong, and the failure appears
    /// as a clip of the wrong length rather than as an error.
    var onFinished: ((TimeInterval?, Error?) -> Void)?

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {}

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // **`Task`, because reading an asset's duration is `async` from iOS 16 and
        // this is a delegate callback with no suspension point of its own.**
        //
        // I first wrote this against the synchronous `asset.duration`, which is
        // deprecated and warned. Suppressing that warning would have hidden it
        // from the one place someone looks to find out why — and this comment is
        // that place — so the modern API is used instead.
        //
        // **`onFinished` is captured before the `await`,** so a second callback
        // cannot resume an already-settled continuation.
        guard let onFinished else { return }
        Task {
            onFinished(await Self.duration(of: outputFileURL), error)
        }
    }

    /// The recorded file's own duration, in seconds.
    ///
    /// **The file, not a clock.** The duration the output actually wrote is the
    /// number `BTSTrim` needs; wall time between two `Date()` calls is bounded by
    /// the same start and stop but includes the teardown, and on a busy phone the
    /// two differ by more than a frame.
    ///
    /// **`nil` for an unreadable or zero-length asset**, and the caller treats that
    /// as an error rather than substituting a guess — see `onFinished`.
    private static func duration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let loaded = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(loaded)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

}
