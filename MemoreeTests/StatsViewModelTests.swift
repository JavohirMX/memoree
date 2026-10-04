import Foundation
import Testing

@testable import Memoree

/// Phase 7 — the Stats screen's decisions.
///
/// The arithmetic is `StreakSummaryTests`. This file is about the choices, and
/// they are choices rather than derivations:
///
/// - **Which rows exist at all.** A row that always reads zero is a row of noise.
/// - **How a number is said.** `"83%"` is a grade. `"7 of 12"` is a count of
///   photographs, and it does not imply a threshold the user was measured
///   against.
/// - **What is never said.** No encouragement, no "keep it up", no reaction to
///   the number at all.
@Suite("Phase 7 — stats screen")
@MainActor
struct StatsViewModelTests {

    private let calendar = Calendar(identifier: .gregorian)

    private struct Harness {
        let environment: AppEnvironment
        let store: MomentStore
    }

    private func makeHarness(now: Date) throws -> Harness {
        let environment = try AppEnvironment(
            container: try Persistence.inMemoryContainer(),
            momentScheduler: TestSupport.Scheduler(start: now),
            notificationService: InMemoryNotificationService(),
            photoLibrary: InMemoryPhotoLibraryService(),
            captureService: InMemoryCaptureService()
        )
        return Harness(environment: environment, store: environment.momentStore)
    }

    /// Records one moment on `day`, `offset` days ago.
    @discardableResult
    private func record(
        _ harness: Harness,
        daysAgo offset: Int,
        onTime: Bool = true,
        retakes: Int = 0,
        hasBTS: Bool = false
    ) throws -> Moment {
        let today = DayIdentifier(date: Self.reference, calendar: calendar)
        let day = today.offset(by: -offset, calendar: calendar)
        let start = day.date.addingTimeInterval(12 * 3600)
        return try harness.store.record(
            day: day,
            interval: MomentInterval(start: start, end: start.addingTimeInterval(120)),
            capturedAt: onTime ? start.addingTimeInterval(60) : start.addingTimeInterval(3600),
            retakeCount: retakes,
            backAssetIdentifier: nil,
            frontAssetIdentifier: nil,
            hasBTS: hasBTS
        )
    }

