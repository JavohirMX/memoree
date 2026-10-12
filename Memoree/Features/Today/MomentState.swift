import Foundation

/// The state of today's moment.
///
/// Enumerated exhaustively so the Today screen cannot silently omit a case.
/// The resolver is a pure function of `(now, interval, today's moment)` — no
/// clock reads, no database access — which makes every state reachable in a
/// unit test (docs/TRD.md §8).
///
/// **No case carries a payload, and that is the point.** An earlier version
/// carried `late`/`lateBy` on `captured` and a countdown on `scheduled` and
/// `open`. The view read all three: it rendered an amber *"posted 12m late"*
/// badge, told the user *"the streak did not grow"*, and ticked a number at a
/// deadline that no longer closed.
///
/// ADR-023 made off-window moments indistinguishable from on-time ones; ADR-024
/// and ADR-032 removed the home-screen countdown. Rather than delete the
/// branches that rendered them, the *data* went, so the view is structurally
/// incapable of leaking either. Hiding a branch is a promise; not carrying the
/// value is one the compiler keeps (AGENTS.md §6).
///
/// `Hashable` so a test can assert on the *set* of states the resolver can
/// produce rather than one case at a time.
enum MomentState: Hashable, Sendable {

    /// The reminder has not fired yet. Capture is permitted and counts.
    case scheduled

    /// The reminder window is open now. Capture counts.
    case open

    /// The reminder window closed without a capture. Capture is still permitted
    /// and still counts toward the streak (ADR-032).
    ///
    /// **Not a miss.** A day ends only when a day passes with no photograph at
    /// all, and by then it is tomorrow and the state is `scheduled` again
    /// (ADR-010). This case says the reminder window is gone, nothing more.
    case windowPassed

    /// Captured today, on time or not — the two are indistinguishable here.
    case captured

    /// Whether a moment already exists for today.
    ///
    /// The only predicate a view may ask. In particular there is deliberately no
    /// `countsForStreak` and no `isLate`: ADR-023 requires that an off-window
    /// moment be indistinguishable from an on-time one, so no screen may ask.
    /// Streak math no longer reads timing either (ADR-032 — every capture
    /// counts); `isOnTime` survives only on `MomentFacts` for export metadata.
    var isCaptured: Bool { self == .captured }
}

/// Resolves `MomentState` from the clock, today's window, and today's moment.
///
/// Pure, and it takes nothing but what it needs. The inclusivity of the window
/// edges is the one subtlety left, and `MomentStateTests` pins it.
enum MomentStateResolver {

    /// - Parameters:
    ///   - now: The current instant.
    ///   - interval: Today's capture window.
    ///   - todayMoment: Today's accepted moment, if one exists.
    static func resolve(
        now: Date,
        interval: MomentInterval,
        todayMoment: MomentFacts?
    ) -> MomentState {
        if todayMoment != nil { return .captured }

        // Before the window opens.
        if now < interval.start { return .scheduled }

        // Inside the window, inclusive at both edges so a capture on the final
        // instant still counts as on time.
        if now <= interval.end { return .open }

        return .windowPassed
    }
}
