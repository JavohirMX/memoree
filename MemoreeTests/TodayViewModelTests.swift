import Foundation
import SwiftData
import Testing
import UIKit

@testable import Memoree

/// Phase 5 — the Today screen's view model.
///
/// This suite did not exist while the Today screen shipped, and the gap was not
/// academic. `todayMoment` was only ever re-read on a day rollover, so capturing
/// a moment and dismissing the camera left the screen showing "It's time" with
/// a streak that had not moved, and nothing in the app would have noticed.
/// `TodayViewModel` is where the clock, the archive, the Photos read path and
/// the notification diagnostics meet — the kind of type that most needs a suite
/// and least wants one.
@Suite("Phase 5 — Today screen")
@MainActor
struct TodayViewModelTests {

    // MARK: - Harness

    /// The device's own rendering of a clock time, for assertions about *which*
    /// time rather than about how it is spelled.
    ///
    /// Necessary because the exact string is a property of the device, not of the
    /// code: `en_GB` says `14:00`, `en_US` says `2:00 PM` with a **narrow no-break
    /// space** (U+202F) before the meridiem, and `ja_JP` says `14:00`. A test that
    /// writes `"14:00"` is asserting that everyone on earth reads a 24-hour clock.
    private static func formattedClockTime(_ hour: Int, minute: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let reference = calendar.date(
            from: DateComponents(year: 2001, month: 1, day: 1, hour: hour, minute: minute)
        )
        guard let reference else { return "\(hour):\(minute)" }
        return reference.formatted(date: .omitted, time: .shortened)
    }

    /// A tiny real PNG, so the read path resolves actual pixels.
    private static let pixelPNG = PixelFixture.png

    /// A clock that advances a fixed step per read. Step 0 pins time, which is
    /// what nearly every test here wants; the ticker test uses one second.
    ///
    /// `StepClock` and `FixedScheduler` now live in `TestSupport.swift` —
    /// three suites need them and three copies is three places to miss when
    /// `MomentScheduler` grows a method. The one here used to count ticks from
    /// zero and this one advances by `step`; the shared version does the latter,
    /// which is the same thing at step 0 and the more obvious one otherwise.
    private typealias StepClock = TestSupport.Clock
    private typealias FixedScheduler = TestSupport.Scheduler

    private struct Harness {
        let environment: AppEnvironment
        let notifications: InMemoryNotificationService
        let library: InMemoryPhotoLibraryService
        let store: MomentStore
    }

    /// Noon and 14:00 on a fixed day. The moment is always at 14:00; each test
    /// chooses the instant it is asking about.
    private func dayAndStart(on day: String = "2026-09-30") throws -> (noon: Date, momentStart: Date) {
        let identifier = try #require(DayIdentifier(string: day))
        return (
            identifier.date.addingTimeInterval(12 * 3600),
            identifier.date.addingTimeInterval(14 * 3600)
        )
    }

    private func makeHarness(
        now: Date,
        momentStart: Date,
        notificationsAuthorized: Bool = true
    ) throws -> Harness {
        let notifications = InMemoryNotificationService()
        notifications.setAuthorization(
            notificationsAuthorized ? .authorized : .denied
        )
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let environment = try AppEnvironment(
            container: try Persistence.inMemoryContainer(),
            momentScheduler: FixedScheduler(start: momentStart),
            notificationService: notifications,
            photoLibrary: library,
            captureService: InMemoryCaptureService()
        )
        // Pin the day so `interval(for:)` never has to reach the scheduler.
        // It also proves a persisted day is honoured over a re-derivation, which
        // is what stops a mid-day window change moving a notification that has
        // already been scheduled (TRD §4.1).
        try environment.momentStore.saveDayRecord(
            day: DayIdentifier(date: now), momentStart: momentStart
        )

        return Harness(
            environment: environment,
            notifications: notifications,
            library: library,
            store: environment.momentStore
        )
    }

    private func makeModel(
        _ harness: Harness,
        at instant: Date,
        step: TimeInterval = 0
    ) -> TodayViewModel {
        let clock = StepClock(origin: instant, step: step)
        return TodayViewModel(environment: harness.environment, now: { clock.now() })
    }