    /// A fixed "now", so "days ago" means what it says.
    private static let reference: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 1
        components.hour = 20
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }()

    private func makeModel(_ harness: Harness) -> StatsViewModel {
        // Captured into a local rather than read as `Self.reference` inside the
        // closure: the clock is `@Sendable`, and a `@MainActor` static cannot be
        // read from one. The value is captured by copy, which is the point of a
        // constant.
        let now = Self.reference
        return StatsViewModel(environment: harness.environment, now: { now })
    }

    // MARK: - Nothing to show

    @Test("A fresh install has no statistics to report")
    func emptyOnFreshInstall() throws {
        let harness = try makeHarness(now: Self.reference)
        let model = makeModel(harness)
        model.load()

        #expect(model.isEmpty)
        // And the numbers are all zero rather than absent, so the screen can
        // branch on one flag instead of eight optionals.
        #expect(model.summary == .empty)
    }

    // MARK: - Phrasing

    @Test("Timing is a count of photographs, never a percentage")
    func timingIsACount() throws {
        // `"83%"` reads as a grade and implies a passing mark. `"7 of 12"` is
        // what the user actually did.
        let harness = try makeHarness(now: Self.reference)
        for offset in 1...7 { try record(harness, daysAgo: offset) }
        for offset in 8...12 { try record(harness, daysAgo: offset, onTime: false) }

        let model = makeModel(harness)
        model.load()

        #expect(model.onTimeDescription == "7 of 12 on time")
        #expect(!model.onTimeDescription.contains("%"))
    }

    @Test("Timing of everything, and of nothing, is still a sentence")
    func timingEdgeCases() throws {
        let harness = try makeHarness(now: Self.reference)
        let model = makeModel(harness)
        model.load()
        #expect(model.onTimeDescription == "0 of 0 on time",
                "not empty — the row is hidden by `isEmpty`, not by a blank string")

        try record(harness, daysAgo: 1, onTime: false)
        model.load()
        #expect(model.onTimeDescription == "0 of 1 on time")
    }

    @Test("Day counts are pluralised, and one is singular")
    func pluralisation() throws {
        let harness = try makeHarness(now: Self.reference)

        try record(harness, daysAgo: 1)
        let one = makeModel(harness)
        one.load()
        #expect(one.currentStreakDescription == "1 day")
        #expect(one.daysCapturedDescription == "1 day")

        try record(harness, daysAgo: 2)
        try record(harness, daysAgo: 3)
        let three = makeModel(harness)
        three.load()
        #expect(three.currentStreakDescription == "3 days")
        #expect(three.daysCapturedDescription == "3 days")
        #expect(three.longestStreakDescription == "3 days")
    }

    // MARK: - Rows that hide

    @Test("A retake average of zero is hidden rather than shown")
    func zeroRetakesAreHidden() throws {
        // `"0 retakes"` is the absence of the thing being counted. A user who
        // has never retaken anything is not being told they scored zero — and
        // the archive detail already made this call, so the two screens agree.
        let harness = try makeHarness(now: Self.reference)
        try record(harness, daysAgo: 1, retakes: 0)

        let model = makeModel(harness)
        model.load()
        #expect(model.retakeDescription == nil)
    }

    @Test("A retake average is shown once there is one, without false precision")
    func retakesAreShown() throws {
        let harness = try makeHarness(now: Self.reference)
        try record(harness, daysAgo: 1, retakes: 0)
        try record(harness, daysAgo: 2, retakes: 2)

        let model = makeModel(harness)
        model.load()
        // Exactly 1.0 — an integer mean, so it must not render as "1.0".
        #expect(model.retakeDescription == "1 on average")
    }

    @Test("A fractional retake average keeps one decimal")
    func fractionalRetakes() throws {
        let harness = try makeHarness(now: Self.reference)
        try record(harness, daysAgo: 1, retakes: 0)
        try record(harness, daysAgo: 2, retakes: 0)
        try record(harness, daysAgo: 3, retakes: 2)

        let model = makeModel(harness)
        model.load()
        // 2/3. Two decimals would be "0.67", which is a precision the underlying
        // integer counts cannot support.
        #expect(model.retakeDescription == "0.7 on average")
    }

    @Test("A clip count of zero is hidden, because BTS is off by default")
    func zeroClipsAreHidden() throws {
        // **The row existed in the plan from Phase 2 marked "omitted".** The reason
        // given was that BTS had no recorder, so the row would always read "0" —
        // which is still true for every user who has not turned it on, and is the
        // majority. A row reading zero describes a feature they are not using as
        // though they were using it badly. Hidden at zero, like retakes.
        let harness = try makeHarness(now: Self.reference)
        try record(harness, daysAgo: 1, hasBTS: false)

        let model = makeModel(harness)
        model.load()
        #expect(model.btsDescription == nil)
        #expect(model.summary.btsCount == 0, "the count is still zero; only the row is hidden")
    }

    @Test("A clip count is shown once there is one, and is a count not a percentage")
    func clipsAreShown() throws {
        let harness = try makeHarness(now: Self.reference)
        try record(harness, daysAgo: 1, hasBTS: true)
        try record(harness, daysAgo: 2, hasBTS: true)
        try record(harness, daysAgo: 3, hasBTS: false)

        let model = makeModel(harness)
        model.load()
        // **"2 clips", not "67%".** A percentage invites the reading that more is
        // better, and it is not: the photographs are the product and a clip is
        // context (ADR-013). Also singular/plural, because "1 clips" is the kind of
        // thing that survives a release.
        #expect(model.summary.btsCount == 2)
        #expect(model.btsDescription == "2 clips")
    }

    @Test("One clip reads in the singular")
    func oneClipIsSingular() throws {
        let harness = try makeHarness(now: Self.reference)
        try record(harness, daysAgo: 1, hasBTS: true)

        let model = makeModel(harness)
        model.load()
        #expect(model.btsDescription == "1 clip")
    }

    @Test("Busiest hour is absent with no history")
    func busiestHourAbsentWhenEmpty() throws {
        let harness = try makeHarness(now: Self.reference)
        let model = makeModel(harness)
        model.load()
        #expect(model.busiestHourDescription == nil)
    }

    @Test("Busiest hour uses the device's own time format")
    func busiestHourFollowsTheLocale() throws {
        // The first version hardcoded `"ha"` with a lowercase `pm` symbol, which
        // rendered "8pm" directly above a history list reading "11.38" — two time
        // formats on one screen, because the list was following the device
        // locale and the label was not.
        //
        // Asserted by *comparing against the same formatter the list uses* rather
        // than against a literal. A test that hardcodes "4pm" would fail on a
        // 24-hour device and pass on a 12-hour one, which is a test that only
        // ever runs in one place.
        let harness = try makeHarness(now: Self.reference)
        try record(harness, daysAgo: 1)
        try record(harness, daysAgo: 2)
        try record(harness, daysAgo: 3)

        let model = makeModel(harness)
        model.load()

        let hour = try #require(model.summary.busiestHour)
        let expected = Self.referenceDay
            .addingTimeInterval(Double(hour) * 3600)
            .formatted(date: .omitted, time: .shortened)
        #expect(model.busiestHourDescription == expected)
    }

    /// Local midnight on a fixed day — the same reference the view model uses.
    private static let referenceDay = Calendar.current.date(
        from: DateComponents(year: 2001, month: 1, day: 1, hour: 0)
    )!

    // MARK: - The missed-days label

    @Test("Days with nothing are labelled by what happened, not by a failure")
    func missedDaysLabel() throws {
        // `"2 missed"` reads as a reprimand and, worse, is *wrong* under
        // ADR-023: an off-window day is a day the user showed up. Only an empty
        // day breaks a streak, so only an empty day is counted here.
        let harness = try makeHarness(now: Self.reference)
        try record(harness, daysAgo: 4)
        try record(harness, daysAgo: 1)
        // Three and two have nothing at all.

        let model = makeModel(harness)
        model.load()
        #expect(model.summary.missedDays == 2)
        #expect(model.missedDescription == "2 with nothing")
        #expect(!model.missedDescription.lowercased().contains("miss"))
    }

    @Test("Days before the first moment are not days with nothing")
    func missedDaysStartAtTheFirstMoment() throws {
        // The first version of the test above recorded a single moment a day
        // ago and expected the two days *before* it to count as missed. They do
        // not, and they should not: you cannot have missed a day before you
        // started. `missedDays` measures the span from the first moment, which
        // is what makes the label true rather than merely pessimistic.
        //
        // Worth pinning because the alternative is defensible-looking and wrong
        // — a user who installed the app last week would open this screen to
        // "several days with nothing" on their first launch.
        let harness = try makeHarness(now: Self.reference)
        try record(harness, daysAgo: 1)

        let model = makeModel(harness)
        model.load()
        #expect(model.summary.missedDays == 0,
                "the day before the first moment is not a miss")
    }

    // MARK: - Ordering

    @Test("The history is newest first, agreeing with the archive")
    func historyIsNewestFirst() throws {
        // Obvious when it matches, maddening when it does not: two screens that
        // list the same photographs in different orders make the user work out
        // which one is "the first".
        let harness = try makeHarness(now: Self.reference)
        for offset in 1...5 { try record(harness, daysAgo: offset) }

        let model = makeModel(harness)
        model.load()

        let days = model.days.map(\.day)
        #expect(days == days.sorted(by: >))
        #expect(model.days.count == 5)
    }
}
