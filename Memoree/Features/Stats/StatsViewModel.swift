import Foundation
import Observation

/// Drives the Stats screen.
///
/// A view over one `StreakSummary` and nothing else.
///
/// **No arithmetic happens here, and that is the point of the phase.** Phase 2
/// built `StreakCalculator.summary` — every field below was computed and tested
/// months before there was anywhere to put it. So this type exists to answer two
/// questions the summary cannot: *what is worth showing*, and *how do you say a
/// number*.
///
/// Which brings up the one real decision in this phase. ADR-023 removed the
/// per-moment late badge, so an off-window moment is now indistinguishable from
/// an on-time one on every screen — **and the streak silently does not move when
/// you photograph off-window.** The ADR accepted that consequence knowingly and
/// noted the risk: *"A user who has not read this ADR will experience that as a
/// bug in the first week."*
///
/// This screen is the answer to that risk, and the reason it is phrased as an
/// aggregate is the whole of ADR-023: **"7 of 12 on time" describes a number; a
/// badge on a photograph described the user.** The distinction is still recorded
/// — it has to be, the streak depends on it — and this is the one place it is
/// allowed to be visible.
@MainActor
@Observable
final class StatsViewModel {

    /// The numbers, recomputed on appear rather than cached.
    ///
    /// Recomputed because `MomentStore.summary` is a fetch plus a pass over a few
    /// thousand rows, and because a stored counter is one more thing that can
    /// drift out of agreement with the archive it summarises.
    private(set) var summary: StreakSummary = .empty

    /// The days themselves, for the streak history.
    private(set) var days: [MomentFacts] = []

    /// Trailing 14 days of streak continuity.
    private(set) var habitDays: [StreakCalculator.HabitDay] = []

    /// 24-hour distribution bins for capture rhythm.
    private(set) var hourlyDistribution: [(hour: Int, count: Int, ratio: Double)] = []

    /// Whether today already has a recorded capture.
    private(set) var isStreakActiveToday: Bool = false

    /// Currently selected moment for detail view sheet presentation.
    var selectedMoment: MomentFacts?

    /// The clock, for the same reason `TodayViewModel` has one: "which day is it"
    /// is an input to every derived value here, and a view model that reads
    /// `Date()` cannot be tested at a chosen time.
    private let clock: @Sendable () -> Date

    private let environment: AppEnvironment

    init(environment: AppEnvironment, now: @escaping @Sendable () -> Date = { Date() }) {
        self.environment = environment
        self.clock = now
    }

    func load() {
        let today = DayIdentifier(date: clock())
        summary = environment.momentStore.summary(today: today)
        // Newest first, same order as the archive — so the two screens agree
        // about which moment is "the first one", which is the kind of thing that
        // is obvious when it matches and maddening when it does not.
        days = environment.momentStore.facts()

        let captured = StreakCalculator.capturedDays(from: days)
        habitDays = StreakCalculator.recentHabitDays(
            capturedDays: captured,
            today: today,
            daysCount: 14
        )
        isStreakActiveToday = captured.contains(today)

        let maxHourCount = summary.hourlyDistribution.values.max() ?? 0
        hourlyDistribution = (0..<24).map { hour in
            let count = summary.hourlyDistribution[hour, default: 0]
            let ratio = maxHourCount > 0 ? Double(count) / Double(maxHourCount) : 0.0
            return (hour: hour, count: count, ratio: ratio)
        }
    }

    /// Tombstones the moment in the store and refreshes every derived number.
    ///
    /// **Does not touch Photos.** Same contract as `ArchiveViewModel.delete`
    /// (ADR-008): add-only authorisation cannot remove assets, so the photos
    /// stay in the camera roll and only the archive entry disappears.
    func delete(_ moment: MomentFacts) throws {
        guard let row = environment.momentStore.allMoments
            .first(where: { $0.id == moment.id })
        else { return }

        try environment.momentStore.delete(row)
        // Streak, habit strip, and history all read from the store — reload so
        // a tombstone cannot leave a stale count on screen.
        load()
    }

    // MARK: - Copy

    /// Nothing here is a sentence about the user.
    ///
    /// No "keep it up", no "you are falling behind", no congratulation. The
    /// numbers are the reward and the only thing the app has ever offered
    /// (ADR-015, and the app's entire premise). A screen whose job is to report
    /// has no business editorialising.


    /// "3 days" / "1 day"
    var currentStreakDescription: String {
        Self.plural(summary.currentStreak, "day")
    }

