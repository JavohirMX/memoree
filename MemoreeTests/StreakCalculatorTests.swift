import Foundation
import Testing

@testable import Memoree

/// Phase 2 — streak arithmetic.
///
/// Every function here is pure, so the whole suite runs in microseconds with no
/// SwiftData container and no device. The cases that matter most are the two ADR
/// decisions that are easy to conflate:
///
/// - **ADR-023** an off-window day is *transparent* — it neither grows the
///   streak nor ends it. Only a day with **no moment at all** ends the walk.
///   (This reversed ADR-009, which said a late-only day breaks the streak.)
/// - **ADR-010** an unposted *today* does *not* break the streak
///
/// Getting either wrong produces a streak that resets every morning, which
/// users experience as the app being broken.
@Suite("Phase 2 — current streak")
struct CurrentStreakTests {

    private var calendar = Calendar(identifier: .gregorian)

    private func day(_ s: String) throws -> DayIdentifier {
        try #require(DayIdentifier(string: s, calendar: calendar))
    }

    private func facts(_ rows: [(String, Bool)]) -> [MomentFacts] {
        rows.map { row in
            let day = DayIdentifier(string: row.0, calendar: calendar)!
            let capturedAt = day.date.addingTimeInterval(14 * 3600)
            return MomentFacts(
                id: UUID(),
                day: day,
                isOnTime: row.1,
                capturedAt: capturedAt,
                windowEndsAt: capturedAt.addingTimeInterval(120),
                retakeCount: 0,
                hasBTS: false
            )
        }
    }

    private func streak(_ rows: [(String, Bool)], today: String) throws -> Int {
        let f = facts(rows)
        return StreakCalculator.currentStreak(
            onTimeDays: StreakCalculator.onTimeDays(from: f),
            capturedDays: StreakCalculator.capturedDays(from: f),
            today: try day(today),
            calendar: calendar
        )
    }

    // MARK: - Basics

    @Test("A single on-time moment is a streak of one")
    func single() throws {
        #expect(try streak([("2026-09-30", true)], today: "2026-09-30") == 1)
    }

