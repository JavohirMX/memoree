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
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The moment for a given day, if one exists.
    func moment(for day: DayIdentifier) -> Moment? {
        let target = day.rawValue
        var descriptor = FetchDescriptor<Moment>(
            predicate: #Predicate { $0.dayIdentifier == target && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Moments on a specific day.
    func moments(on day: DayIdentifier) -> [Moment] {
        let target = day.rawValue
        let descriptor = FetchDescriptor<Moment>(
            predicate: #Predicate { $0.dayIdentifier == target && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.capturedAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    var hasAnyMoment: Bool { !allMoments.isEmpty }

    /// Tombstoned moments — deleted from the archive but still on disk.
    ///
    /// Retained rather than erased so that a future "deleted moments" view can
    /// show what was removed, and so the Photos asset identifiers survive for
    /// reference. Memoree still never touches the user's library (ADR-008).
    var tombstonedMoments: [Moment] {
        let descriptor = FetchDescriptor<Moment>(
            predicate: #Predicate { $0.deletedAt != nil },
            sortBy: [SortDescriptor(\.deletedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Every persisted day record, for diagnostics and the horizon view.
    var allDayRecords: [DayRecord] {
        let descriptor = FetchDescriptor<DayRecord>(
            sortBy: [SortDescriptor(\.dayIdentifier)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Immutable snapshots for the statistics layer.
    ///
    /// Tombstoned moments are excluded, which is what makes deleting a moment
    /// recompute the streak immediately (ADR-008): the row stops being visible
    /// to the calculator without any cached value needing invalidating.
    ///
    /// The asset identifiers come along because a screen holding a
    /// `MomentFacts` needs them to show the photographs, and `Moment` is not
    /// `Sendable` — a view cannot hold one and cross an isolation boundary with
    /// it. Both halves travel together or not at all.
    func facts() -> [MomentFacts] {
        allMoments.map { moment in
            MomentFacts(
                id: moment.id,
                day: DayIdentifier(string: moment.dayIdentifier, calendar: calendar)
                    ?? DayIdentifier(date: moment.capturedAt, calendar: calendar),
                isOnTime: !moment.isLate,
                capturedAt: moment.capturedAt,
                windowEndsAt: moment.windowEndsAt,
                retakeCount: moment.retakeCount,
                hasBTS: moment.hasBTS,
                btsAssetIdentifier: moment.btsAssetIdentifier,
                assets: Self.assets(of: moment),
                note: moment.note
            )
        }
    }

    /// The pair, or `nil` when the moment has no photographs on record.
    ///
    /// Half a pair is treated as no pair. The write path cannot produce it — both
    /// assets are created in one `performChanges` block — so if only one is
    /// present, the moment is not displayable and reporting half of it would
    /// just move the "cannot happen" decision to every caller.
    static func assets(of moment: Moment) -> SavedAssetPair? {
        guard let back = moment.backAssetIdentifier,
              let front = moment.frontAssetIdentifier
        else { return nil }
        return SavedAssetPair(back: back, front: front)
    }

    /// Every statistic the app displays, computed fresh from the archive.
    ///
    /// Nothing is cached. A stored counter is one more thing that can drift out
    /// of agreement with the moments it summarises, and the recompute is
    /// microseconds over a few thousand rows.
    func summary(today: DayIdentifier? = nil) -> StreakSummary {
        StreakCalculator.summary(
            facts: facts(),
            today: today ?? DayIdentifier(date: Date(), calendar: calendar),
            calendar: calendar
        )
    }

    /// Finds moments captured on the same calendar month and day in previous years ("On This Day").
    ///
    /// Excludes the current year. On leap years (Feb 29), checks Feb 29 captures in past leap years,
    /// or Feb 28 on non-leap years if needed.
    func flashbackMoments(for date: Date = Date()) -> [MomentFacts] {
        let currentComponents = calendar.dateComponents([.year, .month, .day], from: date)
        guard let currentYear = currentComponents.year,
              let currentMonth = currentComponents.month,
              let currentDay = currentComponents.day
        else { return [] }

        return facts()
            .filter { fact in
                let comp = calendar.dateComponents([.year, .month, .day], from: fact.day.date)
                guard let y = comp.year, let m = comp.month, let d = comp.day else { return false }
                guard y < currentYear else { return false }
                return m == currentMonth && d == currentDay
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    /// Moments on the same calendar month and day across every year, including today.
    ///
    /// Feeds the "this day across years" flipbook (ADR-038). Selection is pure —
    /// see `SameDayFlipbook`. Distinct from `flashbackMoments`, which hides the
    /// current year so ON THIS DAY does not repeat today's card.
    func sameDayAcrossYearsMoments(for date: Date = Date()) -> [MomentFacts] {
        SameDayFlipbook.moments(from: facts(), matching: date, calendar: calendar)
    }

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
            note: Self.normalizedNote(note),
            hasBTS: hasBTS,
            btsAssetIdentifier: btsAssetIdentifier,
            backAssetIdentifier: backAssetIdentifier,
            frontAssetIdentifier: frontAssetIdentifier
        )
        context.insert(moment)
        try save()
        return moment
    }

    func updateNote(_ note: String?, for moment: Moment) throws {
        moment.note = Self.normalizedNote(note)
        try save()
    }

    #if DEBUG
    /// Points existing moments at real `PHAsset` identifiers, for the layout audit.
    ///
    /// **A debug affordance, and the only method here that writes asset
    /// identifiers without a photograph having been captured.** `record` is the
    /// single write path in production and this is emphatically not a second one:
    /// it exists so the archive grid, the Today composite and the moment detail
    /// screen can be *looked at* with pixels in them, which a grid of empty
    /// rectangles does not exercise — the `scaledToFit` mat, the front inset sized
    /// from the short side, and the composite renderer all need a real image to
    /// reveal anything.
    ///
    /// Compiled out of release. On a device this would violate ADR-008 in the most
    /// literal way available — pointing a user's archive at assets they never
    /// captured — so `AppEnvironment` gates the call behind a runtime
    /// simulator check rather than trusting the `#if` alone.
    func attachPhotographsForSeeding(
        to moments: [Moment],
        back: [String],
        front: [String]
    ) throws {
        for (index, moment) in moments.enumerated() {
            moment.backAssetIdentifier = back[index % back.count]
            moment.frontAssetIdentifier = front[index % front.count]
        }
        try save()
    }
    #endif

    /// Trims a note and treats an empty or whitespace-only note as absent.
    ///
    /// Shared by `record` and `updateNote` so a note entered at capture time and
    /// one edited later are normalised identically.
    private static func normalizedNote(_ note: String?) -> String? {
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Tombstones a moment.
    ///
    /// The Photos assets are **not** deleted — they belong to the user
    /// (ADR-008). Only Memoree's record goes.
    func delete(_ moment: Moment) throws {
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

    /// Discards every persisted day record from `day` onward.
    ///
    /// Exists because changing the moment window is not a settings write. Each
    /// day in the horizon has a resolved `DayRecord`, and `AppEnvironment
    /// .interval(for:)` prefers a persisted record over the configured window so
    /// a notification cannot move retroactively (TRD §4.1, FR-2). So a new
    /// window has to *delete* the future before it can take effect — otherwise
    /// the picker in Settings is a control that changes nothing for 45 days.
    ///
    /// The caller chooses the boundary, and the reason it is not a parameter of
    /// this function is that the boundary is a product decision rather than a
    /// storage detail: today keeps its moment even if the new window would place
    /// it elsewhere, because it may already have been notified.
    ///
    /// - Returns: how many records were discarded, so a test can assert the
    ///   operation did something rather than merely did not fail.
    @discardableResult
    func discardDayRecords(from day: DayIdentifier) throws -> Int {
        let boundary = day.rawValue
        let descriptor = FetchDescriptor<DayRecord>(
            predicate: #Predicate { $0.dayIdentifier >= boundary },
            sortBy: [SortDescriptor(\.dayIdentifier)]
        )
        let records = try context.fetch(descriptor)
        for record in records {
            context.delete(record)
        }
        try save()
        return records.count
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

    /// The single choke point every mutation in this type passes through.
    ///
    /// Narrowing to `StoreError` here rather than at each call site is what
    /// makes the error user-presentable: SwiftData's own errors are excellent
    /// in a log and useless on a screen, and they are the only thing that
    /// would otherwise reach `CameraViewModel`'s error mapping.
    private func save() throws {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            throw StoreError.wrapping(error)
        }
    }
}
