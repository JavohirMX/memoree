import Foundation

/// The horizon decision, as a pure function of value types.
///
/// `UserNotificationService` used to make this decision inline, interleaved
/// with `UNUserNotificationCenter` calls — which is why Phase 1's refill
/// invariant test was never written. It could not be: the only way to observe
/// the service was to schedule real notifications, and the system centre is not
/// subclassable into a test double. The test was not omitted for being
/// unimportant; it was **unimplementable against the shape of the code**, and
/// stayed that way for five phases.
///
/// So the decision came out. `UNUserNotificationCenter` is now a thin shell that
/// reports what is pending and does what it is told; the arithmetic lives here,
/// where it is exercisable at the boundaries that matter: 0, 19, 20 and 64.
enum NotificationHorizonPlanner {

    /// What to do to bring the horizon back up to its full length.
    struct Plan: Equatable {

        /// Days to schedule, in order, starting today.
        let daysToSchedule: [DayIdentifier]

        /// When each of them fires. Localised because
        /// `UNCalendarNotificationTrigger` takes wall-clock components, which
        /// have to be read in the user's current zone at the time of building
        /// the trigger.
        let fireDates: [DayIdentifier: Date]

        /// Days to schedule evening streak-saver reminders for (7-day rolling window).
        let streakDaysToSchedule: [DayIdentifier]

        /// Fire dates for the evening streak-saver reminders (21:00 local time).
        let streakFireDates: [DayIdentifier: Date]

        /// Identifiers to remove before adding.
        ///
        /// Always exactly the ones about to be replaced, and never the empty
        /// string — `removePendingNotificationRequests(withIdentifiers: [""])`
        /// is a wildcard that clears *everything* the app has pending,
        /// including anything it did not schedule. `AGENTS.md §9` is explicit
        /// about never calling `removeAllPendingNotificationRequests()`, and a
        /// stray empty identifier is the same bug wearing a different hat.
        let identifiersToRemove: [String]

        /// Nothing to do. The horizon is already full.
        var isEmpty: Bool {
            daysToSchedule.isEmpty && streakDaysToSchedule.isEmpty && identifiersToRemove.isEmpty
        }
    }

    /// The identifier Memoree gives a day's spontaneous reminder.
    static func identifier(for day: DayIdentifier) -> String {
        identifierPrefix + day.rawValue
    }

    /// The identifier Memoree gives a day's evening streak-saver reminder.
    static func streakIdentifier(for day: DayIdentifier) -> String {
        streakIdentifierPrefix + day.rawValue
    }

    private static let identifierPrefix = "moment."
    private static let streakIdentifierPrefix = "streak."

    /// Rolling window length for evening streak-saver reminders.
    /// Kept bounded so 45 moments + 7 streak-savers = 52 requests (< 64 system limit).
    static let defaultStreakHorizon = 7

    /// 21:00 (9:00 PM) local time for the streak-saver notification.
    static let streakReminderHour = 21

    /// Computes 21:00 local time on the given calendar day.
    static func streakFireDate(for day: DayIdentifier, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: streakReminderHour, minute: 0, second: 0, of: day.date)
            ?? day.date.addingTimeInterval(TimeInterval(streakReminderHour * 3600))
    }

    /// Decides what to schedule.
    ///
    /// - Parameters:
    ///   - horizon: How many days of moments to keep scheduled. Memoree uses 45.
    ///   - streakHorizon: How many days of streak savers to keep scheduled (default 7).
    ///   - today: The day to count from.
    ///   - now: Current instant, to avoid scheduling reminders in the past.
    ///   - existing: Identifiers already pending, from the system centre.
    ///   - capturedDays: Days that already have a captured moment, so streak savers are skipped/cleared.
    ///   - momentStart: Resolves a day to its moment time. Injected rather than
    ///     reached for, so the planner is pure and the scheduler stays the one
    ///     place the derivation lives.
    static func plan(
        horizon: Int,
        streakHorizon: Int = 0,
        today: DayIdentifier,
        now: Date? = nil,
        existing: [String],
        capturedDays: Set<DayIdentifier> = [],
        momentStart: (DayIdentifier) -> Date
    ) -> Plan {
        let days = (0..<horizon).map { today.offset(by: $0) }
        let alreadyPending = Set(existing)

        // Only days with nothing pending. Re-adding a request whose identifier
        // already exists throws, and re-adding the whole horizon on every
        // foreground is churn the system does not need.
        let missing = days.filter { !alreadyPending.contains(identifier(for: $0)) }

        // Streak saver planning
        let currentTime = now ?? today.date
        let streakCandidates = (0..<streakHorizon).map { today.offset(by: $0) }
        var streakToSchedule: [DayIdentifier] = []
        var streakFireDates: [DayIdentifier: Date] = [:]
        var streakToRemove: [String] = []

        for day in streakCandidates {
            let id = streakIdentifier(for: day)
            let fireDate = streakFireDate(for: day)

            // If day is already captured or streak time has already passed today,
            // prune pending streak notification if one exists.
            if capturedDays.contains(day) || fireDate <= currentTime {
                if alreadyPending.contains(id) {
                    streakToRemove.append(id)
                }
                continue
            }

            if !alreadyPending.contains(id) {
                streakToSchedule.append(day)
                streakFireDates[day] = fireDate
                streakToRemove.append(id)
            }
        }

        return Plan(
            daysToSchedule: missing,
            fireDates: Dictionary(uniqueKeysWithValues: missing.map {
                ($0, momentStart($0))
            }),
            streakDaysToSchedule: streakToSchedule,
            streakFireDates: streakFireDates,
            // Replace what we are about to re-add, and prune any streak savers that are no longer needed.
            identifiersToRemove: missing.map(identifier(for:)) + streakToRemove
        )
    }

    /// Whether the pending count is low enough to be worth topping up.
    ///
    /// The gap between the threshold and the horizon is the buffer that absorbs
    /// a user who does not open the app for weeks — and the reason iOS's hard
    /// cap of 64 is not the horizon: 45 leaves room for the system and for a
    /// user who declines some of them.
    static func shouldRefill(pendingCount: Int, horizon: Int, threshold: Int) -> Bool {
        pendingCount < threshold && pendingCount < horizon
    }
}
