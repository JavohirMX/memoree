import Foundation

/// Records Behind the Scenes: the few seconds of video around a moment.
///
/// ## Why a protocol, and why it is not on `CapturePhotoService`
///
/// A protocol so the whole flow is testable with no camera and no microphone —
/// the simulator has neither, and the app's entire capture path is already built
/// on that seam (`AGENTS.md` §3). BTS sits on a **separate** protocol because it
/// is a different lifetime: the camera service is created once and lives for the
/// process, while a recording is opened and closed per moment and the user can
/// switch it off entirely. Folding it into `CapturePhotoService` would make
/// every existing test double carry a feature most tests never touch.
///
/// ## What the camera service owes it
///
/// The movie output has to be attached to the same `AVCaptureSession` as the
/// photo output, and that session belongs to `CaptureSessionController`. So the
/// real implementation holds a reference to the controller's movie output rather
/// than owning one — a session cannot have two, and creating a second is the
/// class of defect Phase 4 spent six device runs learning about.
///
/// ## The recording is the user's, not the app's
///
/// Everything produced here lands in the user's Photos library, in the app's
/// temporary directory, or is discarded. Nothing is retained in app storage
/// (`AGENTS.md` §2.4).
protocol BTSRecorder: AnyObject, Sendable {

    /// Whether a recording is open right now.
    var isRecording: Bool { get }

    /// Current microphone authorisation.
    ///
    /// **A denial is a supported state, not an error** (ADR-013). BTS without
    /// audio is still BTS; the user gets a silent clip rather than a blocked
    /// moment, because the moment is two photographs and refusing to take them
    /// over audio would be absurd.
    func microphoneStatus() -> MicrophoneAuthorizationStatus

    /// Requests microphone access.
    ///
    /// **Lazy, and only when the user turns BTS on.** Requesting it at launch
    /// would be a permission prompt for a feature they may never enable, and
    /// `AGENTS.md` §2 lists deniable permissions as ones the app must survive
    /// losing.
    func requestMicrophoneAuthorization() async -> MicrophoneAuthorizationStatus

    /// Opens a recording to a temporary file. Idempotent-unsafe by design:
    /// starting while already recording throws rather than silently discarding
    /// the first recording, because a caller that does that has a bug and the
    /// first clip may already be the moment.
    func startRecording() async throws

    /// Pauses / closes the currently active camera segment before a camera swap
    /// or entering review. The overall BTS session remains open.
    func pauseRecording() async

    /// Starts recording the next camera segment after a camera swap.
    func resumeRecording() async throws

    /// Closes the open recording and hands back what was captured across all segments.
    ///
    /// - Throws: when no recording is open.
    func stopRecording() async throws -> BTSRecording

    /// Trims a recording to its last `clipDuration` seconds and hands back the bytes.
    ///
    /// ## Why `Data` and not a `URL`
    ///
    /// This returned a file URL once, and the only consumer read it immediately and
    /// deleted it. That put a temporary-directory read **and** a `removeItem` in
    /// `Features/`, which is not where file I/O belongs (`AGENTS.md` §3), and it
    /// handed the caller a path into a directory the system purges whenever it
    /// likes. The export session needs a URL — that is inside this type now — and
    /// everything outside it wants the bytes.
    ///
    /// - Returns: the trimmed clip, or `nil` when there is nothing worth keeping —
    ///   a recording shorter than `BTSTrim.minimumRecordedDuration`. `nil` is not a
    ///   failure: the moment is photographs either way, and an error here would
    ///   give the user a dialog about a clip they never asked for.
    func trim(_ recording: BTSRecording, toSeconds clipDuration: TimeInterval) async throws -> Data?

    /// Releases a recording's bytes. Called on every path that does not keep the
    /// clip, including a re-take — see `CameraViewModel`'s commit for why that
    /// matters.
    func discard(_ recording: BTSRecording)

    /// Closes whatever is open, throws away its bytes, and leaves no state behind.
    ///
    /// ## Why this exists rather than `try? stopRecording()` followed by `discard`
    ///
    /// That sequence is what the camera view model did first, and it leaves the
    /// recorder **wedged** in exactly the case that matters. `stopRecording` throws
    /// when the movie output has gone — which is what a session rebuild does, and
    /// ADR-027's recovery rebuilds the session whenever the capture subsystem dies
    /// — and the throw means the returned `BTSRecording`, and therefore the path to
    /// the bytes, is never handed back. `isRecording` then stays `true` for the
    /// life of the object, so every later `startRecording` throws
    /// `alreadyRecording`, silently swallowed, and **every subsequent moment loses
    /// its clip because of one dead session an hour earlier.**
    ///
    /// `abandon` does not need the file URL to succeed: it closes whatever is open,
    /// clears the state, and removes what it can. **Never throws, and is safe with
    /// nothing open**, so a caller on a failure path has one call to make and no
    /// branch to get wrong.
    func abandon()