    @Test("Consecutive on-time days accumulate")
    func consecutive() throws {
        #expect(try streak([
            ("2026-09-30", true), ("2026-09-29", true), ("2026-09-28", true)
        ], today: "2026-09-30") == 3)
    }

    @Test("An empty history is zero, not a crash")
    func empty() throws {
        #expect(try streak([], today: "2026-09-30") == 0)
    }

    @Test("A gap stops the run")
    func gapStopsRun() throws {
        // 30th and 28th captured, 29th missed.
        #expect(try streak([("2026-09-30", true), ("2026-09-28", true)], today: "2026-09-30") == 1)
        #expect(try streak([
            ("2026-09-28", true), ("2026-09-27", true), ("2026-09-25", true)
        ], today: "2026-09-28") == 2)
    }

    @Test("A long run does not overflow or truncate")
    func longRun() throws {
        var rows: [(String, Bool)] = []
        let start = try #require(DayIdentifier(string: "2026-01-01", calendar: calendar))
        for offset in 0..<400 {
            rows.append((start.offset(by: offset, calendar: calendar).rawValue, true))
        }
        // 400 days from 2026-01-01 lands on 2027-02-04.
        #expect(try streak(rows, today: "2027-02-04") == 400)
    }

    // MARK: - ADR-010: today is never itself a miss

    @Test("An unposted today leaves yesterday's streak standing")
    func unpostedTodayDoesNotBreak() throws {
        #expect(try streak([
            ("2026-09-29", true), ("2026-09-28", true), ("2026-09-27", true)
        ], today: "2026-09-30") == 3)
    }

    @Test("Only a day with no moment at all is skipped")
    func skipOnlyWhenNothingCaptured() throws {
        let f = facts([("2026-09-29", true)])
        #expect(StreakCalculator.currentStreak(
            onTimeDays: StreakCalculator.onTimeDays(from: f),
            capturedDays: StreakCalculator.capturedDays(from: f),
            today: try day("2026-09-30"), calendar: calendar
        ) == 1)
    }

    // MARK: - ADR-023: an off-window day is transparent

    // These four replaced tests that asserted the opposite. They were not
    // deleted: a test that pins the old behaviour is a plausible account of how
    // a superseded rule stayed in the codebase, and replacing them with the new
    // rule is what makes the reversal visible in the diff.

    @Test("An off-window day does not grow the streak, and does not reset it")
    func offWindowDayIsTransparent() throws {
        // Today off-window, yesterday on time -> 1. Neither 0 (it reset) nor 2
        // (it counted). This is the whole of ADR-023 in one assertion.
        #expect(try streak([("2026-09-30", false), ("2026-09-29", true)], today: "2026-09-30") == 1)
    }

    @Test("An off-window day alone, with no run behind it, is zero")
    func offWindowDayAloneIsZero() throws {
        // Zero because there is nothing to count — not zero because it broke
        // something. The distinction matters and only the second reading would
        // survive a later reversal.
        #expect(try streak([("2026-09-30", false)], today: "2026-09-30") == 0)
    }

    @Test("Consecutive off-window days are skipped, not ended")
    func consecutiveOffWindow() throws {
        #expect(try streak([
            ("2026-09-30", false), ("2026-09-29", false), ("2026-09-28", true)
        ], today: "2026-09-30") == 1)
    }

    @Test("An off-window day in the past is skipped and the run continues")
    func offWindowDayInPastIsSkipped() throws {
        // Today, yesterday and the day before on time, with an off-window day
        // wedged between two of them -> 3, not 1.
        #expect(try streak([
            ("2026-09-30", true), ("2026-09-29", false), ("2026-09-28", true)
        ], today: "2026-09-30") == 2)
    }

    @Test("A day with no moment at all still ends the run")
    func noMomentStillEndsTheRun() throws {
        // The distinction ADR-023 draws: no photograph is a genuine miss, and
        // only that ends the walk. An off-window photograph is not a miss.
        #expect(try streak([
            ("2026-09-30", true), ("2026-09-28", true)
        ], today: "2026-09-30") == 1)
    }

    @Test("The best streak is never lower than the current one")
    func bestIsNeverBelowCurrent() throws {
        // The display bug ADR-023 would have caused, pinned so it cannot come
        // back. `currentStreak` skips off-window days; if `longestStreak` counted
        // strictly-consecutive *on-time* days it could land below the current
        // value, and the Today footer would render "best 2" beside a streak of 3.
        //
        // Swept across a fortnight of histories rather than asserted once,
        // because the specific shape that breaks it is a one-in-many pattern
        // and a single fixture is a fixture that happened to pass.
        for mask in 0..<(1 << 10) {
            var onTime: Set<DayIdentifier> = []
            var captured: Set<DayIdentifier> = []
            for bit in 0..<10 {
                let day = try day("2026-09-\(20 + bit)")
                if mask & (1 << bit) != 0 {
                    onTime.insert(day)
                    captured.insert(day)
                } else if mask & (1 << (bit + 10)) != 0 {
                    captured.insert(day)          // off-window
                }
                // Neither set: a day with no moment at all.
            }
            let today = try day("2026-09-30")
            let current = StreakCalculator.currentStreak(
                onTimeDays: onTime, capturedDays: captured,
                today: today, calendar: calendar
            )
            let best = StreakCalculator.longestStreak(
                capturedDays: captured, calendar: calendar
            )
            #expect(
                best >= current,
                "best \(best) below current \(current) for mask \(mask)"
            )
        }
    }

    // MARK: - Calendar boundaries

    @Test("Crosses month and year boundaries")
    func crossesBoundaries() throws {
        #expect(try streak([
            ("2027-01-01", true), ("2026-12-31", true), ("2026-12-30", true)
        ], today: "2027-01-01") == 3)

        #expect(try streak([
            ("2026-03-01", true), ("2026-02-28", true), ("2026-02-27", true)
        ], today: "2026-03-01") == 3)
    }

    @Test("Crosses a leap day")
    func crossesLeapDay() throws {
        #expect(try streak([
            ("2028-03-01", true), ("2028-02-29", true), ("2028-02-28", true)
        ], today: "2028-03-01") == 3)
    }

    @Test("Crosses a DST transition without gaining or losing a day")
    func crossesDST() throws {
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!

        let rows: [MomentFacts] = ["2027-03-13", "2027-03-14", "2027-03-15"].map { raw in
            let day = DayIdentifier(string: raw, calendar: eastern)!
            let capturedAt = day.date.addingTimeInterval(14 * 3600)
            return MomentFacts(
                id: UUID(),
                day: day,
                isOnTime: true,
                capturedAt: capturedAt,
                windowEndsAt: capturedAt.addingTimeInterval(120),
                retakeCount: 0,
                hasBTS: false
            )
        }

        let streak = StreakCalculator.currentStreak(
            onTimeDays: StreakCalculator.onTimeDays(from: rows),
            capturedDays: StreakCalculator.capturedDays(from: rows),
            today: DayIdentifier(string: "2027-03-15", calendar: eastern)!,
            calendar: eastern
        )
        #expect(streak == 3, "a 23-hour day must not break a streak")
    }
}

