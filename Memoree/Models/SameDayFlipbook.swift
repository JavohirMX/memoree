import Foundation

/// Selection for a "this day across years" flipbook.
///
/// Pure over `[MomentFacts]` — no SwiftData, no Photos, no clock. The Archive
/// already exports a full-library timelapse through `PhotoLibraryService
/// .exportFlipbookVideo`; this only decides *which* moments belong to one
/// calendar day across years so Today can offer that subset when it is worth
/// exporting (ADR-038).
enum SameDayFlipbook {

    /// At least two distinct calendar years on the same month and day.
    ///
    /// Two captures on the same day in one year are not "across years." The
    /// bar is years, not moment count — ADR-030 multi-capture must not unlock
    /// this export alone.
    static let minimumYearCount = 2

    /// Moments whose local calendar month and day match `date`, every year
    /// included, oldest first.
    ///
    /// Unlike `MomentStore.flashbackMoments`, this keeps the current year so a
    /// capture from today can sit beside prior years in the same movie.
    ///
    /// Leap day (29 February) matches only 29 February — same rule as
    /// flashbacks. No silent remapping to the 28th.
    static func moments(
        from facts: [MomentFacts],
        matching date: Date,
        calendar: Calendar = .current
    ) -> [MomentFacts] {
        let target = calendar.dateComponents([.month, .day], from: date)
        guard let month = target.month, let day = target.day else { return [] }

        return facts
            .filter { fact in
                let components = calendar.dateComponents([.month, .day], from: fact.day.date)
                return components.month == month && components.day == day
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Whether the selection spans enough years to export.
    static func isExportable(
        _ moments: [MomentFacts],
        calendar: Calendar = .current
    ) -> Bool {
        let years = Set(moments.map { calendar.component(.year, from: $0.day.date) })
        return years.count >= minimumYearCount
    }
}
