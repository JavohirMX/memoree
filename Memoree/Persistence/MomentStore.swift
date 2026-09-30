import Foundation
import SwiftData

/// The single write path for moments.
///
/// `@MainActor` because every mutation here also has to update observable UI
/// state, and SwiftData's `ModelContext` is not safe to share across
/// isolation domains. Reads are cheap; the data set is one user and a few
/// thousand rows.
///
/// Enforces the two invariants that matter:
/// 1. At most one accepted moment per `dayIdentifier`. Re-posting after a delete
///    updates the existing row rather than inserting a second one.
/// 2. `lateBy` and `isLate` are always consistent with the capture window, so
///    no caller can mark a late capture as on time by mistake.
@MainActor
@Observable
final class MomentStore {

    private let context: ModelContext
    private let calendar: Calendar

    init(context: ModelContext, calendar: Calendar = .current) {
        self.context = context
        self.calendar = calendar
    }

    // MARK: - Reading

    /// All live moments, newest first.
    var allMoments: [Moment] {
        let descriptor = FetchDescriptor<Moment>(
            predicate: #Predicate { !$0.isDeleted },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The moment for a given day, if one exists.
    func moment(for day: DayIdentifier) -> Moment? {
        let target = day.rawValue
        let descriptor = FetchDescriptor<Moment>(
            predicate: #Predicate { $0.dayIdentifier == target && !$0.isDeleted }
        )
        return try? context.fetch(descriptor).first
    }

    /// The most recent live moment, or `nil` on a fresh install.
    var mostRecentMoment: Moment? { allMoments.first }

    /// Moments on a specific day.
    func moments(on day: DayIdentifier) -> [Moment] {
        let target = day.rawValue
        let descriptor = FetchDescriptor<Moment>(
            predicate: #Predicate { $0.dayIdentifier == target && !$0.isDeleted },
            sortBy: [SortDescriptor(\.capturedAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    var hasAnyMoment: Bool { !allMoments.isEmpty }

    // MARK: - Writing

    /// Records a captured moment, replacing any existing moment for that day.
    ///
    /// - Parameters:
    ///   - interval: The capture window the shutter fired inside.
    ///   - capturedAt: Shutter time.
    ///   - Lateness is derived here, never passed in, so it cannot disagree
    ///     with the window.
    @discardableResult
    func record(
        day: DayIdentifier,
        interval: MomentInterval,
        capturedAt: Date,
        retakeCount: Int,
        backAssetIdentifier: String?,
        frontAssetIdentifier: String?,
        hasBTS: Bool = false,
        btsAssetIdentifier: String? = nil,
        location: (latitude: Double, longitude: Double)? = nil,
        note: String? = nil
    ) throws -> Moment {
        let lateness = interval.lateness(at: capturedAt)

        // Replacing rather than inserting keeps the one-moment-per-day
        // invariant true when a user re-captures after deleting.
        if let existing = moment(for: day) {
            context.delete(existing)
        }

        let moment = Moment(
            dayIdentifier: day.rawValue,
            momentStart: interval.start,
            windowEndsAt: interval.end,
            capturedAt: capturedAt,
            isLate: lateness > 0,
            lateBy: lateness,
            retakeCount: retakeCount,
            hasLocation: location != nil,
            latitude: location?.latitude,
            longitude: location?.longitude,
            note: note,
            hasBTS: hasBTS,
            btsAssetIdentifier: btsAssetIdentifier,
            backAssetIdentifier: backAssetIdentifier,
            frontAssetIdentifier: frontAssetIdentifier
        )
        context.insert(moment)
        try save()
        return moment
    }

    /// Attaches the Photos asset identifiers after a successful library write.
    ///
    /// Kept separate from `record` because the capture happens first and the
    /// write can fail. A moment with no identifiers is still a real moment and
    /// must not be discarded — Phase 5 wires the retry.
    func attachAssets(
        to moment: Moment,
        back: String?,
        front: String?,
        bts: String? = nil
    ) throws {
        moment.backAssetIdentifier = back
        moment.frontAssetIdentifier = front
        if let bts {
            moment.btsAssetIdentifier = bts
            moment.hasBTS = true
        }
        try save()
    }

    func updateNote(_ note: String?, for moment: Moment) throws {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        moment.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try save()
    }

    /// Tombstones a moment.
    ///
    /// The Photos assets are **not** deleted — they belong to the user
    /// (ADR-008). Only Memoree's record goes.
    func delete(_ moment: Moment) throws {
        moment.isDeleted = true
        moment.deletedAt = Date()
        try save()
    }

    // MARK: - Day records

    /// The resolved moment start for a day, if already persisted.
    func dayRecord(for day: DayIdentifier) -> DayRecord? {
        let target = day.rawValue
        let descriptor = FetchDescriptor<DayRecord>(predicate: #Predicate { $0.dayIdentifier == target })
        return try? context.fetch(descriptor).first
    }

    /// Persists a resolved moment so later window changes cannot move it.
    func saveDayRecord(day: DayIdentifier, momentStart: Date, notificationIdentifier: String? = nil) throws {
        if let existing = dayRecord(for: day) {
            existing.momentStart = momentStart
            if let notificationIdentifier { existing.notificationIdentifier = notificationIdentifier }
        } else {
            context.insert(DayRecord(
                dayIdentifier: day.rawValue,
                momentStart: momentStart,
                notificationIdentifier: notificationIdentifier
            ))
        }
        try save()
    }

    // MARK: - Settings

    /// The singleton settings row, created on first access.
    @discardableResult
    func settings() -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let created = AppSettings()
        context.insert(created)
        try? save()
        return created
    }

    func saveSettings(_ settings: AppSettings) throws {
        try save()
    }

    // MARK: - Persistence

    private func save() throws {
        guard context.hasChanges else { return }
        try context.save()
    }
}