    /// Removes the temporary directory BTS writes into.
    ///
    /// On the protocol rather than being a private detail because **the app must
    /// be able to clean up after a crash**, and a crash is precisely the moment
    /// no other code runs.
    func clearTemporaryFiles()
}

extension BTSRecorder {
    func pauseRecording() async {}
    func resumeRecording() async throws {}
}

/// A closed recording across one or more camera segments, before trimming.
///
/// A value type carrying URLs, not a class: it crosses queues, and the
/// `Sendable` requirement on the protocol means everything it hands out has to
/// be too. Nothing is retained in app storage — these are files in the temporary
/// directory, referenced, not copied.
struct BTSRecording: Equatable, Hashable, Sendable {

    /// The raw, untrimmed recordings across camera segments in chronological order.
    let segmentURLs: [URL]

    /// Legacy / convenience single file URL. Points to the first segment.
    var fileURL: URL { segmentURLs.first ?? URL(fileURLWithPath: "/dev/null") }

    /// Durations of each segment as measured by the recorder.
    let segmentDurations: [TimeInterval]

    /// How long it actually ran in total across all segments.
    var recordedDuration: TimeInterval { segmentDurations.reduce(0, +) }

    /// Whether the clip carries an audio track.
    ///
    /// False when the microphone was denied. Recorded rather than inferred so
    /// the export path can avoid asking for an audio session it cannot have.
    let hasAudio: Bool

    init(fileURL: URL, recordedDuration: TimeInterval, hasAudio: Bool) {
        self.segmentURLs = [fileURL]
        self.segmentDurations = [recordedDuration]
        self.hasAudio = hasAudio
    }

    init(segmentURLs: [URL], segmentDurations: [TimeInterval], hasAudio: Bool) {
        self.segmentURLs = segmentURLs
        self.segmentDurations = segmentDurations
        self.hasAudio = hasAudio
    }
}

/// Mirrors `AVAuthorizationStatus` for the microphone, matching
/// `CameraAuthorizationStatus` exactly so the Settings screen has one shape to
/// render and no caller branches on two.
enum MicrophoneAuthorizationStatus: Sendable, Equatable {

    /// Not yet asked. BTS has not been turned on.
    case notDetermined

    /// Granted.
    case authorized

    /// The user said no. BTS records silently; nothing else changes.
    case denied

    /// Blocked by device policy or parental controls.
    case restricted
}

// MARK: - Errors

/// Everything that can go wrong recording Behind the Scenes.
///
/// Separate from `CaptureError` because these never block a moment. Every case
/// is recoverable by discarding the clip and continuing — the two photographs
/// are the moment, and a BTS failure must not cost the user one (ADR-013).
enum BTSRecorderError: Error, LocalizedError, Equatable {

    /// A recording is already open.
    case alreadyRecording

    /// Nothing is open, so there is nothing to stop.
    case notRecording

    /// The movie output could not be attached to the session.
    ///
    /// The camera is fine and the photograph will still be taken — this is the
    /// whole reason BTS is a separate failure from capture.
    case outputUnavailable

    /// The recording could not be written.
    case writeFailed(String)

    /// The trim or export failed.
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A Behind the Scenes clip is already recording."
        case .notRecording:
            return "No Behind the Scenes clip is recording."
        case .outputUnavailable:
            return "Behind the Scenes is unavailable on this camera."
        case .writeFailed:
            return "The Behind the Scenes clip could not be recorded."
        case .exportFailed:
            return "The Behind the Scenes clip could not be trimmed."
        }
    }

    /// Whether retrying could plausibly succeed.
    ///
    /// **No case is retryable.** A second attempt at the same moment would
    /// record the same thing again, and the user has already taken the
    /// photograph that matters — the response is to continue without a clip, not
    /// to offer a retry that cannot help. This is the opposite of
    /// `CaptureError.isRetryable`, and the difference is the point.
    var isRetryable: Bool { false }
}