/// Phase 2 — the historical longest streak.
@Suite("Phase 2 — longest streak")
struct LongestStreakTests {

    private var calendar = Calendar(identifier: .gregorian)

    /// Longest run of consecutive days with a moment. Takes plain day strings
    /// because the statistic no longer cares whether each one was on time
    /// (ADR-023) — a point worth restating in the helper's signature, since the
    /// old version of this took `onTimeDays` and would have read as the same
    /// number under a different name.
    private func longest(_ days: [String]) -> Int {
        let ids = Set(days.compactMap { DayIdentifier(string: $0, calendar: calendar) })
        return StreakCalculator.longestStreak(capturedDays: ids, calendar: calendar)
    }

    @Test("Empty is zero")
    func empty() {
        #expect(longest([]) == 0)
    }

    @Test("A single day is one")
    func single() {
        #expect(longest(["2026-09-30"]) == 1)
    }

    @Test("Finds the longest run among several")
    func findsLongest() {
        #expect(longest(["2026-09-01", "2026-09-02",
                         "2026-09-05", "2026-09-06", "2026-09-07"]) == 3)
    }

    @Test("A gap splits two runs even when adjacent")
    func gapSplits() {
        // 25th, 26th then 28th — 27th missing.
        #expect(longest(["2026-09-25", "2026-09-26", "2026-09-28"]) == 2)
    }

    @Test("Unsorted input yields the same answer")
    func unsortedInput() {
        #expect(longest(["2026-09-07", "2026-09-01", "2026-09-06", "2026-09-05"]) == 3)
    }

    @Test("Crosses the new year")
    func crossesYear() {
        #expect(longest(["2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02"]) == 4)
    }

    @Test("A single long run equals the current streak")
    func matchesCurrentWhenUnbroken() {
        let days = ["2026-09-26", "2026-09-27", "2026-09-28", "2026-09-29", "2026-09-30"]
        #expect(longest(days) == 5)
    }
}

/// Phase 2 — the missed-day count shown on the Stats screen.
@Suite("Phase 2 — missed days")
struct MissedDaysTests {

    private var calendar = Calendar(identifier: .gregorian)

    private func missed(_ days: [String], today: String) -> Int {
        let ids = Set(days.compactMap { DayIdentifier(string: $0, calendar: calendar) })
        return StreakCalculator.missedDays(
            capturedDays: ids,
            today: DayIdentifier(string: today, calendar: calendar)!,
            calendar: calendar
        )
    }

    @Test("No history means nothing missed")
    func empty() {
        #expect(missed([], today: "2026-09-30") == 0)
    }

    @Test("First moment today means nothing missed")
    func firstToday() {
        #expect(missed(["2026-09-30"], today: "2026-09-30") == 0)
    }

    @Test("Counts gaps between the first moment and today")
    func countsGaps() {
        #expect(missed(["2026-09-28"], today: "2026-09-30") == 1)
        #expect(missed(["2026-09-25"], today: "2026-09-30") == 4)
    }

    @Test("A gapless history reports zero")
    func gapless() {
        #expect(missed(["2026-09-28", "2026-09-29"], today: "2026-09-30") == 0)
        #expect(missed(["2026-09-27", "2026-09-28", "2026-09-29"], today: "2026-09-30") == 0)
    }
}

/// Phase 2 — the aggregate shown on the Stats screen.
@Suite("Phase 2 — summary")
struct SummaryTests {

