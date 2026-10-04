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
    /// grows a streak (ADR-023) — and, since the UI is not allowed to know
    /// either way, the only place the distinction survives at all.
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

    /// Whether this moment has a Behind-the-Scenes clip.
    let hasBTS: Bool

    /// Where that clip was written, when it has one.
    ///
    /// **Carried beside `hasBTS` rather than instead of it, and that duplication is
    /// the point.** `hasBTS` answers "does this moment have one", which is what a
    /// cell's badge and the stats screen need and which is a `Bool` a screen can
    /// hold. The identifier answers "where", which is what playback needs. Deriving
    /// one from the other is impossible in the direction that matters — `true` with
    /// no identifier is the ordinary "you deleted the clip in Photos" state, and
    /// treating it as an error would show the user a red state for something they
    /// did on purpose (ADR-008).
    let btsAssetIdentifier: String?

    /// The two `PHAsset.localIdentifier`s the photographs were written under.
    ///
    /// Carried here so a screen holding a `MomentFacts` can display the moment
    /// without reaching for the managed object. The archive, the Today screen's
    /// composite, detail, and share all need these, and every one of them was
    /// going to re-fetch the row to get them.
    ///
    /// Nil on **both** halves together or not at all. A moment with one half
    /// and no other is not a state the write path can produce — the two assets
    /// are created in one `performChanges` block, so either both land or
    /// neither does (TRD §6.2) — and modelling the impossible case would only
    /// invite a caller to handle it.
    let assets: SavedAssetPair?

    init(
        id: UUID,
        day: DayIdentifier,
        isOnTime: Bool,
        capturedAt: Date,
        windowEndsAt: Date,
        retakeCount: Int,
        hasBTS: Bool,
        btsAssetIdentifier: String? = nil,
        assets: SavedAssetPair? = nil
    ) {
        self.id = id
        self.day = day
        self.isOnTime = isOnTime
        self.capturedAt = capturedAt
        self.windowEndsAt = windowEndsAt
        self.retakeCount = retakeCount
        self.hasBTS = hasBTS
        self.btsAssetIdentifier = btsAssetIdentifier
        self.assets = assets
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

    /// Consecutive on-time days counting back from today, with off-window days
    /// skipped and a day with no moment ending the walk.
    ///
    /// Today is never itself a miss — see ADR-010.
    let currentStreak: Int

    /// Longest run of consecutive days with *any* moment, on time or not.
    ///
    /// Deliberately a different rule from `currentStreak`, and the reason is
    /// that the same rule would make the two numbers identical for anyone who
    /// has never missed a whole day. See `StreakCalculator.longestStreak`.
    let longestStreak: Int

    /// Days with any moment at all, on time or late.
    let daysCaptured: Int

    /// Total moments. One per day, by invariant, but stated separately so the
    /// Stats screen does not have to infer it.
    let totalMoments: Int

    /// Off-window moments — captured, saved, archived, and skipped by the walk.
    ///
    /// Not displayed anywhere yet. It exists because it is the honest aggregate
    /// behind `onTimePercentage`, and because the per-moment late marker was
    /// removed on purpose (ADR-023) — so this is where the distinction between
    /// on-time and off-window is allowed to be visible, if it ever is.
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
