import Foundation

/// A local calendar day, identified by its `YYYY-MM-DD` string in the device's
/// **current** timezone.
///
/// This type is the single most important modelling decision in Memoree. A
/// moment must be attached to the day the *user* experienced it, because that
/// is what a streak means to a human. Using a UTC date instead would put a
/// 23:30 capture on the wrong day for anyone east or west of Greenwich, and
/// would silently corrupt streaks near midnight.
///
/// Not a UTC date. Not an instant. A day, as a person experiences it.
struct DayIdentifier: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {

    /// The canonical form: `2026-09-30`.
    let rawValue: String

    /// The instant at the start of this day, in the given calendar's timezone.
    let date: Date

    var description: String { rawValue }

    // MARK: - Construction

    /// Private so that `rawValue` and `date` can never disagree.
    ///
    /// An earlier version exposed a public `init(rawValue:date:)` and it was
    /// immediately possible to build a day labelled `2026-12-31` whose `date`
    /// was today — which made `offset(by:)` arithmetic silently wrong. A day is
    /// defined by its two fields agreeing, so the invariant is enforced by the
    /// type rather than by discipline.
    private init(consistent rawValue: String, date: Date) {
        self.rawValue = rawValue
        self.date = date
    }

    /// Derives the day containing `date`, as observed in `calendar`'s timezone.
    init(date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.rawValue = Self.format(components)
        self.date = calendar.startOfDay(for: date)
    }

    /// Parses a canonical `YYYY-MM-DD` string into a day at local midnight.
    ///
    /// Returns `nil` for malformed input rather than trapping, because these
    /// strings arrive from persisted storage where corruption is possible.
    init?(string: String, calendar: Calendar = .current) {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0

        guard let resolved = calendar.date(from: components) else { return nil }
        // Reject dates that do not survive a round trip, e.g. 2026-02-31.
        guard Self(date: resolved, calendar: calendar).rawValue == string else { return nil }

        self.init(consistent: string, date: calendar.startOfDay(for: resolved))
    }

    // MARK: - Arithmetic

    /// The day `offset` days from this one.
    func offset(by offset: Int, calendar: Calendar = .current) -> DayIdentifier {
        guard let shifted = calendar.date(byAdding: .day, value: offset, to: date) else {
            return self
        }
        return DayIdentifier(date: shifted, calendar: calendar)
    }

    /// Whole calendar days between two days. Negative if `other` precedes `self`.
    func days(until other: DayIdentifier, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: date, to: other.date).day ?? 0
    }

    /// The previous day.
    func previous(calendar: Calendar = .current) -> DayIdentifier {
        offset(by: -1, calendar: calendar)
    }

    var isToday: Bool { self == DayIdentifier(date: Date()) }

    // MARK: - Format

    private static func format(_ components: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

extension DayIdentifier {
    /// Ordering by canonical string is equivalent to ordering chronologically,
    /// because `YYYY-MM-DD` is zero-padded fixed-width.
    static func < (lhs: DayIdentifier, rhs: DayIdentifier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
