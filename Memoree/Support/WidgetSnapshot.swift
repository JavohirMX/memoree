import Foundation

/// Metadata-only payload the Home Screen widget reads (ADR-040).
///
/// No photographs, asset identifiers, notes, or location — those stay in the
/// app sandbox / Photos. The widget only needs “did today count” and streak.
struct WidgetSnapshot: Codable, Equatable, Sendable {

    /// Local calendar day the snapshot was built for (`YYYY-MM-DD`).
    var dayIdentifier: String

    /// Whether that day already has a live moment.
    var capturedToday: Bool

    /// Current streak from `StreakCalculator` (ADR-010 / ADR-032).
    var currentStreak: Int

    /// Last seven calendar days, oldest → newest (today is the last entry).
    var lastSevenDays: [Bool]

    var updatedAt: Date

    /// Empty / pre-first-launch placeholder.
    static let empty = WidgetSnapshot(
        dayIdentifier: "",
        capturedToday: false,
        currentStreak: 0,
        lastSevenDays: Array(repeating: false, count: 7),
        updatedAt: .distantPast
    )

    /// Resolves against the widget’s notion of “today”.
    ///
    /// A stale `dayIdentifier` means the app has not refreshed since midnight —
    /// treat today as not captured, keep the last known streak until the app runs.
    func resolved(forToday todayRawValue: String) -> WidgetSnapshot {
        guard dayIdentifier == todayRawValue else {
            var copy = self
            copy.capturedToday = false
            copy.dayIdentifier = todayRawValue
            return copy
        }
        return self
    }
}
