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
        #expect(TimeWindow.default.displayBounds == "11:00 – 23:00")
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

    @Test("Display bounds format midnight and end-of-day readably")
    func displayFormatting() {
        #expect(TimeWindow(startMinutes: 0, endMinutes: 9 * 60).displayBounds == "00:00 – 09:00")
        #expect(TimeWindow(startMinutes: 0, endMinutes: 24 * 60).displayBounds == "00:00 – 24:00")
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
