import Foundation
import SwiftData

/// One captured moment.
///
/// Memoree stores **no image bytes**. `backAssetIdentifier`, `frontAssetIdentifier`
/// and `btsAssetIdentifier` are `PHAsset.localIdentifier` values pointing into
/// the user's Photos library (AGENTS.md §2.4, ADR-007). Deleting Memoree loses
/// this row and nothing else — which is the entire point.
@Model
final class Moment {

    @Attribute(.unique) var id: UUID

    /// The user-experienced local calendar day this moment belongs to.
    ///
    /// At most one accepted moment per day; `MomentStore` enforces it. Naming
    /// this `dayIdentifier` rather than `day` avoids colliding with SwiftData's
    /// relationship vocabulary.
    @Attribute(.unique) var dayIdentifier: String

    /// The moment start that was scheduled for this day.
    var momentStart: Date

    /// `momentStart` + the capture window duration.
    var windowEndsAt: Date

    /// Shutter time of the accepted capture.
    var capturedAt: Date

    /// True when captured after `windowEndsAt`.
    var isLate: Bool

    /// Seconds past `windowEndsAt` at capture. Zero when on time.
    var lateBy: TimeInterval

    /// How many times the shutter was pressed before accepting.
    var retakeCount: Int

    /// Whether the user opted into recording coordinates for this moment.
    var hasLocation: Bool
    var latitude: Double?
    var longitude: Double?

    /// Optional free-text note. Never transmitted anywhere.
    var note: String?

    var hasBTS: Bool
    var btsAssetIdentifier: String?

    var backAssetIdentifier: String?
    var frontAssetIdentifier: String?

    /// When this moment was deleted, or `nil` if it is live.
    ///
    /// The tombstone is this date alone. An earlier version also stored a
    /// parallel `isDeleted: Bool`, and that boolean silently failed to persist
    /// on the Xcode 27 / iOS 27 SDK — setting it to `true` saved without error
    /// and read back `false` from a fresh `ModelContext`, including against a
    /// file-backed store. Isolated to two structurally identical booleans in
    /// one model, where a property named `plain` persisted correctly and one
    /// named `isDeleted` never did, so the cause is the property name in the
    /// toolchain's schema handling rather than anything in this code.
    ///
    /// Deriving the flag from the date removes the duplicated state entirely,
    /// which is better modelling regardless: two fields meaning the same thing
    /// is one more thing that can disagree with itself. See ADR-017.
    var deletedAt: Date?

    /// Whether this moment has been deleted from the archive.
    ///
    /// Computed, never stored.
    var isDeleted: Bool { deletedAt != nil }

    init(
        id: UUID = UUID(),
        dayIdentifier: String,
        momentStart: Date,
        windowEndsAt: Date,
        capturedAt: Date,
        isLate: Bool,
        lateBy: TimeInterval,
        retakeCount: Int,
        hasLocation: Bool = false,
        latitude: Double? = nil,
        longitude: Double? = nil,
        note: String? = nil,
        hasBTS: Bool = false,
        btsAssetIdentifier: String? = nil,
        backAssetIdentifier: String? = nil,
        frontAssetIdentifier: String? = nil
    ) {
        self.id = id
        self.dayIdentifier = dayIdentifier
        self.momentStart = momentStart
        self.windowEndsAt = windowEndsAt
        self.capturedAt = capturedAt
        self.isLate = isLate
        self.lateBy = lateBy
        self.retakeCount = retakeCount
        self.hasLocation = hasLocation
        self.latitude = latitude
        self.longitude = longitude
        self.note = note
        self.hasBTS = hasBTS
        self.btsAssetIdentifier = btsAssetIdentifier
        self.backAssetIdentifier = backAssetIdentifier
        self.frontAssetIdentifier = frontAssetIdentifier
    }
}

/// A day for which the moment time has been resolved.
///
/// Persisted so that changing the moment window mid-day does not retroactively
/// move a notification that has already been scheduled (docs/TRD.md §4.1).
@Model
final class DayRecord {

    @Attribute(.unique) var dayIdentifier: String
    var momentStart: Date
    var notificationIdentifier: String?

    init(dayIdentifier: String, momentStart: Date, notificationIdentifier: String? = nil) {
        self.dayIdentifier = dayIdentifier
        self.momentStart = momentStart
        self.notificationIdentifier = notificationIdentifier
    }
}

/// A streak value. Two rows exist: `id == "current"` and `id == "longest"`.
@Model
final class StreakRecord {

    @Attribute(.unique) var id: String
    var value: Int
    var startedAt: Date?
    var endedAt: Date?

    static let currentKey = "current"
    static let longestKey = "longest"

    init(id: String, value: Int, startedAt: Date? = nil, endedAt: Date? = nil) {
        self.id = id
        self.value = value
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// Singleton settings row.
///
/// Time window, capture duration, BTS preferences and album behaviour.
@Model
final class AppSettings {

    @Attribute(.unique) var id: String

    var windowStartMinutes: Int
    var windowEndMinutes: Int

    /// Capture window length in seconds. Default 120, as in BeReal.
    var windowDuration: Int

    var btsEnabled: Bool
    var btsDuration: Double
    var saveBTS: Bool

    var saveToAlbum: Bool
    /// Guards against recreating an album the user deleted (docs/TRD.md §6.4).
    var albumCreationAttempted: Bool

    var onboardingComplete: Bool

    init(
        id: String = "singleton",
        windowStartMinutes: Int = TimeWindow.default.startMinutes,
        windowEndMinutes: Int = TimeWindow.default.endMinutes,
        windowDuration: Int = 120,
        btsEnabled: Bool = true,
        btsDuration: Double = 5.0,
        saveBTS: Bool = true,
        saveToAlbum: Bool = false,
        albumCreationAttempted: Bool = false,
        onboardingComplete: Bool = false
    ) {
        self.id = id
        self.windowStartMinutes = windowStartMinutes
        self.windowEndMinutes = windowEndMinutes
        self.windowDuration = windowDuration
        self.btsEnabled = btsEnabled
        self.btsDuration = btsDuration
        self.saveBTS = saveBTS
        self.saveToAlbum = saveToAlbum
        self.albumCreationAttempted = albumCreationAttempted
        self.onboardingComplete = onboardingComplete
    }

    /// Validated window, so a corrupt store degrades instead of crashing.
    var timeWindow: TimeWindow {
        get { TimeWindow(startMinutes: windowStartMinutes, endMinutes: windowEndMinutes) }
        set {
            windowStartMinutes = newValue.startMinutes
            windowEndMinutes = newValue.endMinutes
        }
    }

    var captureDuration: TimeInterval {
        get { TimeInterval(windowDuration) }
        set { windowDuration = Int(newValue) }
    }
}
