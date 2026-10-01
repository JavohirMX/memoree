import Foundation
import Testing

@testable import Memoree

/// Phase 5 — the Today screen's state resolver.
///
/// Pure function of `(now, interval, todayMoment)`, so every state is reachable
/// without a clock, a database or a device.
///
/// The cases that carry real risk are the edges: the window is inclusive at both
/// ends, and a day's moment must win over the clock. The third edge — that an
/// on-time and an off-window moment resolve to the *same* state — is ADR-023's
/// structural guarantee, and it is the one that a future edit is most likely to
/// undo by accident.
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
        moment: MomentFacts? = nil
    ) -> MomentState {
        MomentStateResolver.resolve(now: now, interval: window, todayMoment: moment)
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

    private func offWindowFacts(lateBy: TimeInterval = 600, day: String = "2026-09-30") throws -> MomentFacts {
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

    @Test("Before the window opens the state is scheduled")
    func scheduled() throws {
        let window = try interval()
        let state = resolve(now: window.start.addingTimeInterval(-3600), window: window)

        #expect(state == .scheduled)
    }

    // MARK: - The window

    @Test("At the opening instant the window is open")
    func opensExactlyOnTime() throws {
        let window = try interval()
        #expect(resolve(now: window.start, window: window) == .open)
    }

    @Test("At the closing instant it is still open, not lapsed")
    func closingInstantIsStillOpen() throws {
        // The difference between on time and off-window is one instant, so the
        // boundary is pinned deliberately.
        let window = try interval()
        #expect(resolve(now: window.end, window: window) == .open)
    }

    @Test("One instant past the close the window has lapsed")
    func pastCloseIsWindowPassed() throws {
        let window = try interval()
        let state = resolve(now: window.end.addingTimeInterval(1), window: window)

        #expect(state == .windowPassed)
    }

    @Test("A window that lapsed hours ago is still only windowPassed")
    func longAfterCloseIsStillWindowPassed() throws {
        // 23:59, with a window that closed at 14:02. This used to be a second
        // state — `missed` — distinguished by a `dayEnd` argument. It could not
        // be reached in the app: `endOfDay(containing: now)` is always later
        // than `now`, so the `missed` branch never executed, and a day that
        // genuinely ended had already rolled over into tomorrow's `scheduled`.
        //
        // The case is gone rather than made reachable, and this pins what
        // replaced it: an unposted day is not a miss, it is simply a day whose
        // two minutes are over.
        let window = try interval()
        let day = try #require(DayIdentifier(string: "2026-09-30", calendar: calendar))
        let lateInDay = day.date.addingTimeInterval(23 * 3600 + 59 * 60)

        #expect(resolve(now: lateInDay, window: window) == .windowPassed)
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

        #expect(state == .captured)
        #expect(state.isCaptured)
    }

    @Test("A captured moment stays captured after the window closes")
    func capturedIsSticky() throws {
        let window = try interval()
        let state = resolve(
            now: window.end.addingTimeInterval(7200),
            window: window,
            moment: try onTimeFacts()
        )
        #expect(state == .captured)
    }

    // MARK: - The distinction that must not exist

    @Test("An off-window moment resolves to the same state as an on-time one")
    func onTimeAndOffWindowAreIndistinguishable() throws {
        // **The structural guarantee ADR-023 asks for.** The Today screen used
        // to read `late` and `lateBy` off this state and render an amber "posted
        // 12m late" badge above a sentence explaining that the streak had not
        // grown. ADR-023 ruled out both: an off-window moment must look exactly
        // like an on-time one.
        //
        // Rather than delete the branch that rendered them, the payload went —
        // so the view is *unable* to leak the distinction, and this assertion is
        // the one that fails if somebody puts it back.
        let window = try interval()

        let onTime = resolve(
            now: window.start.addingTimeInterval(30),
            window: window,
            moment: try onTimeFacts()
        )
        let offWindow = resolve(
            now: window.end.addingTimeInterval(600),
            window: window,
            moment: try offWindowFacts(lateBy: 600)
        )

        #expect(onTime == offWindow)
        #expect(onTime == .captured)
        #expect(offWindow == .captured)
    }

    @Test("A day's moment wins over the clock at every hour of the day")
    func capturedBeatsEveryOtherState() throws {
        // One moment, five clocks. The day's moment is the only thing that can
        // change the answer, so it has to win every time — including long after
        // the window closed, which is where a stale clock would otherwise show
        // `windowPassed` and invite a second capture of a day already shot.
        let window = try interval()
        let day = try #require(DayIdentifier(string: "2026-09-30", calendar: calendar))
        let moment = try onTimeFacts()

        for hour in [0, 13, 14, 15, 23] {
            let now = day.date.addingTimeInterval(Double(hour) * 3600)
            #expect(resolve(now: now, window: window, moment: moment) == .captured,
                    "the moment must win at \(hour):00")
        }
    }

    // MARK: - Exhaustiveness

    @Test("Exactly four states, and each is reachable")
    func everyStateIsReachable() throws {
        // The enum is payload-free, so a new case is a compile-time break in
        // `TodayView.primaryState` rather than a silently unhandled state. This
        // pins that the four remaining cases are each produced by the resolver
        // rather than declared and never returned.
        let window = try interval()
        let day = try #require(DayIdentifier(string: "2026-09-30", calendar: calendar))
        let moment = try onTimeFacts()

        let produced: Set<MomentState> = [
            resolve(now: day.date.addingTimeInterval(13 * 3600), window: window),
            resolve(now: window.start, window: window),
            resolve(now: window.end.addingTimeInterval(1), window: window),
            resolve(now: window.end, window: window, moment: moment)
        ]

        #expect(produced == [.scheduled, .open, .windowPassed, .captured])
    }
}