    private var calendar = Calendar(identifier: .gregorian)

    /// A single fixture row. A struct rather than a named tuple because a
    /// named tuple cannot take `.init` inside an array literal.
    private struct Row {
        let day: String
        let onTime: Bool
        let retakes: Int
        let bts: Bool
        let hour: Int

        init(_ day: String, onTime: Bool, retakes: Int = 0, bts: Bool = false, hour: Int = 12) {
            self.day = day
            self.onTime = onTime
            self.retakes = retakes
            self.bts = bts
            self.hour = hour
        }
    }

    private func makeFacts(_ rows: [Row]) -> [MomentFacts] {
        let cal = calendar
        return rows.map { row in
            let day = DayIdentifier(string: row.day, calendar: cal)!
            var components = cal.dateComponents([.year, .month, .day], from: day.date)
            components.hour = row.hour
            let capturedAt = cal.date(from: components)!
            return MomentFacts(
                id: UUID(),
                day: day,
                isOnTime: row.onTime,
                capturedAt: capturedAt,
                windowEndsAt: capturedAt.addingTimeInterval(120),
                retakeCount: row.retakes,
                hasBTS: row.bts
            )
        }
    }

    @Test("Empty history yields the empty summary")
    func empty() throws {
        let today = try #require(DayIdentifier(string: "2026-09-30", calendar: calendar))
        #expect(StreakCalculator.summary(facts: [], today: today, calendar: calendar) == .empty)
    }

    @Test("Counts, percentages and averages are all derived correctly")
    func aggregates() throws {
        let facts = makeFacts([
            Row("2026-09-27", onTime: false, retakes: 0, bts: true,  hour: 9),
            Row("2026-09-28", onTime: true,  retakes: 1, bts: false, hour: 14),
            Row("2026-09-29", onTime: true,  retakes: 2, bts: true,  hour: 14),
            Row("2026-09-30", onTime: true,  retakes: 3, bts: false, hour: 14),
        ])
        let today = try #require(DayIdentifier(string: "2026-09-30", calendar: calendar))
        let s = StreakCalculator.summary(facts: facts, today: today, calendar: calendar)

        #expect(s.totalMoments == 4)
        #expect(s.daysCaptured == 4)
        #expect(s.lateMoments == 1)
        // The 27th was off-window, so it is skipped rather than ending the run:
        // the 28th, 29th and 30th all count (ADR-023).
        #expect(s.currentStreak == 3)
        // `longestStreak` counts days with *any* moment, so the off-window 27th
        // is inside the best run and it spans all four days. Under the old rule
        // this would have been 3 — and with `currentStreak` skipping, a best of 3
        // beside a current of 3 is a number that never says anything.
        #expect(s.longestStreak == 4)
        #expect(s.onTimePercentage == 0.75)
        #expect(s.averageRetakes == 1.5)    // (0+1+2+3)/4
        #expect(s.btsCount == 2)
    }

    @Test("Busiest hour picks the mode and resolves ties to the earlier hour")
    func busiestHour() throws {
        let today = try #require(DayIdentifier(string: "2026-09-30", calendar: calendar))

        let skewed = makeFacts([
            Row("2026-09-28", onTime: true, hour: 7),
            Row("2026-09-29", onTime: true, hour: 7),
            Row("2026-09-30", onTime: true, hour: 18),
        ])
        #expect(StreakCalculator.summary(facts: skewed, today: today, calendar: calendar).busiestHour == 7)

        let tied = makeFacts([
            Row("2026-09-29", onTime: true, hour: 21),
            Row("2026-09-30", onTime: true, hour: 6),
        ])
        #expect(StreakCalculator.summary(facts: tied, today: today, calendar: calendar).busiestHour == 6)
    }

    @Test("Percentages never divide by zero")
    func noDivisionByZero() throws {
        let today = try #require(DayIdentifier(string: "2026-09-30", calendar: calendar))
        let s = StreakCalculator.summary(facts: [], today: today, calendar: calendar)
        #expect(s.onTimePercentage == 0)
        #expect(s.averageRetakes == 0)
        #expect(s.busiestHour == nil)
        #expect(s.currentStreak == 0)
        #expect(s.longestStreak == 0)
    }
}
