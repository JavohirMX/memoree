import Foundation
import Testing

@testable import Memoree

/// Pure selection for the "this day across years" flipbook (ADR-038).
@Suite("Same-day flipbook selection")
struct SameDayFlipbookTests {

    // MARK: - Fixtures

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func moment(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 12,
        zone: String = "UTC"
    ) -> MomentFacts {
        let cal = calendar(zone)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        let captured = cal.date(from: components)!
        return MomentFacts(
            id: UUID(),
            day: DayIdentifier(date: captured, calendar: cal),
            isOnTime: true,
            capturedAt: captured,
            windowEndsAt: captured.addingTimeInterval(120),
            retakeCount: 0,
            hasBTS: false
        )
    }

    // MARK: - Matching

    @Test("Matches the same month and day across every year, oldest first")
    func matchesAcrossYearsIncludingCurrent() {
        let cal = calendar()
        let facts = [
            moment(year: 2026, month: 10, day: 8, hour: 16),
            moment(year: 2024, month: 10, day: 8, hour: 14),
            moment(year: 2025, month: 10, day: 9, hour: 12),
            moment(year: 2025, month: 10, day: 8, hour: 15),
        ]
        let query = moment(year: 2026, month: 10, day: 8).capturedAt

        let selected = SameDayFlipbook.moments(from: facts, matching: query, calendar: cal)

        #expect(selected.map(\.day.rawValue) == [
            "2024-10-08",
            "2025-10-08",
            "2026-10-08",
        ])
    }

    @Test("Empty input yields an empty selection")
    func emptyInput() {
        let cal = calendar()
        let query = moment(year: 2026, month: 10, day: 8).capturedAt
        #expect(SameDayFlipbook.moments(from: [], matching: query, calendar: cal).isEmpty)
    }

    @Test("Leap day matches only February 29")
    func leapDayExactMatch() {
        let cal = calendar()
        let facts = [
            moment(year: 2024, month: 2, day: 29),
            moment(year: 2020, month: 2, day: 29),
            moment(year: 2023, month: 2, day: 28),
            moment(year: 2024, month: 2, day: 28),
        ]
        let query = moment(year: 2024, month: 2, day: 29).capturedAt

        let selected = SameDayFlipbook.moments(from: facts, matching: query, calendar: cal)

        #expect(selected.map(\.day.rawValue) == ["2020-02-29", "2024-02-29"])
    }

    @Test("Timezone: local calendar day, not UTC instant")
    func usesLocalCalendarDay() {
        // 2026-10-08 01:00 in Auckland is still 2026-10-07 in UTC.
        let auckland = calendar("Pacific/Auckland")
        let facts = [
            moment(year: 2025, month: 10, day: 8, hour: 1, zone: "Pacific/Auckland"),
            moment(year: 2026, month: 10, day: 8, hour: 1, zone: "Pacific/Auckland"),
            moment(year: 2026, month: 10, day: 7, hour: 23, zone: "Pacific/Auckland"),
        ]
        let query = moment(year: 2026, month: 10, day: 8, hour: 12, zone: "Pacific/Auckland").capturedAt

        let selected = SameDayFlipbook.moments(from: facts, matching: query, calendar: auckland)

        #expect(selected.map(\.day.rawValue) == ["2025-10-08", "2026-10-08"])
    }

    // MARK: - Export gate

    @Test("Exportable when two or more distinct years match")
    func exportableAcrossYears() {
        let cal = calendar()
        let moments = [
            moment(year: 2024, month: 10, day: 8),
            moment(year: 2026, month: 10, day: 8),
        ]
        #expect(SameDayFlipbook.isExportable(moments, calendar: cal))
    }

    @Test("Not exportable with a single year, even with multiple captures")
    func notExportableSameYearMultiCapture() {
        let cal = calendar()
        let moments = [
            moment(year: 2026, month: 10, day: 8, hour: 10),
            moment(year: 2026, month: 10, day: 8, hour: 18),
        ]
        #expect(!SameDayFlipbook.isExportable(moments, calendar: cal))
    }

    @Test("Not exportable with fewer than two moments")
    func notExportableSingleMoment() {
        let cal = calendar()
        #expect(!SameDayFlipbook.isExportable([moment(year: 2026, month: 10, day: 8)], calendar: cal))
        #expect(!SameDayFlipbook.isExportable([], calendar: cal))
    }

    @Test("Multi-capture days still export when years span")
    func multiCaptureStillExportableAcrossYears() {
        let cal = calendar()
        let moments = [
            moment(year: 2025, month: 10, day: 8, hour: 10),
            moment(year: 2025, month: 10, day: 8, hour: 18),
            moment(year: 2026, month: 10, day: 8, hour: 12),
        ]
        #expect(SameDayFlipbook.isExportable(moments, calendar: cal))
        #expect(SameDayFlipbook.moments(from: moments, matching: moments[2].capturedAt, calendar: cal).count == 3)
    }
}
