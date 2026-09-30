import Foundation

/// An immutable snapshot of a moment, reduced to the fields the statistics care
/// about.
///
/// `StreakCalculator` operates on these rather than on `Moment` directly. Two
/// reasons:
///
/// 1. **Purity.** No SwiftData in the arithmetic. `Moment` is a managed object
///    whose properties can be mutated behind the calculator's back; a value
///    copy cannot.
/// 2. **Concurrency.** `Moment` is not `Sendable`. A `Set<DayIdentifier>` is,
///    so the statistics can be computed anywhere without isolation ceremony.
///
/// Built by `MomentStore.facts()`, which applies the two filters that matter:
/// tombstoned moments are excluded, and deleted ones are never resurrected.
struct MomentFacts: Sendable, Hashable, Identifiable {

    let id: UUID
    let day: DayIdentifier

    /// Whether the capture landed inside the window. The only thing that
    /// grows a streak (ADR-009).
    let isOnTime: Bool

    let capturedAt: Date

    /// When today's window closed.
    ///
    /// Carried so `lateBy` can be derived correctly. An earlier version omitted
    /// it and computed lateness against local midnight, which reported a moment
    /// captured ten minutes late as roughly fourteen hours late — because
    /// midnight-to-window-end is most of a day.
    let windowEndsAt: Date

    let retakeCount: Int
    let hasBTS: Bool

    init(
        id: UUID,
        day: DayIdentifier,
        isOnTime: Bool,
        capturedAt: Date,
        windowEndsAt: Date,
        retakeCount: Int,
        hasBTS: Bool
    ) {
        self.id = id
        self.day = day
        self.isOnTime = isOnTime
        self.capturedAt = capturedAt
        self.windowEndsAt = windowEndsAt
        self.retakeCount = retakeCount
        self.hasBTS = hasBTS
    }

    /// How long after the window closed this moment was captured.
    ///
    /// Zero when on time. Derived rather than stored so it cannot disagree with
    /// the window it is measured against.
    var lateBy: TimeInterval {
        isOnTime ? 0 : max(0, capturedAt.timeIntervalSince(windowEndsAt))
    }
}

/// Aggregate statistics for the Stats screen and the streak badge.
///
/// Every field is derived on demand from `[MomentFacts]`. Nothing is cached,
/// because an incrementally-maintained counter is one more thing that can drift
/// out of agreement with the archive.
struct StreakSummary: Sendable, Equatable {

    /// Consecutive days with an on-time moment, counting back from today.
    ///
    /// Today is never itself a miss — see ADR-010.
    let currentStreak: Int

    /// Longest run of consecutive on-time days ever achieved.
    let longestStreak: Int

    /// Days with any moment at all, on time or late.
    let daysCaptured: Int

    /// Total moments. One per day, by invariant, but stated separately so the
    /// Stats screen does not have to infer it.
    let totalMoments: Int

    /// Late moments — captured, saved, archived, and not counted anywhere else.
    let lateMoments: Int

    /// On-time moments as a percentage of all moments. 0 when there are none.
    let onTimePercentage: Double

    /// Mean retakes across all moments. 0 when there are none.
    let averageRetakes: Double

    /// How many moments carry Behind the Scenes.
    let btsCount: Int

    /// Local hour (0–23) with the most captures, or `nil` with no moments.
    let busiestHour: Int?

    /// Consecutive days since the first moment with no capture at all.
    ///
    /// The complement of `daysCaptured`, which is what makes the number on the
    /// Stats screen mean something.
    let missedDays: Int

    static let empty = StreakSummary(
        currentStreak: 0, longestStreak: 0, daysCaptured: 0, totalMoments: 0,
        lateMoments: 0, onTimePercentage: 0, averageRetakes: 0, btsCount: 0,
        busiestHour: nil, missedDays: 0
    )

    init(
        currentStreak: Int, longestStreak: Int, daysCaptured: Int, totalMoments: Int,
        lateMoments: Int, onTimePercentage: Double, averageRetakes: Double,
        btsCount: Int, busiestHour: Int?, missedDays: Int
    ) {
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.daysCaptured = daysCaptured
        self.totalMoments = totalMoments
        self.lateMoments = lateMoments
        self.onTimePercentage = onTimePercentage
        self.averageRetakes = averageRetakes
        self.btsCount = btsCount
        self.busiestHour = busiestHour
        self.missedDays = missedDays
    }
}