    var longestStreakDescription: String {
        Self.plural(summary.longestStreak, "day")
    }

    var daysCapturedDescription: String {
        Self.plural(summary.daysCaptured, "day")
    }

    /// First recorded memory date, e.g. "Oct 1, 2026".
    var firstMemoryDescription: String? {
        summary.firstCaptureDate?.formatted(date: .abbreviated, time: .omitted)
    }

    /// Overall capture consistency since the first memory, e.g. "85%".
    var consistencyDescription: String? {
        guard let consistency = summary.consistencyPercentage else { return nil }
        return "\(Int(consistency.rounded()))%"
    }

    /// Notes written across all moments.
    var notesDescription: String? {
        guard summary.notesCount > 0 else { return nil }
        return Self.plural(summary.notesCount, "note")
    }

    /// Status of today's streak: "Active today" if captured today, or "Protected through yesterday".
    var streakStatusDescription: String {
        if summary.currentStreak == 0 {
            return "No active streak"
        } else if isStreakActiveToday {
            return "Active today"
        } else {
            return "Protected through yesterday"
        }
    }

    /// Retakes, or nothing at all when there were none.
    ///
    /// Hidden at zero for the same reason the archive hides a zero retake count:
    /// "0 retakes" is the absence of the thing being counted, and a row that says
    /// so is a row of noise. A user who has never retaken anything is not being
    /// told they scored zero.
    var retakeDescription: String? {
        guard summary.averageRetakes > 0 else { return nil }
        let rounded = summary.averageRetakes.rounded()
        // Whole numbers stay whole. "2.0 retakes on average" is a false precision
        // — the underlying data is an integer count per moment.
        let number = rounded == summary.averageRetakes
            ? String(Int(rounded))
            : String(format: "%.1f", summary.averageRetakes)
        return "\(number) on average"
    }

    /// "4pm" or "16:00", matching whatever the device does everywhere else.
    ///
    /// **The locale's format, not a hardcoded one.** The first version used a
    /// `DateFormatter` with `dateFormat = "ha"` and a lowercase `pm` symbol, which
    /// produced "8pm" directly above a history list reading "11.38" — two time
    /// formats on one screen, because the list was following the device locale
    /// and this was not. A user in a 24-hour locale should see 24-hour times;
    /// they should see them *everywhere*.
    ///
    /// The date is arbitrary on purpose. "The busiest hour" is an hour of the
    /// day, not an instant, and formatting it needs a `Date` to format — so a
    /// fixed reference day is used, which keeps the formatter out of any question
    /// of which day or time zone it landed on.
    var busiestHourDescription: String? {
        guard let hour = summary.busiestHour else { return nil }
        return Self.referenceDay
            .addingTimeInterval(Double(hour) * 3600)
            .formatted(date: .omitted, time: .shortened)
    }

    /// Local midnight on a fixed day, used only to give the hour formatter a
    /// `Date` to format. Midnight matters: an hour boundary is exactly where a
    /// stray time zone shifts the label from 16:00 to 15:00.
    private static let referenceDay = Calendar.current.date(
        from: DateComponents(year: 2001, month: 1, day: 1, hour: 0)
    ) ?? Date(timeIntervalSinceReferenceDate: 0)

    /// Days with no photograph at all — the only thing that breaks a streak.
    ///
    /// Labelled "days with nothing" rather than "days missed", because "missed"
    /// reads as a failure and ADR-023 made a day with no photograph the *only*
    /// failure. An off-window day is not missed; it is a day you showed up.
    var missedDescription: String {
        "\(summary.missedDays) with nothing"
    }

    /// Clips recorded, or nothing at all when there are none.
    ///
    /// **Hidden at zero, for the same reason retakes are** — a user who has BTS off,
    /// which is the default for everyone, is not being told they scored zero clips.
    /// A row reading "0" describes a feature they are not using as though they were
    /// using it badly.
    ///
    /// ## Why it is a count and not a percentage
    ///
    /// The temptation is "3 of 12 days" or "25%". Both are worse. A percentage
    /// invites the reading that more is better, and it is not — the photographs are
    /// the product and a clip is context (ADR-013), so a month where every day has a
    /// clip is not a better month. A count is a fact and nothing more.
    var btsDescription: String? {
        guard summary.btsCount > 0 else { return nil }
        return Self.plural(summary.btsCount, "clip")
    }

    /// Whether there is anything to say at all.
    var isEmpty: Bool { summary.totalMoments == 0 }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(count == 1 ? noun : noun + "s")"
    }
}
