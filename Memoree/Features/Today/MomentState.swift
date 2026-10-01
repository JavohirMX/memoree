import Foundation

/// The state of today's moment.
///
/// Enumerated exhaustively so the Today screen cannot silently omit a case.
/// The resolver is a pure function of `(now, interval, today's moment)` — no
/// clock reads, no database access — which makes every state reachable in a
/// unit test (docs/TRD.md §8).
enum MomentState: Equatable, Sendable {

    /// The window has not opened. Countdown to it.
    case scheduled(timeUntilStart: TimeInterval)

    /// The window is open now. Capture is permitted.
    case open(remaining: TimeInterval)

    /// Captured on time today.
    case captured(late: Bool, lateBy: TimeInterval)

    /// The window has closed and nothing was captured. Capture is still allowed,
    /// and the streak will not grow.
    case lateAvailable(lateBy: TimeInterval)

    /// The day is over with nothing captured.
    case missed

    /// Whether the shutter should be offered.
    ///
    /// **Always `true` since ADR-023.** This used to be false for `scheduled`,
    /// which is what made the early-post refusal (`FR-5`, `AGENTS.md` §2 rule 10)
    /// structural rather than a disabled button — a nice piece of work that was
    /// answering the wrong question, and that contradicted the app's own
    /// onboarding copy.
    ///
    /// Kept as a property rather than deleted so the view reads the same and the
    /// rule has one home. A view that asked the user for permission it always
    /// grants is a worse thing than one that never asks.
    var allowsCapture: Bool { true }

    /// True while the countdown is running toward an unopened window.
    var isAwaitingMoment: Bool {
        if case .scheduled = self { return true }
        return false
    }

    /// Whether this moment counts toward the streak.
    var countsForStreak: Bool {
        if case .captured(let late, _) = self { return !late }
        return false
    }

    /// Whether a moment already exists for today.
    var isCaptured: Bool {
        if case .captured = self { return true }
        return false
    }

    /// Whether this moment is late, for the amber badge.
    var isLate: Bool {
        switch self {
        case .captured(let late, _): return late
        case .lateAvailable: return true
        case .scheduled, .open, .missed: return false
        }
    }

    /// Whether the amber `late` treatment applies, including the not-yet-won
    /// state where the window has closed but nothing was shot.
    var showsLateBadge: Bool {
        switch self {
        case .captured, .lateAvailable: return true
        case .scheduled, .open, .missed: return false
        }
    }
}

/// Resolves `MomentState` from the clock, today's window, and today's moment.
///
/// Pure. Everything that makes this function tricky — the inclusivity of the
/// window edges, and the fact that today is never itself a miss — is pinned by
/// `MomentStateTests`.
enum MomentStateResolver {

    /// - Parameters:
    ///   - now: The current instant.
    ///   - interval: Today's capture window.
    ///   - todayMoment: Today's accepted moment, if one exists.
    ///   - dayEnd: The instant today's calendar day ends, used only to tell
    ///     `lateAvailable` from `missed`.
    static func resolve(
        now: Date,
        interval: MomentInterval,
        todayMoment: MomentFacts?,
        dayEnd: Date
    ) -> MomentState {
        if let moment = todayMoment {
            return .captured(
                late: !moment.isOnTime,
                lateBy: moment.isOnTime ? 0 : moment.lateBy
            )
        }

        // Before the window opens.
        if now < interval.start {
            return .scheduled(timeUntilStart: interval.start.timeIntervalSince(now))
        }

        // Inside the window, inclusive at both edges so a capture on the final
        // instant still counts as on time.
        if now <= interval.end {
            return .open(remaining: interval.remaining(at: now))
        }

        // The window closed without a capture.
        if now < dayEnd {
            return .lateAvailable(lateBy: interval.lateness(at: now))
        }

        return .missed
    }

    /// The end of the calendar day containing `date`.
    static func endOfDay(containing date: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? date
    }
}
