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
        // An unposted *today* is not a miss (ADR-010), so the walk starts at
        // yesterday rather than ending immediately. This has to be handled
        // before the loop, not inside it: today is the one day whose emptiness
        // means nothing, and special-casing it mid-loop is how it gets lost.
        let cursor: DayIdentifier
        if onTimeDays.contains(today) || capturedDays.contains(today) {
            cursor = today
        } else {
            cursor = today.offset(by: -1, calendar: calendar)
        }

        var streak = 0
        var day = cursor

        // Walk back. An on-time day counts. An off-window day is **skipped** —
        // transparent, neither counted nor an ending. A day with no moment at
        // all ends the walk (ADR-023).
        //
        // The distinction this draws is the whole of ADR-023: capture is
        // permitted at any time, so a day without a photograph is a genuine
        // miss, while a day photographed outside the two-minute window is a day
        // you showed up and it simply does not count. The earlier version
        // returned 0 outright for a late today, which is ADR-009 — superseded.
        while true {
            if onTimeDays.contains(day) {
                streak += 1
            } else if !capturedDays.contains(day) {
                break
            }

            let previous = day.offset(by: -1, calendar: calendar)
            // Defensive: a malformed calendar could return the same day
            // forever. Bail rather than spin.
            guard previous != day else { break }
            day = previous
        }
        return streak
    }

    // MARK: - Longest streak

    /// The longest run of consecutive days with a moment, anywhere in history.
    ///
    /// **Counts any moment, on-time or not** (ADR-023). The previous version
    /// counted strictly-consecutive *on-time* days, which became wrong the
    /// moment `currentStreak` learned to skip off-window days: a history of
    /// on-time, on-time, off-window, on-time would then display a current streak
    /// of 3 beside a best of 2. A footer whose best number is lower than the
    /// current one is a bug users find in a day.
    ///
    /// The alternative — giving this the same skip rule as `currentStreak` —
    /// makes the two numbers identical whenever the user has never missed a
    /// whole day, which is the common case for anyone still using the app, and
    /// the "best" row would then never render at all.
    ///
    /// As a statistic this is also the more interesting one: *your best run of
    /// days you actually showed up*, regardless of whether the timing counted.
    static func longestStreak(
        capturedDays: Set<DayIdentifier>,
        calendar: Calendar = .current
    ) -> Int {
        guard !capturedDays.isEmpty else { return 0 }

        let sorted = capturedDays.sorted()
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
            longestStreak: longestStreak(capturedDays: capturedDays, calendar: calendar),
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
