import Foundation
import Testing

@testable import Memoree

/// The BTS flow through `CameraViewModel`: when a recording opens, when it is
/// thrown away, and what a failure costs.
///
/// ## Every case here is `ADR-013`'s central claim
///
/// *"a BTS failure must not cost the user a moment"* — the two photographs are the
/// product and the clip is a bonus. So the tests below are mostly about what
/// **does not** happen when BTS misbehaves: no lost photographs, no wedged phase,
/// no dialog about a video the user cannot have.
///
/// ## Why the double and not the real recorder
///
/// The simulator has no camera, no microphone and no export session, and a test that
/// needed any of the three would only pass on a phone. `InMemoryBTSRecorder` is why
/// the camera path's dozen defects were findable at all, and this suite exists for
/// the same reason. What it cannot cover — the output attaching to a real session,
/// the trim actually producing a playable file — is covered by the invariant tests
/// and by the device gate.
@Suite("Phase 10 — Behind the Scenes flow")
@MainActor
struct BTSFlowTests {

    // MARK: - Helpers

    /// Everything a test needs, as a context rather than a tuple.
    ///
    /// **A struct, and not a four-member tuple.** Three of these are doubles and
    /// one is the thing under test, so the tuple read as
    /// `(model, service, library, box)` at every call site with no hint which was
    /// which — and SwiftLint's `large_tuple` rule exists for that reason. The
    /// capture service is *not* a member: no test below asserts on it, because a
    /// BTS test is about the recorder and the library, and `savedPairCount` already
    /// proves both photographs were captured.
    private struct Fixture {
        let model: CameraViewModel
        let library: InMemoryPhotoLibraryService
        let box: RecordBox

        /// Captures both halves and commits, which is what most tests below need
        /// to have done first.
        ///
        /// **On the fixture rather than taking the model**, so a call site reads
        /// `await fixture.captureAndCommit()` and not a helper with two arguments
        /// it never varied.
        @MainActor
        func captureAndCommit() async {
            await model.start()
            await model.shutterPressed()
            await model.shutterPressed()
            #expect(model.phase == .review)
            await model.commit()
        }
    }

    /// A view model wired for a complete moment, with BTS on or off.
    private func makeModel(
        bts: InMemoryBTSRecorder? = nil,
        saveBTS: Bool = true,
        clipDuration: TimeInterval = BTSTrim.defaultClipDuration,
        library: InMemoryPhotoLibraryService = InMemoryPhotoLibraryService(),
        shouldFileIntoAlbum: Bool = false
    ) -> Fixture {
        library.setAuthorization(.authorized)
        let box = RecordBox()
        let model = CameraViewModel(
            service: InMemoryCaptureService(),
            photoLibrary: library,
            btsRecorder: bts,
            clipDuration: { clipDuration },
            record: { capture in try box.record(capture) },
            shouldFileIntoAlbum: { shouldFileIntoAlbum },
            shouldSaveBTS: { saveBTS },
            chooseFirstCamera: { .back }
        )
        return Fixture(model: model, library: library, box: box)
    }

    // MARK: - The feature is off by default

