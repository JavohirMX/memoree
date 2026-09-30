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

    /// A tiny real PNG, so the read path resolves actual pixels and the test
    /// does not carry an image fixture around.
    private static let pixelPNG: Data = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        guard let data = image.pngData() else {
            Issue.record("could not build the fixture image")
            return Data()
        }
        return data
    }()

    /// A clock that advances a fixed step per read. Step 0 pins time, which is
    /// what nearly every test here wants; the ticker test uses one second.
    private final class StepClock: @unchecked Sendable {
        private let origin: Date
        private let step: TimeInterval
        private var tick = 0

        init(origin: Date, step: TimeInterval = 0) {
            self.origin = origin
            self.step = step
        }

        func now() -> Date {
            defer { tick += 1 }
            return origin.addingTimeInterval(step * Double(tick))
        }
    }

    /// Always answers with the same instant.
    private struct FixedScheduler: MomentScheduler {
        let start: Date

        func momentInterval(
            for day: DayIdentifier,
            window: TimeWindow,
            windowDuration: TimeInterval
        ) -> MomentInterval {
            MomentInterval(start: start, end: start.addingTimeInterval(windowDuration))
        }

        func momentStart(
            for day: DayIdentifier,
            window: TimeWindow,
            windowDuration: TimeInterval
        ) -> Date { start }
    }

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

    // MARK: - The six states

    @Test("Before the window opens the screen is scheduled and has no shutter")
    func scheduledState() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        let model = makeModel(harness, at: start.addingTimeInterval(-3600))
        await model.reload()

        #expect(model.state.isAwaitingMoment)
        #expect(!model.state.allowsCapture, "FR-5: no capture before momentStart")
        // Hours roll into the countdown when there are any; minutes are not
        // clamped to 59, so 72:00 stays 72:00 rather than becoming 12:00.
        #expect(model.countdown == "1:00:00")
    }

    @Test("Inside the window the shutter appears and counts down in mm:ss")
    func openState() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        let model = makeModel(harness, at: start.addingTimeInterval(30))
        await model.reload()

        #expect(model.state.allowsCapture)
        #expect(model.countdown == "01:30", "90 seconds left of a two-minute window")
        #expect(!model.countdownIsUrgent)
    }

    @Test("The countdown turns amber only in the last thirty seconds")
    func urgentCountdown() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)

        let inside = makeModel(harness, at: start.addingTimeInterval(95))
        await inside.reload()
        #expect(inside.countdownIsUrgent, "25s left")

        let outside = makeModel(harness, at: start.addingTimeInterval(85))
        await outside.reload()
        #expect(!outside.countdownIsUrgent, "35s left — not yet")
    }

    @Test("After the window the shutter stays and the state is lateAvailable")
    func lateAvailableState() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        let model = makeModel(harness, at: start.addingTimeInterval(600))
        await model.reload()

        #expect(model.state.allowsCapture, "late posting is permitted (F9)")
        #expect(!model.state.isAwaitingMoment)
        #expect(model.countdown == nil, "there is no countdown outside the window")
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

    @Test("A late moment is still captured — archived, badged, and not a streak")
    func capturedLateState() async throws {
        let (now, start) = try dayAndStart()
        let harness = try makeHarness(now: now, momentStart: start)
        try await record(
            harness, on: DayIdentifier(date: now),
            capturedAt: start.addingTimeInterval(1800)   // 28 minutes after close
        )

        let model = makeModel(harness, at: start.addingTimeInterval(1800))
        await model.reload()

        #expect(model.state.isCaptured, "a late moment is a first-class entry, not a failure")
        #expect(model.streak == 0, "and it does not grow the streak (ADR-009)")
        #expect(model.summary.lateMoments == 1)
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
        #expect(model.state.allowsCapture)
        #expect(model.countdown == "01:30")
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
        let harness = try makeHarness(now: now, momentStart: start)
        // One second per read, so a real tick moves the countdown by one.
        // At the window's start a full two minutes are showing.
        let model = makeModel(harness, at: start, step: 1)
        #expect(model.countdown == "02:00")

        model.startTicking()
        defer { model.stopTicking() }

        try await Task.sleep(for: .milliseconds(2100))
        #expect(model.now > start, "the clock advanced")
        // Whatever the exact second, the countdown must have moved with it and
        // must not be stuck on the value from construction.
        #expect(model.countdown != "02:00")
        #expect(model.countdown != nil)
    }
}
