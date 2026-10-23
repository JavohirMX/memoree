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

    /// Whether the capture landed inside the reminder window.
    ///
    /// **Does not grow the streak** (ADR-032 — every capture counts). Kept so
    /// export JSON and metadata can still answer "was this inside the window"
    /// without the UI ever learning the distinction (ADR-023: no badge).
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

    /// Optional micro-journal note entered by the user.
    let note: String?

    init(
        id: UUID,
        day: DayIdentifier,
        isOnTime: Bool,
        capturedAt: Date,
        windowEndsAt: Date,
        retakeCount: Int,
        hasBTS: Bool,
        btsAssetIdentifier: String? = nil,
        assets: SavedAssetPair? = nil,
        note: String? = nil
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
        self.note = note
    }

    /// How long after the window closed this moment was captured.
    ///
    /// Zero when on time. Derived rather than stored so it cannot disagree with
    /// the window it is measured against.
    var lateBy: TimeInterval {
        isOnTime ? 0 : max(0, capturedAt.timeIntervalSince(windowEndsAt))
    }
}

/// Which moment the detail screen shows for a given pager selection.
///
/// Pure so the rule can be tested without SwiftUI. The detail view used to fall
/// back to `moments[0]` when the selected id was missing — in a newest-first
/// archive that is today's latest capture, which is exactly the wrong memory
/// when the user tapped an older one.
enum MomentDetailSelection: Sendable {

    /// The moment on screen: the selected id when it is in `moments`, otherwise
    /// the moment the user opened. Never substitutes the list's first entry.
    static func resolve(
        opened: MomentFacts,
        moments: [MomentFacts],
        selectedID: UUID
    ) -> MomentFacts {
        moments.first(where: { $0.id == selectedID }) ?? opened
    }
}

/// Aggregate statistics for the Stats screen and the streak badge.
///
/// Every field is derived on demand from `[MomentFacts]`. Nothing is cached,
/// because an incrementally-maintained counter is one more thing that can drift
/// out of agreement with the archive.
struct StreakSummary: Sendable, Equatable {

    /// Consecutive days with any capture, counting back from today.
    ///
    /// A day with no moment ends the walk. Today is never itself a miss —
    /// see ADR-010. Timing inside the reminder window is irrelevant (ADR-032).
    let currentStreak: Int

    /// Longest run of consecutive days with any moment.
    ///
    /// Same rule as `currentStreak` (ADR-032) — both count every capture day.
    let longestStreak: Int

    /// Days with any moment at all.
    let daysCaptured: Int

    /// Total moments. May exceed `daysCaptured` when a day has multiple
    /// captures (ADR-030). Stated separately so Stats does not have to infer it.
    let totalMoments: Int

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

    /// When the very first moment was captured.
    let firstCaptureDate: Date?

    /// How many moments include an attached note.
    let notesCount: Int

    /// Capture counts mapped by local hour of day (0–23).
    let hourlyDistribution: [Int: Int]

    /// Percentage of days captured since the start of recording (0–100).
    let consistencyPercentage: Double?

    static let empty = StreakSummary(
        currentStreak: 0, longestStreak: 0, daysCaptured: 0, totalMoments: 0,
        averageRetakes: 0, btsCount: 0, busiestHour: nil, missedDays: 0,
        firstCaptureDate: nil, notesCount: 0, hourlyDistribution: [:],
        consistencyPercentage: nil
    )

    init(
        currentStreak: Int, longestStreak: Int, daysCaptured: Int, totalMoments: Int,
        averageRetakes: Double, btsCount: Int, busiestHour: Int?, missedDays: Int,
        firstCaptureDate: Date? = nil, notesCount: Int = 0,
        hourlyDistribution: [Int: Int] = [:], consistencyPercentage: Double? = nil
    ) {
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.daysCaptured = daysCaptured
        self.totalMoments = totalMoments
        self.averageRetakes = averageRetakes
        self.btsCount = btsCount
        self.busiestHour = busiestHour
        self.missedDays = missedDays
        self.firstCaptureDate = firstCaptureDate
        self.notesCount = notesCount
        self.hourlyDistribution = hourlyDistribution
        self.consistencyPercentage = consistencyPercentage
    }
}
