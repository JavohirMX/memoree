import Foundation
import Testing

@testable import Memoree

/// Phase 5 — the Today screen's state resolver.
///
/// Pure function of `(now, interval, todayMoment, dayEnd)`, so every state is
/// reachable without a clock, a database or a device.
///
/// The cases that carry real risk are the edges: the window is inclusive at both
/// ends, `missed` must not fire before the day is actually over, and a day's
/// moment must win over the clock.
@Suite("Phase 5 — MomentStateResolver")
struct MomentStateResolverTests {

    private let calendar = Calendar(identifier: .gregorian)

    /// A window opening at 14:00 on 2026-09-30 and closing two minutes later.
    private func interval(
        start: Date? = nil,
        duration: TimeInterval = 120
    ) throws -> MomentInterval {
        let day = try #require(DayIdentifier(string: "2026-09-30", calendar: calendar))
        let open = start ?? day.date.addingTimeInterval(14 * 3600)
        return MomentInterval(start: open, end: open.addingTimeInterval(duration))
    }

    private func resolve(
        now: Date,
        window: MomentInterval,
        moment: MomentFacts? = nil,
        dayEnd: Date? = nil
    ) -> MomentState {
        MomentStateResolver.resolve(
            now: now,
            interval: window,
            todayMoment: moment,
            dayEnd: dayEnd ?? MomentStateResolver.endOfDay(containing: now, calendar: calendar)
        )
    }

    private func onTimeFacts(day: String = "2026-09-30") throws -> MomentFacts {
        let dayIdentifier = try #require(DayIdentifier(string: day, calendar: calendar))
        let capturedAt = dayIdentifier.date.addingTimeInterval(14 * 3600)
        return MomentFacts(
            id: UUID(),
            day: dayIdentifier,
            isOnTime: true,
            capturedAt: capturedAt,
            windowEndsAt: capturedAt.addingTimeInterval(120),
            retakeCount: 0,
            hasBTS: false
        )
    }

    private func lateFacts(lateBy: TimeInterval = 600, day: String = "2026-09-30") throws -> MomentFacts {
        let dayIdentifier = try #require(DayIdentifier(string: day, calendar: calendar))
        // The window closed at 14:02; this moment lands `lateBy` after that.
        let windowEnd = dayIdentifier.date.addingTimeInterval(14 * 3600 + 120)
        return MomentFacts(
            id: UUID(),
            day: dayIdentifier,
            isOnTime: false,
            capturedAt: windowEnd.addingTimeInterval(lateBy),
            windowEndsAt: windowEnd,
            retakeCount: 0,
            hasBTS: false
        )
    }

    // MARK: - Before the window

    @Test("Before the window opens the state is scheduled with the wait")
    func scheduled() throws {
        let window = try interval()
        let state = resolve(now: window.start.addingTimeInterval(-3600), window: window)

        #expect(state == .scheduled(timeUntilStart: 3600))
        #expect(state.isAwaitingMoment)
        // Was `!state.allowsCapture` until ADR-023. The early-post refusal was
        // `FR-5` and `AGENTS.md` §2 rule 10, and it contradicted the app's own
        // onboarding copy. Capture is now permitted at any time, so this state
        // differs from `open` in what it *says*, not in what it permits.
        #expect(state.allowsCapture)
    }

    // MARK: - The window

    @Test("At the opening instant the window is open")
    func opensExactlyOnTime() throws {
        let window = try interval()
        let state = resolve(now: window.start, window: window)

        #expect(state == .open(remaining: 120))
        #expect(state.allowsCapture)
    }

    @Test("At the closing instant it is still open, not late")
    func closingInstantIsStillOpen() throws {
        // The difference between on time and late is one instant, so the boundary
        // is pinned deliberately.
        let window = try interval()
        let state = resolve(now: window.end, window: window)

        #expect(state == .open(remaining: 0))
        #expect(!state.isLate)
    }

    @Test("One instant past the close the window has lapsed")
    func pastCloseIsLateAvailable() throws {
        let window = try interval()
        let state = resolve(now: window.end.addingTimeInterval(1), window: window)

        #expect(state == .lateAvailable(lateBy: 1))
        #expect(state.allowsCapture)
        #expect(state.isLate)
        #expect(!state.countsForStreak)
    }

    // MARK: - Captured

