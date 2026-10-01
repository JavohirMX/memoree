import Foundation
import Testing

@testable import Memoree

/// Phase 1 — window validation and the capture interval.
///
/// Validation never traps and never returns a degenerate window: these values
/// come from user settings, and a corrupt store must degrade to defaults rather
/// than crash the app on launch.
@Suite("Phase 1 — TimeWindow")
struct TimeWindowTests {

    @Test("Defaults to BeReal's observed 11:00–23:00 delivery band")
    func defaultBand() {
        #expect(TimeWindow.default.startMinutes == 11 * 60)
        #expect(TimeWindow.default.endMinutes == 23 * 60)
        #expect(TimeWindow.default.spanSeconds == 12 * 3600)

        // **Asserted in two locales rather than as one literal.** This used to
        // require `"11:00 – 23:00"`, which is only true on a device set to
        // 24-hour time. `displayBounds` was `String(format: "%02d:%02d")`, so a
        // user in the United States set their window as "From 11:00 / Until
        // 23:00" while every other time in the app said "11:00 AM" — and this
        // test *enforced* the wrong behaviour rather than catching it.
        //
        // Pinning both an en_GB and an en_US rendering is what makes it a test
        // about locale-following: one literal proves nothing, because it happens
        // to be right on whichever machine runs it.
        let gb = TimeWindow.format(minutes: 11 * 60, locale: Locale(identifier: "en_GB"))
        let us = TimeWindow.format(minutes: 11 * 60, locale: Locale(identifier: "en_US"))
        #expect(gb == "11:00", "24-hour locale")
        #expect(us.contains("11") && us.uppercased().contains("AM"),
                "12-hour locale, got \(us)")

        // And the two must actually differ, which is the property being protected.
        // Without this the pair above passes even if `locale:` were ignored and
        // both rendered in whatever the machine running the tests is set to.
        #expect(gb != us, "the locale parameter has to do something")
    }

    @Test("End-of-day is 24:00 in every locale")
    func endOfDayIsNotAClockTime() {
        // The one value that is a boundary rather than an instant, and the one
        // genuinely easy to get wrong: rendering it as `00:00` would put the end
        // of the window before the start of it. It is composed by hand for that
        // reason, so it must not follow the locale — a user would otherwise see
        // "12:00 AM" for the end of their day and "12:00 AM" for its start.
        #expect(TimeWindow.format(minutes: 24 * 60, locale: Locale(identifier: "en_US")) == "24:00")
        #expect(TimeWindow.format(minutes: 24 * 60, locale: Locale(identifier: "en_GB")) == "24:00")
    }

    @Test("Times outside the window are clamped, not wrapped")
    func outOfRangeMinutesAreClamped() throws {
        #expect(TimeWindow.format(minutes: 25 * 60, locale: Locale(identifier: "en_GB")) == "24:00",
                "past midnight is still end-of-day")
        // **Nothing here is written as a literal time.** `en_US` puts a narrow no-break
        // space (U+202F) before the meridiem, not a plain space, so `"12:00 AM"`
        // in a test is not the string the device produces — the first version of
        // this assertion failed on exactly that, comparing against a space.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let realMidnight = try #require(
            calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: 0, minute: 0))
        )

        func deviceMidnight(in identifier: String) -> String {
            realMidnight.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened)
                    .locale(Locale(identifier: identifier))
            )
        }

        #expect(
            TimeWindow.format(minutes: -90, locale: Locale(identifier: "en_US"))
                == deviceMidnight(in: "en_US"),
            "before midnight is still midnight"
        )
        #expect(
            TimeWindow.format(minutes: 0, locale: Locale(identifier: "en_GB"))
                == deviceMidnight(in: "en_GB"),
            "and midnight stays midnight"
        )

        // **Midnight in en_GB is `0:00`, not `00:00`.** CLDR's h23 pattern there
        // is `H:mm`. It is the locale's correct rendering and exactly why this
        // function delegates instead of formatting — but it does mean the app can
        // show `0:00` and `24:00` side by side in one window on a British
        // device, which reads like a bug to anyone who has not thought about hour
        // cycles. Both are right. Asserted so the next person does not "fix" it.
        #expect(
            deviceMidnight(in: "en_GB") == "0:00",
            "en_GB midnight is un-padded; changing this is changing the locale"
        )

        // **The same comparison across five locales**, including ones whose
        // rendering is not a colon-separated pair at all. `ar_EG` uses Eastern
        // Arabic digits, so asserting `formatted == expected` is the only way to
        // write this that holds everywhere.
        for identifier in ["en_GB", "en_US", "ja_JP", "de_DE", "ar_EG"] {
            let locale = Locale(identifier: identifier)
            let formatted = TimeWindow.format(minutes: 0, locale: locale)
            #expect(
                formatted == deviceMidnight(in: identifier),
                "\(identifier) midnight: \(formatted) vs \(deviceMidnight(in: identifier))"
            )
        }
    }

    @Test("A well-formed window is preserved exactly")
    func preservesValid() {
        let window = TimeWindow(startMinutes: 8 * 60, endMinutes: 22 * 60)
        #expect(window.startMinutes == 8 * 60)
        #expect(window.endMinutes == 22 * 60)
    }

    @Test("Inverted windows are repaired rather than rejected")
    func repairsInverted() {
        let window = TimeWindow(startMinutes: 20 * 60, endMinutes: 9 * 60)
        #expect(window.isValid)
        #expect(window.endMinutes > window.startMinutes)
    }

    @Test("Zero-width windows become usable")
    func repairsZeroWidth() {
        let window = TimeWindow(startMinutes: 0, endMinutes: 0)
        #expect(window.isValid)
        #expect(window.spanSeconds >= TimeWindow.minimumSpanSeconds)
    }

    @Test("Windows too narrow for meaningful randomness are widened")
    func enforcesMinimumSpan() {
        // Same minute to same minute: zero span.
        let window = TimeWindow(startMinutes: 600, endMinutes: 600)
        #expect(window.isValid)
        #expect(window.spanSeconds >= TimeWindow.minimumSpanSeconds)
    }

    @Test("Out-of-range bounds are clamped into 0...1440")
    func clampsOutOfRange() {
        let low = TimeWindow(startMinutes: -500, endMinutes: 700)
        #expect(low.startMinutes >= 0)
        #expect(low.isValid)

        let high = TimeWindow(startMinutes: 700, endMinutes: 99_999)
        #expect(high.endMinutes <= 24 * 60)
        #expect(high.isValid)
    }

    @Test("Earliest and latest start land on the right day")
    func boundsOnDay() throws {
        let cal = Calendar(identifier: .gregorian)
        let day = try #require(DayIdentifier(string: "2026-09-30", calendar: cal))
        let window = TimeWindow(startMinutes: 11 * 60, endMinutes: 23 * 60)

        let earliest = window.earliestStart(on: day, calendar: cal)
        let latest = window.latestStart(on: day, calendar: cal)

        #expect(cal.component(.hour, from: earliest) == 11)
        #expect(cal.component(.minute, from: earliest) == 0)
        #expect(cal.component(.hour, from: latest) == 23)
        #expect(latest > earliest)
    }

    @Test("A window must leave room for the capture window to open")
    func latestStartLeavesRoom() throws {
        let cal = Calendar(identifier: .gregorian)
        let day = try #require(DayIdentifier(string: "2026-09-30", calendar: cal))
        let window = TimeWindow(startMinutes: 22 * 60, endMinutes: 23 * 60)

        // Without room, a 2-minute window could start at 23:00 and never close
        // within the day.
        let latest = window.latestStartAllowingWindow(of: 120, on: day, calendar: cal)
        #expect(latest <= window.latestStart(on: day, calendar: cal))
        #expect(latest >= window.earliestStart(on: day, calendar: cal))
    }

    @Test("Display bounds render both ends in the device's own format")
    func displayFormatting() {
        // **The separator and both bounds are now locale-derived, so the whole
        // string is asserted against the device.** The old literals
        // `"00:00 – 09:00"` and `"00:00 – 24:00"` were true only on a 24-hour
        // device with a European time format, and they were *enforcing* that.
        //
        // What is actually worth pinning here is the pair of properties this test
        // was written to protect, and neither of them is the exact string:
        //
        // - the **start is not `24:00`** even though the end is — a reversed
        //   window is the bug that matters;
        // - the **end is `24:00`** because it means end-of-day, not midnight.
        let early = TimeWindow(startMinutes: 0, endMinutes: 9 * 60)
        let wholeDay = TimeWindow(startMinutes: 0, endMinutes: 24 * 60)

        let earlyBounds = early.displayBounds.components(separatedBy: " – ")
        #expect(earlyBounds.count == 2, "got \(early.displayBounds)")
        #expect(earlyBounds[0] != "24:00", "the start is never end-of-day")

        let wholeDayBounds = wholeDay.displayBounds.components(separatedBy: " – ")
        #expect(wholeDayBounds.count == 2, "got \(wholeDay.displayBounds)")
        #expect(wholeDayBounds[1] == "24:00", "end-of-day is a boundary, not an instant")
    }
}

