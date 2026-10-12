import Foundation
import Testing
@testable import Memoree

@Suite("Feed day grouping")
struct FeedDayGroupTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test("Empty input yields no groups")
    func emptyInput() {
        #expect(FeedDayGroup.grouping([]).isEmpty)
    }

    @Test("Same day collapses into one group preserving order")
    func sameDayOneGroup() {
        let day = DayIdentifier(
            date: date(year: 2026, month: 10, day: 12, hour: 12),
            calendar: calendar
        )
        let newer = facts(id: UUID(), day: day, hour: 18, minute: 0)
        let older = facts(id: UUID(), day: day, hour: 10, minute: 0)
        let groups = FeedDayGroup.grouping([newer, older])
        #expect(groups.count == 1)
        #expect(groups[0].day == day)
        #expect(groups[0].moments.map(\.id) == [newer.id, older.id])
    }

    @Test("Different days keep newest-first group order")
    func differentDaysPreserveOrder() {
        let today = DayIdentifier(
            date: date(year: 2026, month: 10, day: 12, hour: 12),
            calendar: calendar
        )
        let yesterday = DayIdentifier(
            date: date(year: 2026, month: 10, day: 11, hour: 12),
            calendar: calendar
        )
        let a = facts(id: UUID(), day: today, hour: 15, minute: 0)
        let b = facts(id: UUID(), day: yesterday, hour: 15, minute: 0)
        let groups = FeedDayGroup.grouping([a, b])
        #expect(groups.map(\.day) == [today, yesterday])
        #expect(groups[0].moments.map(\.id) == [a.id])
        #expect(groups[1].moments.map(\.id) == [b.id])
    }

    @Test("Title is Today / Yesterday / dated relative to now")
    func titlesRelativeToNow() {
        let now = date(year: 2026, month: 10, day: 12, hour: 16)
        let today = FeedDayGroup(
            day: DayIdentifier(date: now, calendar: calendar),
            moments: []
        )
        let yesterday = FeedDayGroup(
            day: DayIdentifier(
                date: date(year: 2026, month: 10, day: 11, hour: 12),
                calendar: calendar
            ),
            moments: []
        )
        let earlier = FeedDayGroup(
            day: DayIdentifier(
                date: date(year: 2026, month: 10, day: 5, hour: 12),
                calendar: calendar
            ),
            moments: []
        )
        #expect(today.title(now: now, calendar: calendar) == "Today")
        #expect(yesterday.title(now: now, calendar: calendar) == "Yesterday")
        #expect(earlier.title(now: now, calendar: calendar).contains("5"))
        #expect(earlier.title(now: now, calendar: calendar).contains("2026"))
    }

    // MARK: - Fixtures

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    private func facts(id: UUID, day: DayIdentifier, hour: Int, minute: Int) -> MomentFacts {
        let captured = calendar.date(
            bySettingHour: hour, minute: minute, second: 0, of: day.date
        ) ?? day.date
        return MomentFacts(
            id: id,
            day: day,
            isOnTime: true,
            capturedAt: captured,
            windowEndsAt: captured.addingTimeInterval(120),
            retakeCount: 0,
            hasBTS: false
        )
    }
}