    /// Records a moment and writes its photographs to the in-memory library, so
    /// the read path has something real to resolve.
    @discardableResult
    private func record(
        _ harness: Harness,
        on day: DayIdentifier,
        capturedAt: Date
    ) async throws -> Moment {
        let start = day.date.addingTimeInterval(14 * 3600)
        _ = try await harness.library.saveMomentPair(
            backData: Self.pixelPNG, frontData: Self.pixelPNG, location: nil
        )
        let pair = try #require(harness.library.latestPair)
        return try harness.store.record(
            day: day,
            interval: MomentInterval(start: start, end: start.addingTimeInterval(120)),
            capturedAt: capturedAt,
            retakeCount: 0,
            backAssetIdentifier: pair.back,
            frontAssetIdentifier: pair.front
        )
    }

    // MARK: - The four states

    @Test("Before the window opens the screen is scheduled")
    func scheduledState() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        let model = makeModel(harness, at: start.addingTimeInterval(-3600))
        await model.reload()

        #expect(model.state == .scheduled)
        // Was `!model.state.allowsCapture` with the message "FR-5: no capture
        // before momentStart" — the early-post refusal, now ADR-023. There is no
        // predicate left to assert: the shutter renders in every state, and the
        // state cannot say otherwise.
        #expect(!model.showsMomentTime)
        #expect(model.timeUntilMoment == nil)
    }

    @Test("Inside the window the state is open, and still no time is shown")
    func openState() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        let model = makeModel(harness, at: start.addingTimeInterval(30))
        await model.reload()

        #expect(model.state == .open)
        // The window being open changes what the screen *says*, not what it
        // reveals. "It's time" is not a deadline, and nothing counts down to
        // its end.
        #expect(!model.showsMomentTime)
    }

    @Test("The moment time is a secret while notifications are on")
    func timeIsHiddenWhileNotificationsAreOn() async throws {
        // The core of ADR-024: with notifications authorised, the notification
        // is the alert, and naming the hour would spend the surprise for
        // nothing. The two are the same information delivered twice.
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(
            now: now, momentStart: start, notificationsAuthorized: true
        )
        let model = makeModel(harness, at: start.addingTimeInterval(-3600))
        await model.reload()

        #expect(!model.showsMomentTime)
        #expect(model.timeUntilMoment == nil)
        // The value is still computed — the caller asks first. Keeping the
        // formatting separate means the tests can check the number without also
        // having to stand up a notification state to see it.
        //
        // **Compared against the device's own rendering of 14:00, not the
        // literal `"14:00"`.** `momentClockTime` used to be `"HH:mm"` and this
        // test pinned that, which meant it enforced a 24-hour clock on every
        // user regardless of Settings while the assertion read as though it were
        // testing *that the time is 14:00*. It never was. The fact under test is
        // "the moment's clock time, in the user's format" — so the expectation
        // now computes that and compares.
        #expect(model.momentClockTime == Self.formattedClockTime(14, minute: 0),
                "got \(model.momentClockTime)")
    }

    @Test("The moment time is shown when notifications are off")
    func timeIsShownWhenNotificationsAreOff() async throws {
        // Because then it is the only way the user could ever know. Declining
        // notifications must not mean keeping the app open all day hoping.
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(
            now: now, momentStart: start, notificationsAuthorized: false
        )
        let model = makeModel(harness, at: start.addingTimeInterval(-3600))
        await model.reload()

        #expect(model.showsMomentTime)
        #expect(model.momentClockTime == Self.formattedClockTime(14, minute: 0),
                "got \(model.momentClockTime)")
        #expect(model.timeUntilMoment == 3600, "an hour out")
    }

    @Test("No time is shown once the moment has passed")
    func timeDisappearsAfterTheMoment() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(
            now: now, momentStart: start, notificationsAuthorized: false
        )
        let model = makeModel(harness, at: start.addingTimeInterval(600))
        await model.reload()

        // Repeating a time that has passed is noise, not information.
        #expect(model.showsMomentTime, "the value is still available")
        #expect(model.timeUntilMoment == nil, "but nothing is counting down to it")
    }

    @Test("After the window the state is windowPassed, not late")
    func windowPassedState() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        let model = makeModel(harness, at: start.addingTimeInterval(600))
        await model.reload()

        #expect(model.state == .windowPassed)
        // Was `.lateAvailable` with a `LateBadge("late")` above "The streak will
        // not grow". Both said the same thing twice, and ADR-023 ruled out both:
        // the two minutes ended, nothing was lost, and the streak was not
        // touched. What is left is a fact and an invitation.
    }

    @Test("A captured moment shows captured, and offers a re-capture")
    func capturedState() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        try await record(
            harness, on: DayIdentifier(date: now), capturedAt: start.addingTimeInterval(20)
        )

        let model = makeModel(harness, at: start.addingTimeInterval(30))
        await model.reload()

        #expect(model.state.isCaptured)
        #expect(model.shutterTitle == "Capture again", "re-capture replaces the day (ADR-011)")
        #expect(model.streak == 1)
    }

    @Test("An off-window moment is a first-class entry that grows nothing")
    func capturedOffWindowState() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        try await record(
            harness, on: DayIdentifier(date: now),
            capturedAt: start.addingTimeInterval(1800)   // 28 minutes after close
        )

        let model = makeModel(harness, at: start.addingTimeInterval(1800))
        await model.reload()

        // The screen is told exactly one thing: you captured today. It is not
        // told whether that counted, because `MomentState.captured` does not
        // know — and neither, now, can any view.
        #expect(model.state.isCaptured, "an off-window moment is an entry, not a failure")
        #expect(model.streak == 0, "and it does not grow the streak (ADR-023)")
        // The distinction is still recorded, and still computed honestly — it is
        // simply not on this screen.
        #expect(model.summary.lateMoments == 1)
    }

    @Test("The screen cannot tell an on-time moment from an off-window one")
    func theScreenCannotSeeLateness() async throws {
        // Two harnesses with identical capture behaviour — same day, same
        // photographs, same shutter — differing only in *when* the shutter
        // fired. Every value the Today screen reads is the same. This is
        // ADR-023 decision 3 asserted at the view-model boundary, where the old
        // badge was actually rendered.
        //
        // Same day on purpose. Using two different days would have made the
        // photographs differ, and then the assertion would pass for the wrong
        // reason: it would be testing "two days look alike" rather than "an
        // on-time moment looks like an off-window one".
        let (now, start) = try dayAndStart()
        let today = DayIdentifier(date: now)

        // Inside the two minutes.
        let onTime = try makeHarness(now: now, momentStart: start)
        try await record(
            onTime, on: today, capturedAt: start.addingTimeInterval(20)
        )
        let onTimeModel = makeModel(onTime, at: start.addingTimeInterval(30))
        await onTimeModel.reload()

        // Half an hour after it closed.
        let offWindow = try makeHarness(now: now, momentStart: start)
        try await record(
            offWindow, on: today, capturedAt: start.addingTimeInterval(1800)
        )
        let offWindowModel = makeModel(offWindow, at: start.addingTimeInterval(1800))
        await offWindowModel.reload()

        // Preconditions, so a failure below cannot be a false alarm.
        #expect(onTimeModel.todayMoment?.isOnTime == true)
        #expect(offWindowModel.todayMoment?.isOnTime == false)
        #expect(onTimeModel.summary.lateMoments == 0)
        #expect(offWindowModel.summary.lateMoments == 1)

        // And the screen cannot tell them apart.
        #expect(onTimeModel.state == offWindowModel.state)
        #expect(onTimeModel.shutterTitle == offWindowModel.shutterTitle)
        #expect(onTimeModel.todayImages != nil)
        #expect(offWindowModel.todayImages != nil)
        #expect(onTimeModel.todayMissingFromPhotos == offWindowModel.todayMissingFromPhotos)

        // The only difference, and it is a number rather than a message.
        #expect(onTimeModel.streak == 1)
        #expect(offWindowModel.streak == 0)
    }

    // MARK: - Reading the photographs back

    @Test("Reload resolves today's pair out of the user's library")
    func reloadLoadsTodaysImages() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        try await record(
            harness, on: DayIdentifier(date: now), capturedAt: start.addingTimeInterval(20)
        )

        let model = makeModel(harness, at: start.addingTimeInterval(30))
        await model.reload()

        let images = try #require(model.todayImages)
        #expect(images.large.size.width > 0)
        #expect(!model.todayMissingFromPhotos)
    }

    @Test("Photographs the user deleted are reported, not rendered as a blank")
    func missingPhotographsAreReported() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        let moment = try await record(
            harness, on: DayIdentifier(date: now), capturedAt: start.addingTimeInterval(20)
        )

        // The user deleted them in Photos. Memoree never reached back in to
        // prevent that, or to reverse it (ADR-008).
        let pair = try #require(harness.library.latestPair)
        harness.library.markMissing(pair.back, pair.front)

        let model = makeModel(harness, at: start.addingTimeInterval(30))
        await model.reload()

        #expect(model.todayImages == nil)
        #expect(model.todayMissingFromPhotos)
        // The moment itself is untouched: captured, on record, its photographs
        // simply no longer in a library that is not Memoree's to manage.
        #expect(!moment.isDeleted)
        #expect(harness.store.allMoments.count == 1)
    }

    @Test("A moment with no photographs on record is not called missing")
    func halfRecordedMomentIsNotCalledMissing() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        // Recorded without ever reaching the library — what a crash between the
        // two commit steps leaves behind. It is incomplete, not missing, and
        // must not be described to the user as if they had deleted something.
        _ = try harness.store.record(
            day: DayIdentifier(date: now),
            interval: MomentInterval(start: start, end: start.addingTimeInterval(120)),
            capturedAt: start.addingTimeInterval(20),
            retakeCount: 0,
            backAssetIdentifier: nil,
            frontAssetIdentifier: nil
        )

        let model = makeModel(harness, at: start.addingTimeInterval(30))
        await model.reload()

        #expect(model.state.isCaptured)
        #expect(model.todayImages == nil)
        #expect(!model.todayMissingFromPhotos)
    }

    // MARK: - Diagnostics

    @Test("Declined notifications are a state, not an error")
    func declinedNotifications() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(
            now: now, momentStart: start, notificationsAuthorized: false
        )
        let model = makeModel(harness, at: start.addingTimeInterval(30))
        await model.reload()

        #expect(!model.notificationsAuthorized)
        // And the ritual still works. With no server nothing can re-notify the
        // user later, so the app has to be fully usable without it (TRD §9).
        #expect(model.state == .open)
        // What replaces the removed countdown is the time being *shown*,
        // because with no notification this is the user's only way of learning
        // when the moment is (ADR-024).
        #expect(model.showsMomentTime)
    }

    @Test("The pending count is reported for the diagnostics footer")
    func pendingCountIsReported() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        harness.notifications.setPendingIdentifiers(["moment.2026-09-30", "moment.2026-10-01"])

        let model = makeModel(harness, at: start)
        await model.reload()

        #expect(model.pendingNotificationCount == 2)
    }

    // MARK: - The clock

    @Test("The ticker re-derives from the clock and nothing else")
    func ticking() async throws {
        let (now, start) = try dayAndStart()
        // Notifications off, so there is a countdown to move — the only
        // configuration in which one exists (ADR-024).
        let harness = try makeHarness(
            now: now, momentStart: start, notificationsAuthorized: false
        )
        // One second per read, so a real tick moves it by one. An hour out.
        let model = makeModel(harness, at: start.addingTimeInterval(-3600), step: 1)
        #expect(model.timeUntilMoment == 3600)

        model.startTicking()
        defer { model.stopTicking() }

        try await Task.sleep(for: .milliseconds(2100))
        #expect(model.now > start.addingTimeInterval(-3600), "the clock advanced")
        // The time remaining must have moved with it, and must not be stuck on
        // the value from construction.
        #expect(model.timeUntilMoment ?? 0 < 3600)
    }

    @Test("The ticker keeps the surprise intact")
    func tickingDoesNotLeakTheTime() async throws {
        // The regression that matters: a once-a-second refresh is exactly the
        // kind of thing that quietly reintroduces a countdown. Asserted
        // *after* the tick, not only at construction.
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(
            now: now, momentStart: start, notificationsAuthorized: true
        )
        let model = makeModel(harness, at: start.addingTimeInterval(-3600), step: 1)
        // Read the notification state first. `showsMomentTime` is derived from
        // it, and the initialiser does not fetch it — a fresh model assumes
        // notifications are off, which is the pessimistic direction and the
        // right default for a screen that has not yet asked.
        await model.reload()
        #expect(!model.showsMomentTime, "precondition: notifications are on")

        model.startTicking()
        defer { model.stopTicking() }
        try await Task.sleep(for: .milliseconds(2100))

        #expect(!model.showsMomentTime)
        #expect(model.timeUntilMoment == nil)
    }
}
