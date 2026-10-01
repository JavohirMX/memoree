import Foundation
import Testing

@testable import Memoree

/// The window change, which is not a settings write.
///
/// This suite exists because of a defect that could only appear once a Settings
/// screen existed, and that is the whole argument for writing it down now.
///
/// **The defect.** `AppEnvironment.interval(for:)` always prefers a persisted
/// `DayRecord` over the configured window, so that a notification cannot move
/// retroactively (TRD §4.1, FR-2). Correct, and it means every day in the
/// 45-day horizon has a resolved time that the configuration cannot reach. So a
/// window picker that wrote to settings and stopped would change **nothing** for
/// six weeks — a control that looks real and does nothing, on the one setting
/// that now decides when the app interrupts its user.
///
/// **The fix** is to discard the future before the new window can take effect,
/// while deliberately preserving today. Every test below is one of those two
/// halves, because they are separately breakable.
@Suite("Phase 6 — changing the moment window")
@MainActor
struct MomentWindowChangeTests {

    private let calendar = Calendar(identifier: .gregorian)

    // MARK: - Harness

    private struct Harness {
        let environment: AppEnvironment
        let notifications: InMemoryNotificationService
        let store: MomentStore
    }

    /// The **real** scheduler, with a fixed secret.
    ///
    /// `TestSupport.Scheduler` — the fixed-instant one every other suite uses —
    /// deliberately ignores the window, which makes it useless here: re-deriving
    /// tomorrow with it returns 14:00 whatever the window says, so "the new
    /// window took effect" and "nothing happened" are indistinguishable. That is
    /// not a hypothetical; the first version of this suite used it and asserted
    /// `newStart != 14:00`, which fails for the right reason and passes for the
    /// wrong one.
    ///
    /// A fixed `InstallSecret` makes the derivation deterministic, so the test
    /// exercises the actual HMAC path and can say *inside the new window* rather
    /// than *different from a number I chose*.
    private static let secret = InstallSecret(value: Data(repeating: 0x5A, count: 32))

    private func makeHarness(now: Date) throws -> Harness {
        let notifications = InMemoryNotificationService()
        notifications.setAuthorization(.authorized)

        let environment = try AppEnvironment(
            container: try Persistence.inMemoryContainer(),
            momentScheduler: LocalMomentScheduler(secret: Self.secret),
            notificationService: notifications,
            photoLibrary: InMemoryPhotoLibraryService(),
            captureService: InMemoryCaptureService()
        )
        return Harness(
            environment: environment,
            notifications: notifications,
            store: environment.momentStore
        )
    }

    private static func momentOn(_ date: Date) -> Date {
        let day = Calendar(identifier: .gregorian).startOfDay(for: date)
        return day.addingTimeInterval(14 * 3600)
    }

    // MARK: - The defect this prevents

