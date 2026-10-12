import Foundation

/// Pure derivation of a `WidgetSnapshot` from archive facts (ADR-040).
///
/// Lives beside the store rather than in the widget extension — the extension
/// only *reads* the encoded snapshot. Unit-tested without WidgetKit.
enum WidgetSnapshotBuilder {

    /// Builds a snapshot for `today` from live moment facts.
    static func make(
        facts: [MomentFacts],
        today: DayIdentifier,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> WidgetSnapshot {
        let summary = StreakCalculator.summary(facts: facts, today: today, calendar: calendar)
        let capturedDays = Set(facts.map(\.day))
        let lastSevenDays: [Bool] = (0..<7).map { index in
            // Oldest → newest: index 0 is six days ago, index 6 is today.
            let day = today.offset(by: index - 6, calendar: calendar)
            return capturedDays.contains(day)
        }
        return WidgetSnapshot(
            dayIdentifier: today.rawValue,
            capturedToday: capturedDays.contains(today),
            currentStreak: summary.currentStreak,
            lastSevenDays: lastSevenDays,
            updatedAt: now
        )
    }
}
