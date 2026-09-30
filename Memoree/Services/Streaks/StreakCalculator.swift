import Foundation

/// Streak arithmetic. Pure functions over `DayIdentifier` sets and
/// `[MomentFacts]` — no SwiftData, no clock, no side effects.
///
/// Two rules drive every function here, and both are easy to get wrong:
///
/// - **Only an on-time moment grows a streak.** A late day is recorded and
///   archived, but it breaks the run rather than extending it (ADR-009).
/// - **Today is never itself a miss.** At 09:00 with a moment window of
///   11:00–23:00, an unposted today is not a failure. Without this rule the
///   streak visibly resets every morning and silently rebuilds by evening
///   (ADR-010).
enum StreakCalculator {

    // MARK: - Current streak

    /// Consecutive days with an on-time moment, counting backwards from today.
    ///
    /// Three cases for today, and conflating any two of them is the bug this
    /// function exists to avoid:
    ///
    /// 1. **On-time today** — count it, walk back from today.
    /// 2. **Late today** — the run is already broken. Return zero. A late
    ///    capture is archived but must not let an older run survive
    ///    underneath it (ADR-009).
    /// 3. **No moment today** — nothing has failed yet, so walk back from
    ///    yesterday and leave the streak standing (ADR-010).
    static func currentStreak(
        onTimeDays: Set<DayIdentifier>,
        capturedDays: Set<DayIdentifier>,
        today: DayIdentifier,
        calendar: Calendar = .current
    ) -> Int {
        var cursor: DayIdentifier

        if onTimeDays.contains(today) {
            cursor = today
        } else if capturedDays.contains(today) {
            // Late today: the streak is broken, whatever came before it.
            return 0
        } else {
            cursor = today.offset(by: -1, calendar: calendar)
        }

        var streak = 0
        while onTimeDays.contains(cursor) {
            streak += 1
            let previous = cursor.offset(by: -1, calendar: calendar)
            // Defensive: a malformed calendar could return the same day
            // forever. Bail rather than spin.
            guard previous != cursor else { break }
            cursor = previous
        }
        return streak
    }

    // MARK: - Longest streak

    /// The longest run of consecutive on-time days anywhere in history.
    ///
    /// Counts gaps between runs as breaks, so a run ending three days before
    /// another run begins is not treated as continuous.
    static func longestStreak(
        onTimeDays: Set<DayIdentifier>,
        calendar: Calendar = .current
    ) -> Int {
        guard !onTimeDays.isEmpty else { return 0 }

        let sorted = onTimeDays.sorted()
        var longest = 0
        var run = 0
        var previous: DayIdentifier?

        for day in sorted {
            if let previous, day.days(until: previous, calendar: calendar) == -1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        return longest
    }

    // MARK: - Broken days

    /// Days since the first moment that had no capture at all.
    ///
    /// Only counts days strictly before today, for the same reason the current
    /// streak does (ADR-010). Returns 0 when the first moment is today.
    static func missedDays(
        capturedDays: Set<DayIdentifier>,
        today: DayIdentifier,
        calendar: Calendar = .current
    ) -> Int {
        guard let first = capturedDays.min() else { return 0 }
        let span = first.days(until: today, calendar: calendar)
        return max(0, span - capturedDays.filter { $0 < today }.count)
    }

    // MARK: - Summary

    /// Every statistic the app displays, derived in one pass.
    static func summary(
        facts: [MomentFacts],
        today: DayIdentifier,
        calendar: Calendar = .current
    ) -> StreakSummary {
        guard !facts.isEmpty else { return .empty }

        var onTimeDays = Set<DayIdentifier>()
        var capturedDays = Set<DayIdentifier>()
        var hourCounts = [Int: Int]()
        var retakeTotal = 0
        var btsCount = 0
        var lateMoments = 0

        for fact in facts {
            capturedDays.insert(fact.day)
            if fact.isOnTime {
                onTimeDays.insert(fact.day)
            } else {
                lateMoments += 1
            }

            retakeTotal += fact.retakeCount
            if fact.hasBTS { btsCount += 1 }

            let hour = calendar.component(.hour, from: fact.capturedAt)
            hourCounts[hour, default: 0] += 1
        }

        let total = facts.count
        let onTimeCount = onTimeDays.count

        // Ties resolve to the earlier hour, which is stable and unsurprising.
        let busiest = hourCounts
            .filter { $0.value == hourCounts.values.max() }
            .keys
            .min()

        return StreakSummary(
            currentStreak: currentStreak(
                onTimeDays: onTimeDays, capturedDays: capturedDays,
                today: today, calendar: calendar),
            longestStreak: longestStreak(onTimeDays: onTimeDays, calendar: calendar),
            daysCaptured: capturedDays.count,
            totalMoments: total,
            lateMoments: lateMoments,
            onTimePercentage: Double(onTimeCount) / Double(total),
            averageRetakes: Double(retakeTotal) / Double(total),
            btsCount: btsCount,
            busiestHour: busiest,
            missedDays: missedDays(
                capturedDays: capturedDays, today: today, calendar: calendar)
        )
    }

    // MARK: - Extracting day sets

    /// Days with an on-time moment.
    static func onTimeDays(from facts: [MomentFacts]) -> Set<DayIdentifier> {
        Set(facts.filter(\.isOnTime).map(\.day))
    }

    /// Days with any moment, on time or late.
    static func capturedDays(from facts: [MomentFacts]) -> Set<DayIdentifier> {
        Set(facts.map(\.day))
    }
}