    @Test("With no recorder, nothing is recorded and nothing is written")
    func btsOffRecordsNothing() async throws {
        let fixture = makeModel(bts: nil)

        await fixture.captureAndCommit()

        #expect(fixture.library.savedBTSCount == 0,
                "no recorder means no clip, and no clip means no library write")
        #expect(fixture.box.recorded?.bts == nil,
                "a moment committed without BTS carries no clip")
    }

    // MARK: - The happy path

    @Test("A clip is trimmed to the configured length and written alongside the pair")
    func clipIsTrimmedAndWritten() async throws {
        let bts = InMemoryBTSRecorder()
        bts.stubRecordedDuration = 12
        let fixture = makeModel(bts: bts, clipDuration: 5)

        await fixture.captureAndCommit()

        #expect(bts.startedRecordings.count == 1, "one recording, opened with the session")
        #expect(bts.stoppedRecordings.count == 1, "closed at commit")
        #expect(bts.trimmedToDurations == [5],
                "trimmed to what the user asked for, not to whatever was on hand")

        #expect(fixture.library.savedBTSCount == 1)
        let committed = try #require(fixture.box.recorded?.bts)
        #expect(committed.hasAudio, "the double was authorised, so the clip has audio")
        #expect(committed.assetIdentifier?.isEmpty == false,
                "the moment carries the identifier the clip was written under")
    }

    @Test("The recording opens only once the session is live")
    func recordingStartsWithTheSession() async throws {
        // The movie output has to be attached by `configureSession`, so a recording
        // opened before `start()` would have nothing to record into — and asking
        // earlier would mean configuring a session that does not exist.
        let bts = InMemoryBTSRecorder()
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library,
            btsRecorder: bts, chooseFirstCamera: { .back }
        )

        #expect(bts.startedRecordings.isEmpty, "nothing before start()")
        await model.start()
        #expect(bts.startedRecordings.count == 1, "opened with the session")
        #expect(service.startCount == 1)
        // **Compared by index rather than by equality of the log**, because the
        // property is an ordering and "the log contains both" does not have one.
        // `?? .max` so a *missing* entry sorts last and fails the comparison instead
        // of silently passing an `Int? < Int?` that is `nil` on both sides.
        let requested = service.eventLog.firstIndex(of: "enableMovieOutput") ?? .max
        let started = service.eventLog.firstIndex(of: "startSession") ?? .max
        #expect(requested < started,
                "the output must be asked for before the session is configured")
    }

    @Test("The movie output is asked for exactly once, before the session starts")
    func movieOutputIsRequestedBeforeTheSession() async throws {
        // **The one ordering in this feature that nothing on screen reveals.**
        //
        // `CaptureSessionController` attaches a movie output only to sessions
        // configured *after* `wantsMovieOutput` is set, and a request made after the
        // session is live configures nothing. So the failure is invisible: BTS is
        // on, the recorder's `outputUnavailable` is swallowed per ADR-013, and the
        // app silently records nothing forever.
        //
        // **Counted *and* ordered.** "Both happened" is not the claim; "in that
        // order" is, and a count alone passes on the broken version.
        let bts = InMemoryBTSRecorder()
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library,
            btsRecorder: bts, chooseFirstCamera: { .back }
        )

        #expect(service.movieOutputRequests == 0, "nothing before start()")
        await model.start()

        #expect(service.movieOutputRequests == 1, "asked for exactly once")
        #expect(service.eventLog == ["enableMovieOutput", "startSession"],
                "and in that order — the log is the whole lifecycle of this session")
    }

    @Test("No recorder means the movie output is never requested")
    func movieOutputIsNotRequestedWithoutBTS() async throws {
        // **Not merely untested: asserted.** `enableMovieOutput` sets a flag the
        // controller reads at configure time, so asking for an output nobody records
        // into is a movie output attached to every session for nothing — and it
        // would be attached *before* `if wantsMovieOutput` ever got a chance to be
        // false.
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()

        #expect(service.movieOutputRequests == 0,
                "BTS is off, so nothing should ask for an output")
    }

    @Test("Leaving the camera abandons the recording")
    func leavingTheCameraAbandonsTheRecording() async throws {
        // **A bug about the *next* moment, caused by leaving this one.** Stopping
        // the session also stops the movie output, so nothing more is written — but
        // the file stays in the temporary directory and `isRecording` stays true,
        // which makes every later `startRecording` throw `alreadyRecording`. That
        // throw is swallowed per ADR-013, so the symptom is "BTS stopped working"
        // with nothing to report and nothing to fix.
        let bts = InMemoryBTSRecorder()
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library,
            btsRecorder: bts, chooseFirstCamera: { .back }
        )
        await model.start()
        #expect(bts.isRecording)

        await model.stop()

        #expect(!bts.isRecording, "nothing left recording after the camera closes")
        #expect(bts.discardedURLs.count == 1, "and the bytes were released")
    }

    @Test("A recording that cannot be closed still leaves nothing behind")
    func abandonClearsStateEvenWhenTheStopFails() async throws {
        // **The case that wedged the recorder.** `stopRecording` throws when the
        // movie output has gone — which is exactly what ADR-027's session rebuild
        // does — and the throw means the recording's path is never handed back. The
        // `try? stopRecording()` this replaced left `isRecording` true forever, so
        // one dead session an hour ago cost every subsequent moment its clip.
        //
        // **Asserted through a re-take rather than through `isRecording`**, because
        // `startOver` ends with the camera composing again *and recording* — so
        // "not recording" would be a claim about a moment that has not happened
        // yet. The two things that are true afterwards are that the old recording
        // was released and a *different* one is open.
        let bts = InMemoryBTSRecorder()
        let fixture = makeModel(bts: bts)

        await fixture.model.start()
        let first = try #require(bts.startedRecordings.first)

        bts.failNextStop(with: .writeFailed("the output is gone"))
        await fixture.model.startOver()

        #expect(bts.discardedURLs == [first.fileURL],
                "the abandoned recording's bytes were released despite the stop failing")

        // **And the recorder is usable again.** This is the part that matters: one
        // that still reported `isRecording` would throw `alreadyRecording` here, and
        // that throw is swallowed per ADR-013, so the symptom would be "BTS stopped
        // working" with nothing to report.
        let second = try #require(bts.startedRecordings.last)
        #expect(second.fileURL != first.fileURL, "a genuinely new recording, not the old one")
        #expect(bts.isRecording)
        #expect(bts.startedRecordings.count == 2)
    }

    @Test("The recording is not requested before the session is live, and not twice")
    func recordingIsNotOpenedTwice() async throws {
        let bts = InMemoryBTSRecorder()
        let fixture = makeModel(bts: bts)

        await fixture.model.start()
        // `start()` guards on `phase == .idle`, so a second call is a no-op — and a
        // recorder that threw `alreadyRecording` would surface as an error phase
        // rather than as silence if that guard ever changed.
        await fixture.model.start()

        #expect(bts.startedRecordings.count == 1)
    }

    // MARK: - The microphone, which is a supported denial

    @Test("A denied microphone yields a clip, not a blocked moment")
    func deniedMicrophoneStillCommits() async throws {
        // ADR-013: "a denial is a supported state, not an error… the user gets a
        // silent clip rather than a blocked moment." This is the whole claim, and
        // the test that would catch it being quietly untrue.
        let bts = InMemoryBTSRecorder()
        bts.setMicrophoneStatus(.denied)
        let fixture = makeModel(bts: bts)

        await fixture.captureAndCommit()

        #expect(fixture.model.phase == .saved, "the moment saved")
        #expect(fixture.library.savedPairCount == 1, "both photographs written")
        let committed = try #require(fixture.box.recorded?.bts)
        #expect(!committed.hasAudio, "the clip is silent, which is the whole point")
    }

    @Test("The microphone is not asked about until BTS actually starts")
    func microphonePromptIsLazy() async throws {
        let bts = InMemoryBTSRecorder()
        bts.setMicrophoneStatus(.notDetermined)
        let fixture = makeModel(bts: bts)

        #expect(bts.authorizationRequestCount == 0, "not at construction")
        await fixture.model.start()
        #expect(bts.authorizationRequestCount == 1,
                "asked once, when the recording opens — not at launch")
    }

    @Test("The microphone is asked about once, not on every recording")
    func microphoneIsAskedOnce() async throws {
        let bts = InMemoryBTSRecorder()
        bts.setMicrophoneStatus(.notDetermined)
        let fixture = makeModel(bts: bts)

        await fixture.model.start()
        let afterFirst = bts.authorizationRequestCount
        await fixture.model.startOver()
        await fixture.model.start()

        #expect(bts.authorizationRequestCount == afterFirst,
                "AVCaptureDevice already knows the answer; re-asking is a prompt")
    }

    // MARK: - Failure never costs the moment

    @Test("A recording that will not open leaves the photographs alone")
    func startFailureDoesNotCostTheMoment() async throws {
        let bts = InMemoryBTSRecorder()
        bts.failNextStart(with: .outputUnavailable)
        let fixture = makeModel(bts: bts)

        await fixture.captureAndCommit()

        #expect(fixture.model.phase == .saved, "BTS failing is not a capture failing")
        #expect(fixture.library.savedPairCount == 1)
        #expect(fixture.library.savedBTSCount == 0, "no clip, because none was recorded")
        #expect(fixture.box.recorded?.bts == nil)
    }

    @Test("A trim that fails leaves the photographs alone")
    func trimFailureDoesNotCostTheMoment() async throws {
        let bts = InMemoryBTSRecorder()
        bts.failNextTrim(with: .exportFailed("no space"))
        let fixture = makeModel(bts: bts)

        await fixture.captureAndCommit()

        #expect(fixture.model.phase == .saved)
        #expect(fixture.library.savedPairCount == 1)
        #expect(fixture.library.savedBTSCount == 0)
    }

    @Test("A recording too short to keep is not a failure")
    func tooShortIsNotAFailure() async throws {
        // `BTSTrim` returns `nil` below its floor, and `nil` means "no clip", which
        // is the same as BTS being off. Two shutter presses inside half a second
        // produces this, and it is not something to report as a problem.
        let bts = InMemoryBTSRecorder()
        bts.stubRecordedDuration = BTSTrim.minimumRecordedDuration - 0.1
        let fixture = makeModel(bts: bts)

        await fixture.captureAndCommit()

        #expect(fixture.model.phase == .saved)
        #expect(fixture.model.btsFailure == nil, "an ordinary absence is not a failure")
        #expect(fixture.library.savedBTSCount == 0)
        #expect(bts.discardedURLs.count == 1,
                "the untrimmed recording is discarded rather than left on disk")
    }

    // MARK: - Discarding

    @Test("A re-take abandons the recording rather than keeping a clip of the old shot")
    func reshootAbandonsTheRecording() async throws {
        let bts = InMemoryBTSRecorder()
        let fixture = makeModel(bts: bts)

        await fixture.model.start()
        await fixture.model.shutterPressed()
        await fixture.model.shutterPressed()
        #expect(fixture.model.phase == .review)

        await fixture.model.reshoot(.back)

        #expect(bts.stoppedRecordings.count == 1, "the recording was closed")
        #expect(bts.discardedURLs.count == 1, "and its bytes released")
    }

    @Test("Starting over abandons the recording")
    func startOverAbandonsTheRecording() async throws {
        let bts = InMemoryBTSRecorder()
        let fixture = makeModel(bts: bts)

        await fixture.model.start()
        await fixture.model.shutterPressed()
        await fixture.model.shutterPressed()
        await fixture.model.startOver()

        #expect(bts.stoppedRecordings.count == 1)
        #expect(bts.discardedURLs.count == 1)
    }

    @Test("Only the committed pair ever produces a clip")
    func discardedClipIsNeverWritten() async throws {
        let bts = InMemoryBTSRecorder()
        let fixture = makeModel(bts: bts)

        await fixture.model.start()
        await fixture.model.shutterPressed()
        await fixture.model.shutterPressed()
        await fixture.model.startOver()
        await fixture.model.shutterPressed()
        await fixture.model.shutterPressed()
        await fixture.model.commit()

        // **Both assertions, because either alone is satisfied by "never recorded".**
        //
        // Two recordings opened — the first abandoned on `startOver`, the second for
        // the pair that was kept — and exactly one clip written. `<= 1` would have
        // passed a view model that recorded nothing at all, which is precisely what
        // this test was written after it caught.
        #expect(bts.startedRecordings.count == 2,
                "the first recording was abandoned and a second opened")
        #expect(fixture.library.savedBTSCount == 1, "one clip, for the kept pair")
        #expect(fixture.box.recorded?.bts?.assetIdentifier?.isEmpty == false,
                "and the kept pair's clip is the one the moment points at")
        #expect(!bts.isRecording, "nothing left recording")
    }

    // MARK: - The retry guard

    @Test("A retry after a record failure does not write a second clip")
    func retryDoesNotWriteASecondClip() async throws {
        // ADR-022: "never repeat a step that succeeded". The pair has that guard
        // already, via `writtenAssets`; the clip needs its own, because it is a
        // second library write inside the same commit.
        //
        // **Built by hand rather than through `makeModel`**, because the recorder
        // has to be failing *continuously* — see `RecordBox.alwaysFails`.
        let bts = InMemoryBTSRecorder()
        let library = InMemoryPhotoLibraryService()
        let box = RecordBox()
        box.alwaysFails = true

        library.setAuthorization(.authorized)
        let model = CameraViewModel(
            service: InMemoryCaptureService(), photoLibrary: library,
            btsRecorder: bts,
            record: { capture in try box.record(capture) },
            shouldFileIntoAlbum: { false },
            shouldSaveBTS: { true },
            chooseFirstCamera: { .back }
        )

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        #expect(library.savedPairCount == 1, "the pair was written once")
        #expect(library.savedBTSCount == 1, "the clip was written once")

        // The phase must be retryable, or `retry()` has nothing to act on. Read off
        // the concrete case rather than a convenience property that does not exist.
        guard case .failed(_, let isRetryable) = model.phase else {
            Issue.record("expected a failed phase after a record failure")
            return
        }
        #expect(isRetryable)
        let callsBeforeRetry = box.recordCount

        await model.retry()

        #expect(library.savedPairCount == 1, "the pair was not written twice")
        #expect(library.savedBTSCount == 1, "nor was the clip")
        #expect(box.recordCount == callsBeforeRetry + 1,
                "the retry re-entered the record, so it is the write guards that saved it")
        #expect(bts.stoppedRecordings.count == 1,
                "and it did not try to close a recording that was already closed")
        #expect(bts.trimmedToDurations.count == 1, "nor re-trim the clip")
    }

    // MARK: - Settings

    @Test("With saving turned off, the clip is trimmed and then dropped")
    func unsavedClipIsTrimmedThenDropped() async throws {
        // `saveBTS` defaults **off**, so this is the state a user is in until they
        // ask otherwise — and the trim still happens, because the decision to write
        // is read at commit rather than at start.
        let bts = InMemoryBTSRecorder()
        let fixture = makeModel(bts: bts, saveBTS: false)

        await fixture.captureAndCommit()

        #expect(bts.trimmedToDurations == [BTSTrim.defaultClipDuration])
        #expect(fixture.library.savedBTSCount == 0, "nothing written to the library")
        #expect(fixture.box.recorded?.bts == nil,
                "and the moment does not claim a clip the library does not have")
    }

    @Test("When filing into album is enabled, BTS is filed alongside the photo pair")
    func btsIsFiledIntoAlbumWhenEnabled() async throws {
        let bts = InMemoryBTSRecorder()
        let fixture = makeModel(bts: bts, saveBTS: true, shouldFileIntoAlbum: true)

        await fixture.captureAndCommit()

        #expect(fixture.library.savedBTSCount == 1)
        let members = fixture.library.albumMembers(named: CameraViewModel.albumName)
        #expect(members.count == 3, "both photos and the BTS clip are added to the album")
    }
}

