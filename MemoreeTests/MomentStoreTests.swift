import Foundation
import SwiftData
import Testing

@testable import Memoree

/// Phase 2 — `MomentStore` against a real in-memory SwiftData container.
///
/// These are the persistence-level invariants: one moment per day, lateness
/// derived rather than trusted, and deleting a moment recomputing the streak
/// without any cache invalidation step.
///
/// Runs entirely in memory. No device, no simulator disk state.
@Suite("Phase 2 — MomentStore")
@MainActor
struct MomentStoreTests {

    private func makeStore() throws -> (MomentStore, ModelContext) {
        let container = try Persistence.inMemoryContainer()
        let context = ModelContext(container)
        return (MomentStore(context: context), context)
    }

    private func day(_ s: String) throws -> DayIdentifier {
        try #require(DayIdentifier(string: s))
    }

    private func interval(_ day: DayIdentifier) -> MomentInterval {
        let start = day.date.addingTimeInterval(14 * 3600)   // 14:00
        return MomentInterval(start: start, end: start.addingTimeInterval(120))
    }

    @Test("Settings are created once and reused")
    func settingsSingleton() throws {
        let (store, _) = try makeStore()
        let first = store.settings()
        let second = store.settings()
        #expect(first.id == second.id)
        #expect(store.settings().timeWindow == TimeWindow.default)
        #expect(store.settings().captureDuration == 120)
    }

    @Test("Recording a moment persists it and stamps the day identifier")
    func recordsMoment() throws {
        let (store, _) = try makeStore()
        let d = try day("2026-09-30")

        try store.record(
            day: d,
            interval: interval(d),
            capturedAt: d.date.addingTimeInterval(14 * 3600 + 30),
            retakeCount: 2,
            backAssetIdentifier: "back-id",
            frontAssetIdentifier: "front-id"
        )

        #expect(store.allMoments.count == 1)
        let saved = try #require(store.moment(for: d))
        #expect(saved.dayIdentifier == "2026-09-30")
        #expect(saved.retakeCount == 2)
        #expect(saved.backAssetIdentifier == "back-id")
        #expect(!saved.isLate)
        #expect(saved.lateBy == 0)
    }

    @Test("Lateness is derived from the window, never accepted from the caller")
    func derivesLateness() throws {
        let (store, _) = try makeStore()
        let d = try day("2026-09-30")
        let window = interval(d)

        // Capture two hours after the window closed.
        try store.record(
            day: d,
            interval: window,
            capturedAt: window.end.addingTimeInterval(7200),
            retakeCount: 0,
            backAssetIdentifier: nil,
            frontAssetIdentifier: nil
        )

        let saved = try #require(store.moment(for: d))
        #expect(saved.isLate)
        #expect(abs(saved.lateBy - 7200) < 0.5)
    }

    @Test("A capture exactly at the closing instant is still on time")
    func boundaryIsOnTime() throws {
        let (store, _) = try makeStore()
        let d = try day("2026-09-30")
        let window = interval(d)

        try store.record(
            day: d,
            interval: window,
            capturedAt: window.end,
            retakeCount: 0,
            backAssetIdentifier: nil,
            frontAssetIdentifier: nil
        )

        #expect(try #require(store.moment(for: d)).isLate == false)
    }

    @Test("One moment per day — re-capturing replaces rather than duplicates")
    func oneMomentPerDay() throws {
        let (store, _) = try makeStore()
        let d = try day("2026-09-30")
        let window = interval(d)

        for retakes in 0..<5 {
            try store.record(
                day: d,
                interval: window,
                capturedAt: window.start.addingTimeInterval(10),
                retakeCount: retakes,
                backAssetIdentifier: "back-\(retakes)",
                frontAssetIdentifier: nil
            )
        }

        #expect(store.allMoments.count == 1, "re-capture must replace, not insert")
        #expect(try #require(store.moment(for: d)).retakeCount == 4)
        #expect(store.moment(for: d)?.backAssetIdentifier == "back-4")
    }

