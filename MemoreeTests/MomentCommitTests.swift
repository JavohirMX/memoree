import Foundation
import SwiftData
import Testing

@testable import Memoree

/// Phase 5 — the moment is actually recorded.
///
/// The single test that fails if the daily loop is broken. `CameraViewModel`
/// used to write both photographs to Photos and stop, which meant the archive
/// row was never created, `TodayViewModel.todayMoment` was always `nil`, the
/// `captured` state was unreachable, and the streak never moved — while 163
/// other tests passed. This suite is the one that notices.
///
/// Everything runs against the doubles. There is no camera and no photo
/// library here, by design: the device half is `LiveCaptureTests`, and what is
/// being tested here is the *sequencing* between three collaborators, which is
/// exactly the part a device cannot tell you about.
@Suite("Phase 5 — recording a moment")
@MainActor
struct MomentCommitTests {

    /// Captures what the camera screen handed over, and can be told to fail once.
    private final class Recorder {
        var recorded: [CommittedCapture] = []
        var failNextWith: Error?
    }

    /// A clock that advances a fixed step each time it is read.
    ///
    /// Injected so the one assertion that matters — *which* instant gets
    /// recorded — is deterministic. A test that reaches for `Date()` is racing
    /// its own runtime: across a two-press sequence and a commit, the recorded
    /// time is whichever of the three reads happened to be the second.
    ///
    /// `@unchecked Sendable` because the camera screen's clock is declared
    /// `@Sendable`. The mutable `tick` is only ever touched from the main actor
    /// — this suite is `@MainActor` and the view model is — so the confinement
    /// is real; it is just not expressible to the compiler through a closure.
    private final class StepClock: @unchecked Sendable {
        private let origin: Date
        private let step: TimeInterval
        private var tick = 0

        init(origin: Date, step: TimeInterval = 30) {
            self.origin = origin
            self.step = step
        }

        func now() -> Date {
            defer { tick += 1 }
            return origin.addingTimeInterval(step * Double(tick))
        }
    }

    private struct Harness {
        let service: InMemoryCaptureService
        let library: InMemoryPhotoLibraryService
        let store: MomentStore
        let recorder: Recorder
    }

    private func makeHarness() throws -> Harness {
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        return Harness(
            service: InMemoryCaptureService(),
            library: library,
            store: MomentStore(context: ModelContext(try Persistence.inMemoryContainer())),
            recorder: Recorder()
        )
    }

    /// A view model whose recorder writes through a real in-memory store, and
    /// whose clock advances 30 seconds per read.
    ///
    /// The clock is the point of this helper. An earlier version of this suite
    /// reached for `Date()`, which made the one assertion that matters — *which*
    /// instant gets recorded — a race against the test's own runtime.
    private func makeModel(
        _ harness: Harness,
        chooseFirstCamera: CameraPosition = .back,
        now: Date,
        step: TimeInterval = 30
    ) -> CameraViewModel {
        let store = harness.store
        let recorder = harness.recorder
        let clock = StepClock(origin: now, step: step)

        return CameraViewModel(
            service: harness.service,
            photoLibrary: harness.library,
            record: { capture in
                if let failure = recorder.failNextWith {
                    recorder.failNextWith = nil
                    throw failure
                }
                recorder.recorded.append(capture)
                let day = DayIdentifier(date: capture.capturedAt)
                let start = day.date.addingTimeInterval(14 * 3600)
                try store.record(
                    day: day,
                    interval: MomentInterval(start: start, end: start.addingTimeInterval(120)),
                    capturedAt: capture.capturedAt,
                    retakeCount: capture.retakeCount,
                    backAssetIdentifier: capture.assets.back,
                    frontAssetIdentifier: capture.assets.front
                )
            },
            chooseFirstCamera: { chooseFirstCamera },
            now: { clock.now() }
        )
    }

    // MARK: - The loop closes