/// Captures whatever `CameraViewModel` hands its recorder.
///
/// **A reference type because the recorder closure is `@Sendable`** and a test has
/// to read the committed value from outside it. Also carries the one injected
/// failure, so the retry test does not need a second seam.
final class RecordBox: @unchecked Sendable {

    private let lock = NSLock()
    private var committed: CommittedCapture?
    private var calls = 0

    /// **Every call fails, not just the first.** A retry that succeeds on the second
    /// attempt would prove only that the guard skipped the *first* write; the
    /// property under test is that a second commit never issues one at all.
    var alwaysFails = false

    var recorded: CommittedCapture? {
        lock.lock(); defer { lock.unlock() }
        return committed
    }

    /// How many times the recorder was asked to record, which is how a test tells
    /// "the guard skipped the write" from "the write happened and was cheap".
    var recordCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    /// **Synchronous, and `async` only at the signature**, because
    /// `MomentRecorder` is `@MainActor (…) async throws` and the lock cannot be
    /// held across a suspension point. Deciding and recording happen in one
    /// critical section and the throw happens outside it — which is the same shape
    /// every other store in this project uses.
    func record(_ capture: CommittedCapture) throws {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        if !alwaysFails { committed = capture }
        if alwaysFails { throw StoreError.saveFailed("test") }
    }
}
