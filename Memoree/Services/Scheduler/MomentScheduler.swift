import Foundation

/// Resolves the moment time for a day.
///
/// A protocol so the scheduler can be faked in tests and so the derivation can
/// be swapped without touching callers. Per AGENTS.md §3, every service has a
/// protocol and a test double.
protocol MomentScheduler: Sendable {

    /// The moment start for `day`, inside `window`.
    ///
    /// Deterministic. Calling twice with the same arguments returns the same
    /// instant — callers rely on this to avoid double-scheduling.
    func momentStart(
        for day: DayIdentifier,
        window: TimeWindow,
        windowDuration: TimeInterval
    ) -> Date

    /// The full capture interval for `day`.
    func momentInterval(
        for day: DayIdentifier,
        window: TimeWindow,
        windowDuration: TimeInterval
    ) -> MomentInterval
}

/// A capture interval: when the window opens and when it closes.
struct MomentInterval: Equatable, Hashable, Sendable, Codable {

    let start: Date
    let end: Date

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// Whether `now` falls inside the capture window, inclusive of both edges.
    ///
    /// Inclusive at the start so the countdown reads 02:00 exactly when the
    /// window opens, and inclusive at the end so a capture at precisely the
    /// closing instant is still on time.
    func contains(_ now: Date) -> Bool {
        now >= start && now <= end
    }

    /// Seconds remaining until the window closes. Zero once it has.
    func remaining(at now: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(now))
    }

    /// How long past `end` a capture at `now` is. Zero when on time.
    func lateness(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(end))
    }
}

enum SchedulerError: Error, LocalizedError, Equatable {
    case secretUnavailable
    case notificationDenied
    case schedulingFailed(String)

    var errorDescription: String? {
        switch self {
        case .secretUnavailable:
            "Memoree could not read its scheduling key."
        case .notificationDenied:
            "Notifications are turned off, so Memoree cannot remind you."
        case .schedulingFailed(let reason):
            "Could not schedule the moment: \(reason)"
        }
    }
}