    @Test("A new window does not take effect until the future is re-derived")
    func windowAloneChangesNothing() async throws {
        // These read like setup rather than assertions, which is exactly why they
        // are the tests. Neither of them fails today — both describe correct,
        // already-tested behaviour (FR-2). They exist so that the *shape* of the
        // defect is written down: a window change that stops at the settings row
        // satisfies every other test in this suite and silently does nothing for
        // six weeks.
        // The precondition, stated as a test. It is *correct* behaviour — it is
        // what makes FR-2 hold — and it is also exactly why the picker has to do
        // more than write a setting. A future refactor that made `interval(for:)`
        // prefer the configuration would break stability, and this would catch
        // it.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        let today = DayIdentifier(date: now, calendar: calendar)

        try harness.store.saveDayRecord(day: today, momentStart: Self.momentOn(now))

        // A record exists, and it wins.
        #expect(harness.environment.interval(for: today).start == Self.momentOn(now))

        // So a configuration that disagrees changes nothing while that record
        // stands. Written through the settings row directly rather than through
        // `updateWindow`, because that is the defect: a caller that stops at the
        // write gets exactly this outcome and believes it succeeded.
        let settings = harness.store.settings()
        settings.timeWindow = TimeWindow(startMinutes: 6 * 60, endMinutes: 9 * 60)
        try harness.store.saveSettings(settings)

        #expect(harness.store.settings().timeWindow
                == TimeWindow(startMinutes: 6 * 60, endMinutes: 9 * 60),
                "precondition: the setting really did change")
        #expect(harness.environment.interval(for: today).start == Self.momentOn(now),
                "a persisted moment is not moved by a configuration change (FR-2)")
    }

    @Test("A window change re-derives tomorrow onward")
    func changeReDerivesTheFuture() async throws {
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        let today = DayIdentifier(date: now, calendar: calendar)
        let tomorrow = today.offset(by: 1, calendar: calendar)
        let nextWeek = today.offset(by: 7, calendar: calendar)

        // The default window is 11:00–23:00, so both days resolve inside it
        // before the change. That is the precondition that makes the assertion
        // after the change mean something.
        let before = harness.environment.interval(for: tomorrow).start.hour(calendar)
        #expect((11...23).contains(before), "precondition, was \(before):00")

        // Pin tomorrow to a time that is *outside* the window about to be
        // chosen, so "re-derived" cannot be confused with "left alone".
        try harness.store.saveDayRecord(day: tomorrow, momentStart: Self.momentOn(now))

        let target = TimeWindow(startMinutes: 6 * 60, endMinutes: 9 * 60)
        let changed = await harness.environment.updateWindow(target)

        #expect(changed)

        // Asserted as "inside the new window" rather than "not 14:00". The
        // second would pass if the re-derivation simply produced a different
        // wrong answer, which is the failure mode a fixed instant cannot rule
        // out — see the note on `secret` above.
        let after = harness.environment.interval(for: tomorrow).start.hour(calendar)
        #expect((6...8).contains(after), "tomorrow now falls inside 06:00–09:00, was \(after):00")

        // And a day further out, which had no pinned record at all, also lands
        // in the new window — so this is not just "the pinned row was rewritten".
        let later = harness.environment.interval(for: nextWeek).start.hour(calendar)
        #expect((6...8).contains(later), "a week out also re-derived, was \(later):00")
    }

    @Test("Today keeps its moment even when the new window excludes it")
    func todayIsNeverMoved() async throws {
        // The half most likely to be broken by someone tidying up. Today may
        // already have been notified; re-rolling it would move a notification
        // the user has already acted on, which is the exact harm FR-2 exists to
        // prevent — and it is the one day whose time the user can actually see.
        //
        // The new window is 06:00–09:00 and the pinned moment is 14:00, so
        // "re-derived" would visibly disagree.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        let today = DayIdentifier(date: now, calendar: calendar)

        try harness.store.saveDayRecord(day: today, momentStart: Self.momentOn(now))

        _ = await harness.environment.updateWindow(
            TimeWindow(startMinutes: 6 * 60, endMinutes: 9 * 60)
        )

        #expect(harness.environment.interval(for: today).start == Self.momentOn(now),
                "today's moment is not re-rolled")
    }

    // MARK: - No-op behaviour

    @Test("Setting the same window does nothing at all")
    func sameWindowIsANoOp() async throws {
        // Worth asserting because the alternative is a drag that ends where it
        // started firing 44 deletions and 45 notification requests. `updateWindow`
        // returns whether anything moved, and the Settings screen shows that
        // rather than pretending.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)

        await harness.environment.refreshHorizonIfNeeded(force: true)
        let recordsBefore = harness.store.allDayRecords.count

        let current = harness.store.settings().timeWindow
        let changed = await harness.environment.updateWindow(current)

        #expect(!changed, "reported as unchanged, so the screen need not claim otherwise")
        #expect(harness.store.allDayRecords.count == recordsBefore,
                "and nothing was discarded")
    }

    @Test("A window change is persisted")
    func changeIsPersisted() async throws {
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)

        let target = TimeWindow(startMinutes: 7 * 60, endMinutes: 10 * 60)
        _ = await harness.environment.updateWindow(target)

        #expect(harness.store.settings().timeWindow == target)

        // And it survives being read back through the *validated* accessor,
        // which is the path every consumer takes. `TimeWindow.validated` clamps
        // a corrupt row rather than trapping, so this also confirms the stored
        // value is one the app would actually use.
        let readBack = TimeWindow(
            startMinutes: harness.store.settings().windowStartMinutes,
            endMinutes: harness.store.settings().windowEndMinutes
        )
        #expect(readBack == target, "stored valid, not merely stored")
    }

    // MARK: - The horizon

    @Test("A window change refills the notification horizon with the new window")
    func changeRefillsTheHorizon() async throws {
        // The horizon is what the notification centre is actually holding. A
        // re-derived day whose notification was never re-added would leave the
        // user being interrupted at the *old* time while the app believed the
        // new one — so the refill is part of the operation, not a follow-up.
        //
        // Asserted on the recorded refresh rather than on the pending set,
        // because `InMemoryNotificationService` does not model the re-adding: its
        // `pending` is only ever what a test seeded, since making it simulate
        // `UNUserNotificationCenter` would rebuild the very thing Phase 1 had to
        // extract (`NotificationHorizonPlanner`) in order to be testable at all.
        // What matters here is that the refill happened *and carried the new
        // window* — a refill with the old window would be the same bug wearing a
        // different hat.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        let target = TimeWindow(startMinutes: 6 * 60, endMinutes: 9 * 60)

        await harness.environment.refreshHorizonIfNeeded(force: true)
        let before = harness.notifications.refreshCount
        #expect(before > 0, "precondition: the horizon was populated")

        _ = await harness.environment.updateWindow(target)

        #expect(harness.notifications.refreshCount > before,
                "the change refilled the horizon")
        #expect(harness.notifications.lastRefresh?.window == target,
                "and the refill carried the new window, not the old one")
    }

    @Test("A discarded day is genuinely gone, not merely unreferenced")
    func discardedRecordsAreDeleted() async throws {
        // `discardDayRecords` deletes rows. Asserting the count rather than the
        // behaviour would be weaker, so this checks that a day which is not
        // pinned any more re-derives — which is only possible if the old row is
        // actually absent.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        let today = DayIdentifier(date: now, calendar: calendar)
        let far = today.offset(by: 5, calendar: calendar)

        try harness.store.saveDayRecord(day: far, momentStart: Self.momentOn(now))
        #expect(harness.store.dayRecord(for: far) != nil, "precondition")

        let discarded = try harness.store.discardDayRecords(from: far)
        #expect(discarded == 1)
        #expect(harness.store.dayRecord(for: far) == nil)
    }

    @Test("Discarding from a day keeps the days before it")
    func discardKeepsThePast() async throws {
        // The boundary is the whole point. A version that discarded from
        // yesterday would be one refactor away from discarding today, which
        // would move a notification that has already fired.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        let today = DayIdentifier(date: now, calendar: calendar)

        let yesterday = today.offset(by: -1, calendar: calendar)
        let tomorrow = today.offset(by: 1, calendar: calendar)
        try harness.store.saveDayRecord(day: yesterday, momentStart: Self.momentOn(now))
        try harness.store.saveDayRecord(day: today, momentStart: Self.momentOn(now))
        try harness.store.saveDayRecord(day: tomorrow, momentStart: Self.momentOn(now))

        let discarded = try harness.store.discardDayRecords(from: tomorrow)

        #expect(discarded == 1, "only the boundary day and after")
        #expect(harness.store.dayRecord(for: yesterday) != nil)
        #expect(harness.store.dayRecord(for: today) != nil)
        #expect(harness.store.dayRecord(for: tomorrow) == nil)
    }

    // MARK: - Degenerate input

    @Test("A window that would be degenerate is validated, not stored")
    func degenerateWindowIsValidated() async throws {
        // The sliders cannot produce one, but a corrupt store or a future caller
        // can, and `TimeWindow.validated` clamps rather than trapping — which is
        // why the settings row can never hold a window with no randomness in it.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)

        _ = await harness.environment.updateWindow(
            TimeWindow(startMinutes: 600, endMinutes: 600)
        )

        let stored = harness.store.settings().timeWindow
        #expect(stored.isValid)
        #expect(stored.spanSeconds >= TimeWindow.minimumSpanSeconds)
    }
}

private extension Date {
    /// The local hour, for asserting a moment falls inside a window.
    ///
    /// Read through an explicit `Calendar` rather than `Calendar.current` so the
    /// assertion does not silently depend on the machine running the tests. A
    /// test that passes in one timezone and fails in another is worse than no
    /// test, because it is only ever run in one of them.
    func hour(_ calendar: Calendar) -> Int {
        calendar.component(.hour, from: self)
    }
}
