import Foundation

/// An in-memory `BTSRecorder` for tests.
///
/// Every UI test and every view-model test that touches the capture flow uses
/// one of these, so no test needs a camera, a microphone, or an export session.
/// The simulator has none of the three, and without this seam the BTS path would
/// be exactly the kind of thing that only works on a phone — which is how the
/// camera path acquired a dozen defects that six device runs then found.
///
/// Records what it was asked to do, so a test asserts on **calls** — that the
/// clip was trimmed to the configured duration, that a re-take discards the
/// previous clip rather than leaking it — rather than merely that nothing threw.
///
/// Thread-safe: Swift Testing runs suites in parallel.
final class InMemoryBTSRecorder: BTSRecorder, @unchecked Sendable {

    /// `recordedDuration` the double reports for every recording it opens.
    ///
    /// A number a test can set rather than one derived from a real clock, so
    /// the trim arithmetic is exercised on both sides of
    /// `BTSTrim.minimumRecordedDuration` without waiting for either.
    var stubRecordedDuration: TimeInterval = 12

    private struct State {
        var microphone: MicrophoneAuthorizationStatus = .authorized
        var isRecording = false
        /// Recordings opened, in order. Each carries the duration it was
        /// reported with, so a test can check what was trimmed from what.
        var started: [BTSRecording] = []
        var stopped: [BTSRecording] = []
        /// Durations asked for, in order — the assertion that a clip was
        /// trimmed to the configured length rather than to whatever was on hand.
        var trimmedTo: [TimeInterval] = []
        /// Recordings passed to `discard`, by URL.
        var discarded: [URL] = []
        var clearTemporaryFilesCount = 0
        var authorizationRequests = 0
        /// The recording currently open, if any.
        var open: BTSRecording?
        var startFailure: BTSRecorderError?
        var stopFailure: BTSRecorderError?
        var trimFailure: BTSRecorderError?
    }

    private let lock = NSLock()
    private var state = State()
    private var counter = 0

    // MARK: - Injected failures

    func failNextStart(with error: BTSRecorderError) {
        lock.withLock { state.startFailure = error }
    }

    func failNextStop(with error: BTSRecorderError) {
        lock.withLock { state.stopFailure = error }
    }

    func failNextTrim(with error: BTSRecorderError) {
        lock.withLock { state.trimFailure = error }
    }

    func setMicrophoneStatus(_ status: MicrophoneAuthorizationStatus) {
        lock.withLock { state.microphone = status }
    }

    // MARK: - Recorded calls

    var startedRecordings: [BTSRecording] { lock.withLock { state.started } }
    var stoppedRecordings: [BTSRecording] { lock.withLock { state.stopped } }
    var trimmedToDurations: [TimeInterval] { lock.withLock { state.trimmedTo } }
    var discardedURLs: [URL] { lock.withLock { state.discarded } }
    var clearTemporaryFilesCalls: Int { lock.withLock { state.clearTemporaryFilesCount } }
    var authorizationRequestCount: Int { lock.withLock { state.authorizationRequests } }
    var isStillRecording: Bool { lock.withLock { state.isRecording } }

    // MARK: - BTSRecorder

    var isRecording: Bool { lock.withLock { state.isRecording } }

    func microphoneStatus() -> MicrophoneAuthorizationStatus {
        lock.withLock { state.microphone }
    }

    func requestMicrophoneAuthorization() async -> MicrophoneAuthorizationStatus {
        lock.withLock {
            state.authorizationRequests += 1
            // Mirrors the real service: a request resolves to whatever the
            // user chose, and a double that always answers "granted" cannot
            // exercise the denial path.
            state.microphone = state.microphone == .notDetermined ? .authorized : state.microphone
            return state.microphone
        }
    }

