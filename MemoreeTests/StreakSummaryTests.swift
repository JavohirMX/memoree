import Foundation
import Testing

@testable import Memoree

/// Phase 7 — Stats.
///
/// **This phase's debt, paid.** `StreakCalculator.summary` has computed every
/// field on this screen since Phase 2, and `StreakSummary` is a `Sendable` value
/// type with an initialiser anyone can call. So for five months there was a whole
/// statistics layer with **nothing asserting on most of its output** — the
/// fields existed, and no test would have noticed if `onTimePercentage` started
/// returning nonsense.
///
/// Two halves, and the split is the point:
///
/// - **`StreakSummaryTests`** pins the arithmetic, which is where a wrong number
///   is a wrong number.
/// - **`StatsViewModelTests`** pins the *decisions* — which rows appear, when a
///   row is hidden, and how a number is phrased. These are the ones that were
///   never anyone's job, and they are where this phase's actual choices live.
@Suite("Phase 7 — stats arithmetic")
struct StreakSummaryTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func facts(
        _ day: String,
        onTime: Bool = true,
        retakes: Int = 0,
        hour: Int = 12
    ) throws -> MomentFacts {
        let identifier = try #require(DayIdentifier(string: day, calendar: calendar))
        let capturedAt = identifier.date.addingTimeInterval(Double(hour) * 3600)
        return MomentFacts(
            id: UUID(),
            day: identifier,
            isOnTime: onTime,
            capturedAt: capturedAt,
            windowEndsAt: capturedAt.addingTimeInterval(120),
            retakeCount: retakes,
            hasBTS: false
        )
    }

    // MARK: - Fields nothing asserted on until now

    @Test("Summary counts moments and days captured")
    func summaryCountsMoments() throws {
        let summary = StreakCalculator.summary(
            facts: [
                try facts("2026-09-28"),
                try facts("2026-09-29"),
                try facts("2026-09-30", onTime: false),
                try facts("2026-10-01", onTime: false)
            ],
            today: try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)),
            calendar: calendar
        )

        #expect(summary.totalMoments == 4)
        #expect(summary.daysCaptured == 4)
        #expect(summary.currentStreak == 4)
    }

    @Test("Average retakes is the mean, and is zero rather than NaN with no history")
    func averageRetakes() throws {
        let empty = StreakCalculator.summary(
            facts: [],
            today: try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)),
            calendar: calendar
        )
        #expect(empty.averageRetakes == 0, "not NaN, and not a crash")

        let some = StreakCalculator.summary(
            facts: [
                try facts("2026-09-29", retakes: 0),
                try facts("2026-09-30", retakes: 3)
            ],
            today: try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)),
            calendar: calendar
        )
        #expect(abs(some.averageRetakes - 1.5) < 0.0001)
    }

    @Test("Busiest hour is the mode of the capture hour, in local time")
    func busiestHour() throws {
        let summary = StreakCalculator.summary(
            facts: [
                try facts("2026-09-27", hour: 9),
                try facts("2026-09-28", hour: 9),
                try facts("2026-09-29", hour: 9),
                try facts("2026-09-30", hour: 21)
            ],
            today: try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)),
            calendar: calendar
        )
        #expect(summary.busiestHour == 9)
    }

    @Test("Busiest hour is nil with no history, not zero")
    func busiestHourIsNilWhenEmpty() throws {
        // Zero would be a real claim — midnight — and it would be a false one.
        let empty = StreakCalculator.summary(
            facts: [],
            today: try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)),
            calendar: calendar
        )
        #expect(empty.busiestHour == nil)
    }

    @Test("Missed days counts days with nothing, which is the only thing that breaks a streak")
    func missedDaysCountsEmpties() throws {
        // The label matters as much as the number. Under ADR-023 an off-window
        // day is *not* a miss, so a history of five moments with two off-window
        // among them still reports zero missed days — and this asserts the
        // arithmetic agrees with the rule the streak walk uses.
        let summary = StreakCalculator.summary(
            facts: [
                try facts("2026-09-26"),
                try facts("2026-09-27", onTime: false),
                try facts("2026-09-28"),
                try facts("2026-09-29", onTime: false),
                try facts("2026-09-30")
            ],
            today: try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)),
            calendar: calendar
        )

        #expect(summary.daysCaptured == 5)
        #expect(summary.missedDays == 0, "no day was empty")
        #expect(summary.currentStreak == 5, "all five captured days count toward streak")
    }

    @Test("The summary never reports a longest below the current streak")
    func longestIsNeverBelowCurrent() throws {
        // A property, not an example. `currentStreak` skips off-window days and
        // `longestStreak` counts any moment, so with a gapless history the
        // longest equals the span while the current counts only the on-time
        // days. Reversing either rule would put "best 2" beside a streak of 3 on
        // the Today footer, which is the bug ADR-023's item 5 was about.
        //
        // Swept rather than fixture-based: the shape that breaks it is a
        // one-in-many pattern, and a single fixture is a fixture that happened
        // to pass.
        for length in 1...64 {
            for offWindowStride in [2, 3, 4, 7] {
                var history: [MomentFacts] = []
                var day = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar))
                for index in 0..<length {
                    day = day.offset(by: -1, calendar: calendar)
                    let identifier = day
                    let capturedAt = identifier.date.addingTimeInterval(12 * 3600)
                    history.append(MomentFacts(
                        id: UUID(),
                        day: identifier,
                        isOnTime: index % offWindowStride != 0,
                        capturedAt: capturedAt,
                        windowEndsAt: capturedAt.addingTimeInterval(120),
                        retakeCount: 0,
                        hasBTS: false
                    ))
                }

                let summary = StreakCalculator.summary(
                    facts: history,
                    today: try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)),
                    calendar: calendar
                )

                let shape = "length \(length), stride \(offWindowStride)"
                #expect(
                    summary.longestStreak >= summary.currentStreak,
                    "best \(summary.longestStreak) under current \(summary.currentStreak) — \(shape)"
                )
            }
        }
    }
}
