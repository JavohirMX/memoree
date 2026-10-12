import Foundation
import Testing
@testable import Memoree

@Suite("WidgetSnapshotBuilder")
struct WidgetSnapshotBuilderTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func day(_ raw: String) -> DayIdentifier {
        DayIdentifier(string: raw, calendar: calendar)!
    }

    private func fact(
        day: DayIdentifier,
        capturedAt: Date,
        id: UUID = UUID()
    ) -> MomentFacts {
        MomentFacts(
            id: id,
            day: day,
            isOnTime: true,
            capturedAt: capturedAt,
            windowEndsAt: capturedAt.addingTimeInterval(120),
            retakeCount: 0,
            hasBTS: false
        )
    }

    @Test("empty archive yields zero streak and empty week")
    func emptyArchive() {
        let today = day("2026-10-12")
        let snapshot = WidgetSnapshotBuilder.make(
            facts: [],
            today: today,
            calendar: calendar,
            now: today.date
        )
        #expect(snapshot.dayIdentifier == "2026-10-12")
        #expect(snapshot.capturedToday == false)
        #expect(snapshot.currentStreak == 0)
        #expect(snapshot.lastSevenDays == Array(repeating: false, count: 7))
    }

    @Test("captured today fills the last week dot and grows the streak")
    func capturedToday() {
        let today = day("2026-10-12")
        let yesterday = day("2026-10-11")
        let facts = [
            fact(day: yesterday, capturedAt: yesterday.date.addingTimeInterval(36_000)),
            fact(day: today, capturedAt: today.date.addingTimeInterval(36_000))
        ]
        let snapshot = WidgetSnapshotBuilder.make(
            facts: facts,
            today: today,
            calendar: calendar,
            now: today.date
        )
        #expect(snapshot.capturedToday == true)
        #expect(snapshot.currentStreak == 2)
        #expect(snapshot.lastSevenDays.count == 7)
        #expect(snapshot.lastSevenDays[5] == true) // yesterday
        #expect(snapshot.lastSevenDays[6] == true) // today
        #expect(snapshot.lastSevenDays[0] == false)
    }

    @Test("multi-moment day still counts once in the week strip")
    func multiMomentDay() {
        let today = day("2026-10-12")
        let facts = [
            fact(day: today, capturedAt: today.date.addingTimeInterval(10_000)),
            fact(day: today, capturedAt: today.date.addingTimeInterval(20_000))
        ]
        let snapshot = WidgetSnapshotBuilder.make(
            facts: facts,
            today: today,
            calendar: calendar,
            now: today.date
        )
        #expect(snapshot.capturedToday == true)
        #expect(snapshot.currentStreak == 1)
        #expect(snapshot.lastSevenDays[6] == true)
    }

    @Test("stale day resolves as not captured while keeping streak")
    func staleDayResolution() {
        let snapshot = WidgetSnapshot(
            dayIdentifier: "2026-10-11",
            capturedToday: true,
            currentStreak: 9,
            lastSevenDays: Array(repeating: true, count: 7),
            updatedAt: Date()
        )
        let resolved = snapshot.resolved(forToday: "2026-10-12")
        #expect(resolved.capturedToday == false)
        #expect(resolved.currentStreak == 9)
        #expect(resolved.dayIdentifier == "2026-10-12")
    }

    @Test("unposted today does not break streak display (ADR-010)")
    func unpostedTodayKeepsStreak() {
        let today = day("2026-10-12")
        let yesterday = day("2026-10-11")
        let facts = [
            fact(day: yesterday, capturedAt: yesterday.date.addingTimeInterval(36_000))
        ]
        let snapshot = WidgetSnapshotBuilder.make(
            facts: facts,
            today: today,
            calendar: calendar,
            now: today.date
        )
        #expect(snapshot.capturedToday == false)
        #expect(snapshot.currentStreak == 1)
        #expect(snapshot.lastSevenDays[6] == false)
        #expect(snapshot.lastSevenDays[5] == true)
    }
}