    @Test("Posting writes both photographs and records the moment")
    func postingRecordsAMoment() async throws {
        let harness = try makeHarness()
        let model = makeModel(harness, now: try #require(DayIdentifier(string: "2026-09-30")?.date))

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        #expect(model.phase == .saved)
        #expect(harness.library.savedPairCount == 1, "two assets, written once")
        #expect(harness.store.allMoments.count == 1, "and one archive row")
    }

    @Test("The recorded moment carries the identifiers the library returned")
    func recordedMomentCarriesAssetIdentifiers() async throws {
        let harness = try makeHarness()
        let model = makeModel(harness, now: try #require(DayIdentifier(string: "2026-09-30")?.date))

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        let written = try #require(harness.library.latestPair)
        let moment = try #require(harness.store.allMoments.first)
        // The row points at the photographs. Without this, the archive is a
        // list of days with nothing in it, and no error is ever raised.
        #expect(moment.backAssetIdentifier == written.back)
        #expect(moment.frontAssetIdentifier == written.front)
    }

    @Test("The moment's time is the second shutter press, not the commit")
    func capturedAtIsTheSecondPress() async throws {
        let harness = try makeHarness()
        // 14:00:00 and 14:00:30. The clock in `makeModel` advances 30s per read.
        let base = try #require(DayIdentifier(string: "2026-09-30")?.date)
            .addingTimeInterval(14 * 3600)
        let model = makeModel(harness, now: base)

        await model.start()
        await model.shutterPressed()          // t0 -> 14:00:00
        await model.shutterPressed()          // t1 -> 14:00:30, pair complete
        await model.commit()                  // t2 -> 14:01:00

        let moment = try #require(harness.store.allMoments.first)
        // Commit time would make lateness depend on how long the user stared
        // at the review screen, which is a fact about the review screen.
        #expect(moment.capturedAt == base.addingTimeInterval(30))
    }

    @Test("Lateness is derived from the window, not passed in from the camera")
    func latenessIsDerived() async throws {
        let harness = try makeHarness()
        // The window runs 14:00:00–14:02:00. A capture at 14:05 is three
        // minutes late even though nothing in the camera knows what time it is.
        // Step 0, so the recorded instant is exactly the one named here.
        //
        // **The day is derived rather than pinned**, for the same reason as the
        // on-time test below — and this one needed it *more*, because a stale day
        // makes the final assertion pass for the wrong reason. `summary()` with
        // no argument derives today from the real clock, so a moment on a literal
        // that is no longer recent gives `currentStreak == 0` because of the gap
        // rather than because the capture was late. A green assertion proving
        // nothing is worse than a red one, and this one had silently become one.
        let today = DayIdentifier(date: Date())
        let base = today.date.addingTimeInterval(14 * 3600 + 300)
        let model = makeModel(harness, now: base, step: 0)

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        let moment = try #require(harness.store.allMoments.first)
        #expect(moment.capturedAt == base)
        #expect(moment.dayIdentifier == today.rawValue)
        #expect(moment.isLate)
        #expect(moment.lateBy == 180, "14:05 against a window closing at 14:02")
        // A late day is still a real day. It is archived and badged; it just
        // does not grow the streak (ADR-009).
        #expect(harness.store.allMoments.count == 1)
        // **Today specifically**, so the zero can only come from the lateness:
        // the moment is on today, so the walk starts at today rather than a day
        // back, and only the on-time check can stop it.
        #expect(harness.store.summary(today: today).currentStreak == 0)
        // And the control: the same history with the moment counted as on time
        // does grow the streak, so the assertion above is about lateness.
        #expect(harness.store.summary(today: today).daysCaptured == 1)
    }

    @Test("An on-time capture is not late, and grows the streak")
    func onTimeCaptureGrowsTheStreak() async throws {
        let harness = try makeHarness()

        // **The day is derived, not pinned.** This used to hardcode
        // `DayIdentifier(string: "2026-09-30")`, and the suite went red at
        // midnight on 2026-10-02 for a reason that had nothing to do with the
        // code: `makeModel` pins the *model's* clock with a `StepClock`, but
        // `MomentStore.summary()` derives `today` from the **real** one.
        // `StreakCalculator.currentStreak` walks backwards from that real today,
        // so a capture pinned to a literal only lands inside the walk while the
        // literal is today or yesterday — **the test had a two-day expiry and it
        // expired.**
        //
        // What the assertion is actually about is "an on-time capture today
        // grows today's streak", so the day has to be today. Deriving it makes
        // that the claim instead of an accident of when the suite was written.
        let today = DayIdentifier(date: Date())
        let base = today.date.addingTimeInterval(14 * 3600 + 30)
        let model = makeModel(harness, now: base)

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        let moment = try #require(harness.store.allMoments.first)
        #expect(moment.dayIdentifier == today.rawValue, "the capture landed on the day the test derived")
        #expect(!moment.isLate)
        #expect(harness.store.summary(today: today).currentStreak == 1)
    }

    // MARK: - One moment per day

    @Test("Re-capturing replaces the day rather than adding a second moment")
    func recaptureReplacesTheDay() async throws {
        let harness = try makeHarness()
        let base = try #require(DayIdentifier(string: "2026-09-30")?.date)
            .addingTimeInterval(14 * 3600 + 30)
        let model = makeModel(harness, now: base)

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()
        #expect(harness.store.allMoments.count == 1)

        // A second presentation of the camera for the same day.
        let second = makeModel(harness, now: base.addingTimeInterval(600))
        await second.start()
        await second.shutterPressed()
        await second.shutterPressed()
        await second.commit()

        // One row, not two. Two rows for one day would double-count the streak
        // and render a duplicate cell in the archive (ADR-011: unlimited
        // retakes, one moment per day).
        #expect(harness.store.allMoments.count == 1)
        // Two pairs in Photos. Add-only authorisation cannot delete the first,
        // which is why the Today screen says so before the re-capture tap
        // rather than after it.
        #expect(harness.library.savedPairCount == 2)
    }

    @Test("The retake count is carried through to the moment")
    func retakeCountIsRecorded() async throws {
        let harness = try makeHarness()
        let model = makeModel(harness, now: try #require(DayIdentifier(string: "2026-09-30")?.date))

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.reshoot(.back)
        await model.shutterPressed()
        await model.commit()

        #expect(try #require(harness.store.allMoments.first).retakeCount == 1)
    }

    // MARK: - Partial commits

    @Test("A failed library write is retryable and the photographs survive")
    func failedWriteIsRecoverable() async throws {
        let harness = try makeHarness()
        harness.library.failNextWrite(with: .writeFailed("disk full"))
        let model = makeModel(harness, now: try #require(DayIdentifier(string: "2026-09-30")?.date))

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        #expect(model.isFailed)
        // The photographs are still in memory. An earlier `retry()` cleared
        // `captured` unconditionally and threw both away, which is the one
        // case where nothing had actually been lost.
        #expect(model.captured[.back] != nil)
        #expect(model.captured[.front] != nil)

        await model.retry()

        #expect(model.phase == .saved)
        #expect(harness.store.allMoments.count == 1)
    }

    @Test("A failed archive write does not write to Photos a second time")
    func retryAfterRecordFailureDoesNotRewrite() async throws {
        let harness = try makeHarness()
        let model = makeModel(harness, now: try #require(DayIdentifier(string: "2026-09-30")?.date))
        harness.recorder.failNextWith = StoreError.saveFailed("disk full")

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        // The photographs landed; only the row is missing.
        #expect(model.isFailed)
        #expect(harness.library.savedPairCount == 1)
        #expect(harness.store.allMoments.isEmpty)
        #expect(harness.recorder.recorded.isEmpty)

        await model.retry()

        #expect(model.phase == .saved)
        #expect(harness.store.allMoments.count == 1)
        // The whole point. A retry that re-ran the whole commit would leave a
        // duplicate pair in the user's camera roll, permanently, because
        // add-only authorisation means Memoree can never take it back.
        #expect(harness.library.savedPairCount == 1, "the write is memoised, not repeated")
    }

    @Test("A store error reaches the user as prose, not as a Core Data string")
    func storeErrorIsPresentedAsProse() async throws {
        let harness = try makeHarness()
        let model = makeModel(harness, now: try #require(DayIdentifier(string: "2026-09-30")?.date))
        harness.recorder.failNextWith = StoreError.saveFailed(
            "Core Data: error 133010. Unable to save."
        )

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        guard case .failed(let message, let isRetryable) = model.phase else {
            Issue.record("expected a recoverable failure, got \(model.phase)")
            return
        }
        #expect(isRetryable)
        #expect(!message.contains("Core Data"))
        #expect(!message.contains("133010"))
        // And it says the photographs are safe, because they are.
        #expect(message.localizedCaseInsensitiveContains("library"))
    }

    @Test("Reshooting after a failed write does not reuse the stale identifiers")
    func reshootInvalidatesAMemoisedWrite() async throws {
        let harness = try makeHarness()
        let model = makeModel(harness, now: try #require(DayIdentifier(string: "2026-09-30")?.date))
        harness.recorder.failNextWith = StoreError.saveFailed("nope")

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()
        #expect(model.isFailed)
        #expect(harness.library.latestPair?.back == "back-1")

        // The user reshoots one half instead of retrying. The pair that was
        // written is no longer the pair in hand, so its identifiers must not
        // be reused — otherwise the moment would point at a half that is no
        // longer in it.
        await model.reshoot(.front)
        await model.shutterPressed()
        await model.commit()

        #expect(model.phase == .saved)
        #expect(harness.library.savedPairCount == 2)
        let moment = try #require(harness.store.allMoments.first)
        #expect(moment.backAssetIdentifier == "back-2")
        #expect(moment.frontAssetIdentifier == "front-2")
    }

    // MARK: - The camera screen without an archive

    @Test("With no recorder injected, posting still saves to Photos")
    func noRecorderStillWrites() async throws {
        // SwiftUI previews and any test that is not about the archive run this
        // way. It is a legal configuration, not a failure.
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)
        let model = CameraViewModel(
            service: InMemoryCaptureService(),
            photoLibrary: library,
            chooseFirstCamera: { .back }
        )

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        #expect(model.phase == .saved)
        #expect(library.savedPairCount == 1)
    }
}