/// Phase 1 — the capture interval's boundary semantics.
///
/// Off-by-one here is the difference between "on time" and "late", so the edges
/// are pinned explicitly.
@Suite("Phase 1 — MomentInterval")
struct MomentIntervalTests {

    private let start = Date(timeIntervalSince1970: 1_000)

    /// A computed property, not `lazy`: `lazy` implies mutating access, which
    /// is why it cannot be read from a non-mutating test method.
    private var interval: MomentInterval {
        MomentInterval(start: start, end: start.addingTimeInterval(120))
    }

    @Test("Both edges are inclusive so a boundary capture counts as on time")
    func edgesAreInclusive() {
        #expect(interval.contains(start))
        #expect(interval.contains(start.addingTimeInterval(120)))
        #expect(!interval.contains(start.addingTimeInterval(121)))
        #expect(!interval.contains(start.addingTimeInterval(-1)))
    }

    @Test("Remaining counts down and floors at zero")
    func remaining() {
        #expect(interval.remaining(at: start.addingTimeInterval(10)) == 110)
        #expect(interval.remaining(at: start) == 120)
        #expect(interval.remaining(at: start.addingTimeInterval(500)) == 0)
    }

    @Test("Lateness is zero on time and grows afterwards")
    func lateness() {
        #expect(interval.lateness(at: start.addingTimeInterval(60)) == 0)
        #expect(interval.lateness(at: start.addingTimeInterval(120)) == 0)
        #expect(interval.lateness(at: start.addingTimeInterval(200)) == 80)
        #expect(interval.lateness(at: start.addingTimeInterval(-500)) == 0)
    }

    @Test("A two-minute interval reports 02:00 remaining at its start")
    func matchesCountdownFormatting() {
        #expect(CountdownFormatter.string(fromSeconds: interval.remaining(at: start)) == "02:00")
    }
}
