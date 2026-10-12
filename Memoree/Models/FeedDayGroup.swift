import Foundation

/// One calendar day of Today’s chronological feed, with its moments.
///
/// Pure grouping so the home feed can show the date once as a section title
/// instead of repeating `Today · time` on every card when ADR-030 leaves
/// several captures on the same day.
struct FeedDayGroup: Identifiable, Sendable, Hashable {
    let day: DayIdentifier
    /// Newest first within the day (same order as a chronological feed slice).
    let moments: [MomentFacts]

    var id: String { day.rawValue }

    /// Buckets `moments` by `dayIdentifier`, preserving input order of first
    /// appearance (newest day first when the feed is already newest-first).
    static func grouping(_ moments: [MomentFacts]) -> [FeedDayGroup] {
        guard !moments.isEmpty else { return [] }

        var order: [DayIdentifier] = []
        var buckets: [DayIdentifier: [MomentFacts]] = [:]
        order.reserveCapacity(moments.count)
        buckets.reserveCapacity(moments.count)

        for moment in moments {
            if buckets[moment.day] == nil {
                order.append(moment.day)
                buckets[moment.day] = []
            }
            buckets[moment.day, default: []].append(moment)
        }

        return order.map { day in
            FeedDayGroup(day: day, moments: buckets[day] ?? [])
        }
    }

    /// Section title relative to `now`: `Today`, `Yesterday`, or a medium date.
    ///
    /// Compares against `now` rather than `Calendar.isDateInToday`, so tests
    /// (and a frozen view-model clock) can pin the boundary.
    func title(now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day.date, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day.date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
