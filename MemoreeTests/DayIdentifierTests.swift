import Foundation
import Testing

@testable import Memoree

/// Phase 1 — day identity.
///
/// A day is a *user-experienced* local calendar day, never a UTC date. These
/// tests exist because getting this wrong silently corrupts streaks near
/// midnight, which is exactly the kind of bug nobody reports until they have
/// already lost a streak.
@Suite("Phase 1 — DayIdentifier")
struct DayIdentifierTests {

    @Test("Derives the local day from an instant")
    func derivesLocalDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let lateNight = cal.date(from: DateComponents(
            year: 2026, month: 9, day: 30, hour: 23, minute: 30
        ))!

        // 23:30 in Tokyo is 14:30 UTC the same day, but the point is that the
        // *user's* day is the 30th, regardless of what UTC thinks.
        #expect(DayIdentifier(date: lateNight, calendar: cal).rawValue == "2026-09-30")
    }

    @Test("One instant can be two different days in two timezones")
    func instantIsZoneRelative() {
        let instant = Date(timeIntervalSince1970: 1_790_000_000)

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!

        let inTokyo = DayIdentifier(date: instant, calendar: tokyo)
        let inAuckland = DayIdentifier(date: instant, calendar: auckland)

        // Whatever the values, each must be internally consistent: parsing the
        // raw value back in the same zone must reproduce the same day.
        #expect(DayIdentifier(string: inTokyo.rawValue, calendar: tokyo) == inTokyo)
        #expect(DayIdentifier(string: inAuckland.rawValue, calendar: auckland) == inAuckland)
    }

    @Test("Round-trips through its string form")
    func roundTrips() {
        let day = DayIdentifier(date: Date())
        let parsed = DayIdentifier(string: day.rawValue)
        #expect(parsed == day)
    }

    @Test("Rejects malformed and impossible dates")
    func rejectsBadInput() {
        #expect(DayIdentifier(string: "2026-02-31") == nil)   // February has no 31st
        #expect(DayIdentifier(string: "2026-13-01") == nil)   // month 13
        #expect(DayIdentifier(string: "not-a-date") == nil)
        #expect(DayIdentifier(string: "2026-1-1") == nil)     // must be zero-padded
        #expect(DayIdentifier(string: "") == nil)
        #expect(DayIdentifier(string: "2027-02-29") == nil)   // 2027 is not a leap year
    }

    @Test("Accepts a real leap day")
    func acceptsLeapDay() {
        #expect(DayIdentifier(string: "2028-02-29") != nil)
    }

    @Test("Offsets across month, year and leap boundaries")
    func offsets() {
        #expect(DayIdentifier(string: "2026-12-31")!.offset(by: 1).rawValue == "2027-01-01")
        #expect(DayIdentifier(string: "2026-01-01")!.offset(by: -1).rawValue == "2025-12-31")
        #expect(DayIdentifier(string: "2028-02-28")!.offset(by: 1).rawValue == "2028-02-29")
        #expect(DayIdentifier(string: "2028-02-28")!.offset(by: 2).rawValue == "2028-03-01")
        #expect(DayIdentifier(string: "2026-03-01")!.previous().rawValue == "2026-02-28")
    }

    @Test("Offsets across a DST transition keep the wall-clock day")
    func offsetsAcrossDST() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!

        let beforeDST = DayIdentifier(string: "2027-03-13", calendar: cal)!
        let afterDST = beforeDST.offset(by: 1, calendar: cal)

        #expect(afterDST.rawValue == "2027-03-14")
        // The local wall-clock day must be midnight-ish, not 23:00 the day before,
        // which is what a naive 86400-second offset produces across a spring-forward.
        let hour = cal.component(.hour, from: afterDST.date)
        #expect(hour == 0)
    }

    @Test("Days between two days")
    func dayDistance() {
        let cal = Calendar(identifier: .gregorian)
        let a = DayIdentifier(string: "2026-09-30", calendar: cal)!
        let b = DayIdentifier(string: "2026-10-02", calendar: cal)!
        #expect(a.days(until: b, calendar: cal) == 2)
        #expect(b.days(until: a, calendar: cal) == -2)
        #expect(a.days(until: a, calendar: cal) == 0)
    }

    @Test("Orders chronologically")
    func ordering() {
        #expect(DayIdentifier(string: "2026-01-01")! < DayIdentifier(string: "2026-01-02")!)
        #expect(DayIdentifier(string: "2025-12-31")! < DayIdentifier(string: "2026-01-01")!)
        #expect(DayIdentifier(string: "2026-01-01")! == DayIdentifier(string: "2026-01-01")!)
    }
}