    func startRecording() async throws {
        try lock.withLock {
            if let failure = state.startFailure {
                state.startFailure = nil
                throw failure
            }
            guard !state.isRecording else { throw BTSRecorderError.alreadyRecording }
            counter += 1
            let recording = BTSRecording(
                fileURL: URL(fileURLWithPath: "/tmp/memoree-bts-\(counter).mov"),
                recordedDuration: stubRecordedDuration,
                // Mirrors reality: no microphone means no audio track, and the
                // flag has to travel from the authorisation state rather than
                // being assumed.
                hasAudio: state.microphone == .authorized
            )
            state.isRecording = true
            state.open = recording
            state.started.append(recording)
        }
    }

    func stopRecording() async throws -> BTSRecording {
        try lock.withLock {
            if let failure = state.stopFailure {
                state.stopFailure = nil
                throw failure
            }
            guard state.isRecording, let recording = state.open else {
                throw BTSRecorderError.notRecording
            }
            state.isRecording = false
            state.open = nil
            state.stopped.append(recording)
            return recording
        }
    }

    func trim(_ recording: BTSRecording, toSeconds clipDuration: TimeInterval) async throws -> Data? {
        try lock.withLock {
            if let failure = state.trimFailure {
                state.trimFailure = nil
                throw failure
            }
            state.trimmedTo.append(clipDuration)
            guard let window = BTSTrim.window(
                recordedDuration: recording.recordedDuration,
                clipDuration: clipDuration
            ) else { return nil }

            // **Bytes, and no file at all.**
            //
            // This wrote a real `.mov` into the temporary directory, on the
            // reasoning that "a test that only cares about the decision should not
            // need a writable directory". That was true until `CameraViewModel`
            // started *reading the clip* at commit — and then every BTS test failed
            // at once with `savedBTSCount == 0`, because the view model was handed
            // a URL it could not open and correctly reported no clip. Writing an
            // actual file fixed that failure and left a worse one behind: a suite
            // that litters `/tmp` and a `clearTestFiles` helper that existed only to
            // clean up after it.
            //
            // The protocol returns `Data` now, so the seam ends where the behaviour
            // does. **A double that writes a file for a test to read is not a cheaper
            // double — it is a second thing to go wrong**, and nothing in the view
            // model cares what those bytes are.
            counter += 1
            return Data("trimmed-\(window.start)-\(window.duration)-\(counter)".utf8)
        }
    }

    /// **Deletes nothing, because `trim` no longer writes anything.** The
    /// recording's path is recorded so a test can assert the caller released it,
    /// and that assertion is the whole point — whether the real implementation
    /// manages to unlink the file is not this type's behaviour to verify.
    func discard(_ recording: BTSRecording) {
        lock.withLock { state.discarded.append(recording.fileURL) }
    }

    /// Mirrors the real recorder: close, release the bytes, **and leave nothing
    /// behind** — so `isRecording` is `false` afterwards even when a stop failure
    /// meant the recording could not be closed properly.
    ///
    /// **The failure is swallowed rather than short-circuited.** A test that
    /// injected `failNextStop` and then called `abandon` used to leave the double
    /// reporting `isRecording == true`, which does not match the real
    /// implementation and quietly made the camera view model's abandon path
    /// untestable.
    func abandon() {
        let open = lock.withLock { () -> BTSRecording? in
            state.stopFailure = nil
            let open = state.open
            if let open { state.stopped.append(open) }
            state.isRecording = false
            state.open = nil
            return open
        }
        if let open { lock.withLock { state.discarded.append(open.fileURL) } }
    }

    /// Counts the launch-time sweep of the real recorder's temporary directory.
    ///
    /// **Nothing is swept here, and nothing needs to be.** `trim` hands back
    /// `Data` and keeps its files to itself, so this double no longer writes any —
    /// it has a `temporaryDirectory`, a `clearTestFiles`, and a suite-level
    /// `defer` that cleaned up after itself, all three of which existed only
    /// because `trim` used to return a URL a test had to be able to read.
    func clearTemporaryFiles() {
        lock.withLock { state.clearTemporaryFilesCount += 1 }
    }
}