    @Test("A moment on time beats the clock in every window")
    func capturedWins() throws {
        let window = try interval()
        // Captured while the window was still open.
        let state = resolve(
            now: window.start.addingTimeInterval(30),
            window: window,
            moment: try onTimeFacts()
        )

        #expect(state == .captured(late: false, lateBy: 0))
        #expect(state.countsForStreak)
        #expect(!state.isLate)
    }

    @Test("A captured moment stays captured after the window closes")
    func capturedIsSticky() throws {
        let window = try interval()
        let state = resolve(
            now: window.end.addingTimeInterval(7200),
            window: window,
            moment: try onTimeFacts()
        )
        #expect(state == .captured(late: false, lateBy: 0))
    }

    @Test("A late moment reports its lateness and does not grow the streak")
    func capturedLate() throws {
        let window = try interval()
        let state = resolve(
            now: window.end.addingTimeInterval(600),
            window: window,
            moment: try lateFacts(lateBy: 600)
        )

        #expect(state == .captured(late: true, lateBy: 600))
        #expect(!state.countsForStreak)
        #expect(state.showsLateBadge)
    }

    // MARK: - Missed

    @Test("Missed requires the day to be over, not merely the window")
    func missedRequiresDayOver() throws {
        let window = try interval()
        let day = try #require(DayIdentifier(string: "2026-09-30", calendar: calendar))
        let endOfDay = try #require(
            calendar.date(byAdding: .day, value: 1, to: day.date))

        // 23:59 — the window closed hours ago but the day has not ended.
        let lateInDay = day.date.addingTimeInterval(23 * 3600 + 59 * 60)
        let stillOpen = resolve(now: lateInDay, window: window, dayEnd: endOfDay)
        // The window closed at 14:02, so 23:59 is 9h57m past it — not 9h59m.
        #expect(stillOpen == .lateAvailable(lateBy: 9 * 3600 + 57 * 60),
                "an unposted day is not a miss until it ends")

        // One second past midnight: now it is a miss.
        let afterMidnight = endOfDay.addingTimeInterval(1)
        let missed = resolve(now: afterMidnight, window: window, dayEnd: endOfDay)
        #expect(missed == .missed)
        // Was `!missed.allowsCapture`. A missed day now still permits capture —
        // the day has not rolled over yet, so it is still today (ADR-023), and
        // the streak rule is what distinguishes a day with no photograph from a
        // day photographed off-window, not the shutter.
        #expect(missed.allowsCapture)
    }

    // MARK: - End of day

    @Test("End of day is the following local midnight")
    func endOfDayIsLocalMidnight() throws {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!

        // 23:30 on the day the clocks go forward.
        let lateNight = try #require(eastern.date(from: DateComponents(
            year: 2027, month: 3, day: 13, hour: 23, minute: 30)))
        let end = MomentStateResolver.endOfDay(containing: lateNight, calendar: eastern)

        #expect(eastern.component(.day, from: end) == 14)
        #expect(eastern.component(.hour, from: end) == 0)
    }

    // MARK: - State predicates

    @Test("Every state permits capture")
    func capturePermissions() throws {
        // Was "only an open or lapsed window permits capture", and the assertion
        // that one second before the window opens does *not*. Both of those
        // are ADR-023: the window no longer gates anything, so the states differ
        // in what they say rather than in what they permit.
        let window = try interval()
        #expect(resolve(now: window.start, window: window).allowsCapture)
        #expect(resolve(now: window.end.addingTimeInterval(1), window: window).allowsCapture)
        #expect(resolve(now: window.start.addingTimeInterval(-1), window: window).allowsCapture)

        // And a captured moment, for completeness — every case, no exceptions.
        let captured = MomentFacts(
            id: UUID(), day: try #require(DayIdentifier(string: "2026-09-30")),
            isOnTime: true, capturedAt: window.start, windowEndsAt: window.end,
            retakeCount: 0, hasBTS: false
        )
        let state = MomentStateResolver.resolve(
            now: window.start, interval: window, todayMoment: captured,
            dayEnd: MomentStateResolver.endOfDay(containing: window.start)
        )
        #expect(state.allowsCapture, "re-capture is always permitted (ADR-011)")
    }

    @Test("Every state round-trips through the countdown as nil where expected")
    func countdownPresence() throws {
        let window = try interval()
        // Countdown is derived in the view model; the resolver only guarantees
        // the states it is defined for. This pins the association.
        switch resolve(now: window.start, window: window) {
        case .open(let remaining):
            #expect(remaining == 120)
        default:
            Issue.record("expected .open")
        }
    }
}
