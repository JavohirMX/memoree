import Foundation
import Testing

@testable import Memoree

/// Phase 2 — streak arithmetic.
///
/// Every function here is pure, so the whole suite runs in microseconds with no
/// SwiftData container and no device. The cases that matter most are the two
/// ADR decisions that are easy to conflate:
///
/// - **ADR-009** a late-only day *breaks* the streak
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

    // MARK: - ADR-009: a late-only day breaks the streak

    @Test("A late-only day returns zero, not the previous run")
    func lateTodayBreaks() throws {
        #expect(try streak([("2026-09-30", false)], today: "2026-09-30") == 0)
    }

    @Test("A late today breaks an otherwise perfect run")
    func lateTodayBreaksPriorRun() throws {
        // The bug this pins: walking back from yesterday would report 1 here,
        // because yesterday *was* on time. It must report 0.
        #expect(try streak([("2026-09-30", false), ("2026-09-29", true)], today: "2026-09-30") == 0)
    }

    @Test("Consecutive late days are zero")
    func consecutiveLate() throws {
        #expect(try streak([("2026-09-30", false), ("2026-09-29", false)], today: "2026-09-30") == 0)
    }

    @Test("A late day in the past breaks the walk")
    func lateDayInPastBreaks() throws {
        // Today on time, yesterday late, day before on time -> 1, not 3.
        #expect(try streak([
            ("2026-09-30", true), ("2026-09-29", false), ("2026-09-28", true)
        ], today: "2026-09-30") == 1)
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

    private func longest(_ days: [String]) -> Int {
        let ids = Set(days.compactMap { DayIdentifier(string: $0, calendar: calendar) })
        return StreakCalculator.longestStreak(onTimeDays: ids, calendar: calendar)
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
        #expect(s.currentStreak == 3)      // the 27th was late, so it breaks
        #expect(s.longestStreak == 3)
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
