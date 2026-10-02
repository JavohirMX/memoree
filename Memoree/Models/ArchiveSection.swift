import Foundation

/// One month of the archive, with the moments in it.
///
/// ## Why this is a value type in `Models` and not a loop in the view
///
/// The grouping is the whole of this feature's logic, and it is the part that
/// can be wrong in ways nobody sees: a moment landing in the previous month
/// because the archive is sorted by instant while months are local, a header
/// repeated because two sections resolved to the same month, a boundary at
/// midnight on the day a timezone changed. None of that has a shape a
/// screenshot can check. Written here it gets the table-driven tests
/// `AGENTS.md` §10 asks for — including the DST and timezone cases, which is
/// where a month boundary actually goes wrong.
struct ArchiveSection: Identifiable, Sendable, Hashable {

    /// The year and month, as the calendar resolved them.
    ///
    /// **A pair of integers, not a `"2026-09"` string and not a `Date`.** Both
    /// alternatives are worse in a way that shows up later:
    ///
    /// - A string is not an instant, so it sorts lexicographically, has to be
    ///   parsed, and silently disagrees with the calendar about what "October"
    ///   is. Grouping is exactly the operation where that disagreement becomes a
    ///   duplicated header.
    /// - A `Date` at the start of the month is fine as a *key* but it has to be
    ///   manufactured: `calendar.date(from:)` built from year-and-month alone
    ///   fills in whatever the calendar's defaults are for day and hour, which
    ///   is how a "start of month" ends up being the first of the month at 00:00
    ///   on a calendar that says otherwise.
    ///
    /// So the section *key* is the pair, and the `Date` below is derived for
    /// ordering and display only.
    let key: MonthKey

    /// Newest first, which is the order the archive is read in.
    let moments: [MomentFacts]

    var id: MonthKey { key }

    /// The first instant of the month, for ordering and for the header's date.
    ///
    /// Derived and best-effort: it is a display concern, and a nil here costs a
    /// header a little context rather than costing a moment its place.
    var monthStart: Date? {
        var components = DateComponents()
        components.year = key.year
        components.month = key.month
        components.day = 1
        return Calendar.current.date(from: components)
    }

    /// "September 2026", in the user's own language and calendar.
    ///
    /// `.formatted` rather than a `DateFormatter` with `"MMMM yyyy"` — the same
    /// argument `TimeWindow.format` makes, and the same bug it once had.
    ///
    /// **Falls back to the raw year and month** when the month cannot be
    /// resolved. That is not defensive programming for its own sake: it is what
    /// a section with a single moment in a year of 5000 needs to be readable,
    /// and "2026-09" is still a correct answer to "when was this".
    var title: String {
        guard let monthStart else { return "\(key.year)-\(String(format: "%02d", key.month))" }
        return monthStart.formatted(.dateTime.month(.wide).year())
    }
}

/// A year and a month, as the calendar sees them.
struct MonthKey: Hashable, Sendable, Comparable, CustomStringConvertible {

    let year: Int
    let month: Int

    /// Newest first, because the archive is read newest first.
    ///
    /// The reverse of the obvious order, and it has to be written down: a
    /// `Comparable` that sorted ascending would quietly reverse the whole
    /// archive the first time anyone used `sorted()` on these.
    static func < (lhs: MonthKey, rhs: MonthKey) -> Bool {
        (lhs.year, lhs.month) > (rhs.year, rhs.month)
    }

    var description: String { "\(year)-\(String(format: "%02d", month))" }
}

extension ArchiveSection {

    /// Splits a chronologically sorted archive into months, newest month first.
    ///
    /// - Parameters:
    ///   - moments: Any order. Sorted here, so a caller cannot get it wrong.
    ///   - calendar: Injected so the tests can pin a timezone and a DST
    ///     boundary. Defaults to the device's, which is the only correct choice
    ///     in the app — "September" has to mean the user's September.
    ///
    /// **Contiguous runs, not a lookup keyed by month.** Two moments in the same
    /// month separated in the input by a moment from another month produce one
    /// section under this and two under a dictionary, which then have to be
    /// merged back together. Sorting first and splitting on change makes the
    /// duplicate-header bug unrepresentable rather than merely unlikely.
    static func grouping(
        _ moments: [MomentFacts],
        calendar: Calendar = .current
    ) -> [ArchiveSection] {
        guard !moments.isEmpty else { return [] }

        let sorted = moments.sorted { $0.capturedAt > $1.capturedAt }

        // **Parallel arrays, then `zip`.** The obvious version —
        // `sections[i].moments.append(moment)` — does not compile, because
        // `ArchiveSection.moments` is a `let` on a struct, so appending through
        // a subscript is a mutating member on an immutable value. Making it `var`
        // to accommodate a grouping function would weaken the type for every
        // other caller in exchange for a loop nobody reads.
        var keys: [MonthKey] = []
        var grouped: [[MomentFacts]] = []

        for moment in sorted {
            let components = calendar.dateComponents([.year, .month], from: moment.capturedAt)
            // **The fallback is not a crash path, it is the only honest one.**
            // A `Date` always yields a year and a month from a Gregorian
            // calendar, so this is unreachable; if a calendar ever did not, the
            // moment still appears, filed under the year it belongs to rather
            // than vanishing from the user's archive.
            let key = MonthKey(year: components.year ?? 0, month: components.month ?? 1)

            if keys.last == key {
                grouped[grouped.count - 1].append(moment)
            } else {
                keys.append(key)
                grouped.append([moment])
            }
        }

        return zip(keys, grouped).map { ArchiveSection(key: $0, moments: $1) }
    }
}
