import Foundation
import Testing

@testable import Memoree

/// The archive's month grouping.
///
/// Table-driven and adversarial, because the failure modes here are all
/// invisible: a duplicate header, a section in the wrong order, a moment filed
/// under the month before the one it belongs to. None of them throw, none of
/// them crash, and a screenshot of a grid with 500 photographs in it cannot tell
/// you whether the header says the right month.
@Suite("Phase 6 — archive month grouping")
struct ArchiveSectionTests {

    // MARK: - Fixtures

    /// A calendar in a named zone, so a boundary is a fact about the test rather
    /// than about wherever it happens to be running.
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func moment(
        _ iso: String,
        zone: String = "UTC"
    ) -> MomentFacts {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: zone)
        let captured = formatter.date(from: iso)!
        return MomentFacts(
            id: UUID(),
            day: DayIdentifier(date: captured, calendar: calendar(zone)),
            isOnTime: true,
            capturedAt: captured,
            windowEndsAt: captured.addingTimeInterval(120),
            retakeCount: 0,
            hasBTS: false
        )
    }

    // MARK: - The ordinary cases

    @Test("An empty archive has no sections")
    func emptyArchive() {
        #expect(ArchiveSection.grouping([]).isEmpty)
    }

    @Test("Moments in one month make one section")
    func singleMonth() {
        let sections = ArchiveSection.grouping([
            moment("2026-09-30T10:00:00Z"),
            moment("2026-09-01T09:00:00Z"),
            moment("2026-09-15T14:30:00Z")
        ])

        #expect(sections.count == 1)
        #expect(sections.first?.key == MonthKey(year: 2026, month: 9))
    }

    @Test("Moments are newest first within a section")
    func newestFirstWithinAMonth() {
        let sections = ArchiveSection.grouping([
            moment("2026-09-01T09:00:00Z"),
            moment("2026-09-20T11:00:00Z"),
            moment("2026-09-10T13:00:00Z")
        ])

        let times = (sections.first?.moments ?? []).map(\.capturedAt)
        #expect(times == times.sorted(by: >), "got \(times)")
    }

    @Test("Months come newest first, and every moment is kept exactly once")
    func monthsNewestFirstNothingLost() throws {
        let input = [
            moment("2026-07-04T12:00:00Z"),
            moment("2026-09-30T12:00:00Z"),
            moment("2026-08-15T12:00:00Z"),
            moment("2026-09-01T12:00:00Z"),
            moment("2025-12-25T12:00:00Z")
        ]

        let sections = ArchiveSection.grouping(input)

        #expect(sections.map(\.key) == [
            MonthKey(year: 2026, month: 9),
            MonthKey(year: 2026, month: 8),
            MonthKey(year: 2026, month: 7),
            MonthKey(year: 2025, month: 12)
        ])

        // **The invariant that matters.** Grouping is the one place where a
        // moment can go missing without anything failing, and a photograph the
        // user took silently absent from their own archive is the worst bug this
        // app could have.
        let kept = sections.flatMap(\.moments)
        #expect(kept.count == input.count, "\(kept.count) of \(input.count) survived")
        #expect(Set(kept.map(\.id)) == Set(input.map(\.id)), "no moment in the wrong section")
    }

    @Test("Interleaved input still produces one section per month")
    func interleavedInputDoesNotDuplicateHeaders() {
        // The case a dictionary-shaped implementation gets wrong: September,
        // October, September. Two "September 2026" headers is a screen that
        // claims the user has two of a month they have one of.
        let sections = ArchiveSection.grouping([
            moment("2026-09-10T12:00:00Z"),
            moment("2026-10-05T12:00:00Z"),
            moment("2026-09-20T12:00:00Z"),
            moment("2026-10-25T12:00:00Z")
        ])

        #expect(sections.map(\.key) == [
            MonthKey(year: 2026, month: 10),
            MonthKey(year: 2026, month: 9)
        ])
        #expect(sections.map(\.moments.count) == [2, 2])
        #expect(Set(sections.map(\.key)).count == sections.count, "no key appears twice")
    }

    // MARK: - The boundaries, which is where this actually goes wrong

    @Test("A moment is grouped by the user's month, not UTC's")
    func groupsByTheLocalMonth() {
        // **The bug this whole type exists to prevent.** A moment captured at
        // 01:00 on 1 September in Auckland is 13:00 on 31 August in UTC. Group by
        // UTC and it lands under August, on the screen whose only job is telling
        // the user when a photograph was taken.
        //
        // `Pacific/Auckland` is **UTC+12** in August — NZDT does not start until
        // 27 September — so the crossing instant is 13:00 UTC, not something
        // earlier. The first version of this test used 11:30 UTC, which is 23:30
        // on 31 August locally, and therefore correctly August. It asserted
        // September and failed, and it is worth recording that the fixture was
        // wrong and not the code: a test that pins a timezone has to pin the
        // offset too, because "Auckland in August" and "Auckland in January"
        // are two different timezones.
        let sections = ArchiveSection.grouping(
            [moment("2026-08-31T13:00:00Z")],
            calendar: calendar("Pacific/Auckland")
        )

        #expect(sections.first?.key == MonthKey(year: 2026, month: 9),
                "01:00 on 1 September in Auckland is 13:00 on 31 August in UTC")
    }

    @Test("A timezone behind UTC does not steal the previous month either")
    func groupsByTheLocalMonthGoingWest() {
        // The mirror image: 01:30 on 1 September in Los Angeles is 08:30 UTC on
        // the same day, and 23:30 on 31 August is 06:30 UTC on 1 September. UTC
        // would file that one under September when it is locally August.
        let sections = ArchiveSection.grouping(
            [moment("2026-09-01T06:30:00Z")],
            calendar: calendar("America/Los_Angeles")
        )

        #expect(sections.first?.key == MonthKey(year: 2026, month: 8))
    }

    @Test("A DST transition inside a month does not split it")
    func daylightSavingDoesNotSplitAMonth() {
        // Europe/London springs forward on 29 March 2026, at 01:00. A month
        // boundary resolved by adding or subtracting fixed offsets drifts by an
        // hour across that, and at the end of a month that is a moment in the
        // wrong section. Grouping by `dateComponents` is immune because the
        // calendar resolves the zone itself.
        let london = calendar("Europe/London")
        let sections = ArchiveSection.grouping(
            [
                moment("2026-03-28T12:00:00Z"),
                moment("2026-03-29T12:00:00Z"),
                moment("2026-03-30T12:00:00Z"),
                moment("2026-03-31T12:00:00Z")
            ],
            calendar: london
        )

        #expect(sections.count == 1, "DST inside the month split it: \(sections.map(\.key))")
        #expect(sections.first?.moments.count == 4)
    }

    @Test("The first and last minute of a month land in that month")
    func monthEdges() {
        let edges = ArchiveSection.grouping(
            [
                moment("2026-09-30T23:59:59Z"),
                moment("2026-10-01T00:00:00Z"),
                moment("2026-10-31T23:59:59Z"),
                moment("2026-11-01T00:00:00Z")
            ],
            calendar: calendar("UTC")
        )

        #expect(edges.map(\.key) == [
            MonthKey(year: 2026, month: 11),
            MonthKey(year: 2026, month: 10),
            MonthKey(year: 2026, month: 9)
        ])
    }

    @Test("A year boundary is a month boundary too")
    func yearBoundary() {
        let sections = ArchiveSection.grouping(
            [moment("2026-12-31T23:00:00Z"), moment("2027-01-01T01:00:00Z")],
            calendar: calendar("UTC")
        )

        #expect(sections.map(\.key) == [
            MonthKey(year: 2027, month: 1),
            MonthKey(year: 2026, month: 12)
        ])
    }

    // MARK: - The key itself

    @Test("Month keys sort newest first")
    func keysSortDescending() {
        let keys = [
            MonthKey(year: 2026, month: 9),
            MonthKey(year: 2026, month: 11),
            MonthKey(year: 2025, month: 12),
            MonthKey(year: 2026, month: 10)
        ]

        #expect(keys.sorted() == [
            MonthKey(year: 2026, month: 11),
            MonthKey(year: 2026, month: 10),
            MonthKey(year: 2026, month: 9),
            MonthKey(year: 2025, month: 12)
        ])
    }

    @Test("A section's title is in the user's own words")
    func titlesAreLocalised() {
        let section = ArchiveSection(key: MonthKey(year: 2026, month: 9), moments: [])
        let title = section.title

        // **Not a literal.** `DateFormatter` with `"MMMM yyyy"` says "September"
        // in every locale it is asked about, and the section header is the
        // archive's main piece of text after the photographs.
        let expected = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 1))!
            .formatted(.dateTime.month(.wide).year())
        #expect(title == expected)
        #expect(!title.isEmpty)
    }

    @Test("A section always has a title, even without a resolvable date")
    func titleFallsBackRatherThanBeingEmpty() {
        // Year 0 is not a year any calendar will render a month name for, and a
        // header that says nothing is worse than a header that says "0000-01" —
        // the photograph is still under it either way.
        let section = ArchiveSection(key: MonthKey(year: 0, month: 1), moments: [])
        #expect(!section.title.isEmpty)
    }
}