    @Test("Deleting tombstones the moment and it leaves the live history")
    func deleteTombstones() throws {
        let (store, _) = try makeStore()
        let d = try day("2026-09-30")

        try store.record(
            day: d, interval: interval(d),
            capturedAt: interval(d).start,
            retakeCount: 0, backAssetIdentifier: "keep-me", frontAssetIdentifier: nil
        )
        try store.delete(try #require(store.moment(for: d)))

        #expect(store.allMoments.isEmpty)
        #expect(store.moment(for: d) == nil)
        #expect(store.hasAnyMoment == false)
        // The row is tombstoned, not erased: the Photos asset identifier is
        // retained because Memoree never deletes from the user's library
        // (ADR-008). A future "deleted moments" view would show it.
        //
        // Asserted on a **freshly fetched** instance. SwiftData does not refresh
        // an already-materialised object after `context.save()`, so reading
        // `isDeleted` back off the instance passed to `delete` reports the
        // stale `false` even though the row is correctly tombstoned. The
        // predicate fetch is the authoritative read.
        let tombstone = try #require(store.tombstonedMoments.first)
        #expect(tombstone.backAssetIdentifier == "keep-me")
        #expect(tombstone.deletedAt != nil)
        #expect(tombstone.isDeleted, "isDeleted is derived from deletedAt")
    }

    @Test("The tombstone survives a fresh ModelContext")
    func tombstonePersists() throws {
        // Regression guard. The tombstone used to be a stored `isDeleted: Bool`,
        // which silently failed to persist on this SDK: the write saved without
        // error and read back `false` from a brand-new context. Asserting only on
        // the in-memory instance would have missed it.
        let container = try Persistence.inMemoryContainer()
        let context = ModelContext(container)
        let store = MomentStore(context: context)
        let d = try day("2026-09-30")

        try store.record(
            day: d, interval: interval(d), capturedAt: interval(d).start,
            retakeCount: 0, backAssetIdentifier: "keep-me", frontAssetIdentifier: nil
        )
        try store.delete(try #require(store.moment(for: d)))

        // A separate context sees the committed state, not the cached instance.
        let verifyingContext = ModelContext(container)
        let rows = try verifyingContext.fetch(
            FetchDescriptor<Moment>(predicate: #Predicate { $0.deletedAt != nil }))
        let tombstone = try #require(rows.first)
        #expect(tombstone.isDeleted)
        #expect(tombstone.backAssetIdentifier == "keep-me")
    }

    @Test("Deleting today's on-time moment resets the streak immediately")
    func deleteRecomputesStreak() throws {
        let (store, _) = try makeStore()
        let today = try day("2026-09-30")

        for offset in [0, -1, -2] as [Int] {
            let d = today.offset(by: offset)
            try store.record(
                day: d, interval: interval(d),
                capturedAt: interval(d).start,
                retakeCount: 0, backAssetIdentifier: nil, frontAssetIdentifier: nil
            )
        }
        #expect(store.summary(today: today).currentStreak == 3)

        try store.delete(try #require(store.moment(for: today)))
        #expect(store.summary(today: today).currentStreak == 2,
                "a deleted moment must stop justifying the streak")
    }

    @Test("An off-window day is transparent to the persisted streak too")
    func offWindowIsTransparentToPersistedStreak() throws {
        let (store, _) = try makeStore()
        let today = try day("2026-09-30")

        for offset in [0, -1, -2] as [Int] {
            let d = today.offset(by: offset)
            let window = interval(d)
            let captured = offset == 0 ? window.end.addingTimeInterval(3600) : window.start
            try store.record(
                day: d, interval: window, capturedAt: captured,
                retakeCount: 0, backAssetIdentifier: nil, frontAssetIdentifier: nil
            )
        }

        let s = store.summary(today: today)
        // Was: currentStreak == 0, "late today breaks the run" — ADR-009, now
        // superseded by ADR-023. An off-window day is transparent: it does not
        // grow the streak and it does not end it, so the two on-time days
        // before it still count and the streak is 2.
        #expect(s.currentStreak == 2, "an off-window day is skipped, not an ending")
        // `longestStreak` counts days with any moment, so all three days are in
        // the best run.
        #expect(s.longestStreak == 3)
        #expect(s.lateMoments == 1)
    }

    @Test("Day records persist and are reused")
    func dayRecordsPersist() throws {
        let (store, _) = try makeStore()
        let d = try day("2026-09-30")
        let start = d.date.addingTimeInterval(14 * 3600)

        try store.saveDayRecord(day: d, momentStart: start, notificationIdentifier: "moment.2026-09-30")
        let record = try #require(store.dayRecord(for: d))
        #expect(record.momentStart == start)
        #expect(record.notificationIdentifier == "moment.2026-09-30")

        // Re-saving updates rather than duplicating.
        try store.saveDayRecord(day: d, momentStart: start.addingTimeInterval(60))
        #expect(store.allDayRecords.count == 1)
    }

    @Test("Notes are trimmed and empty notes clear")
    func notesTrim() throws {
        let (store, _) = try makeStore()
        let d = try day("2026-09-30")
        try store.record(
            day: d, interval: interval(d), capturedAt: interval(d).start,
            retakeCount: 0, backAssetIdentifier: nil, frontAssetIdentifier: nil,
            note: "  a good day  "
        )
        let moment = try #require(store.moment(for: d))
        #expect(moment.note == "a good day")

        try store.updateNote("   ", for: moment)
        #expect(moment.note == nil)
    }
}
