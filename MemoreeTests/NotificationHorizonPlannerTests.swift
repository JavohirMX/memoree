import Foundation
import Testing

@testable import Memoree

/// Phase 1 — the notification horizon invariant, finally written.
///
/// Phase 1 listed "Refill invariant test | Simulate 0, 19, 20 and 64 pending;
/// assert the horizon restores to 45" and it was never implemented. Not skipped
/// as unimportant: **unimplementable against the code as it was shaped.** The
/// decision was interleaved with `UNUserNotificationCenter` calls, and the
/// system centre cannot be subclassed into a test double, so there was nowhere
/// to observe it. That stayed true for five phases, through two refactors, and
/// the gap was only closed once the arithmetic came out into
/// `NotificationHorizonPlanner`.
///
/// The 64 case is the one that matters. It is iOS's hard cap on pending local
/// requests per app; above it, adds are dropped silently and the user simply
/// stops being reminded, with nothing thrown and nothing logged.
@Suite("Phase 1 — notification horizon")
struct NotificationHorizonPlannerTests {

    /// Built through the validating initialiser rather than
    /// `init(rawValue:)`, which is private precisely so `rawValue` and `date`
    /// can never disagree. A test that could construct an arbitrary identifier
    /// would be testing a type the app cannot actually hold.
    private let today: DayIdentifier

    private let horizon = 45
    private let threshold = 20

    init() throws {
        self.today = try #require(DayIdentifier(string: "2026-09-30"))
    }

    /// Every day fires at 14:00, so a failure points at the horizon arithmetic
    /// rather than at the scheduler.
    private func start(of day: DayIdentifier) -> Date {
        day.date.addingTimeInterval(14 * 3600)
    }

    private func plan(existing: [String], horizon: Int? = nil) -> NotificationHorizonPlanner.Plan {
        NotificationHorizonPlanner.plan(
            horizon: horizon ?? self.horizon,
            today: today,
            existing: existing,
            momentStart: start(of:)
        )
    }

    /// `moment.<dayIdentifier>` for `count` days from today.
    private func identifiers(_ count: Int) -> [String] {
        (0..<count).map { offset in
            NotificationHorizonPlanner.identifier(for: today.offset(by: offset))
        }
    }

    // MARK: - The boundary cases Phase 1 asked for

    @Test("An empty horizon is filled to the full length")
    func refillsFromEmpty() {
        let result = plan(existing: [])

        #expect(result.daysToSchedule.count == 45)
        #expect(result.fireDates.count == 45)
        #expect(result.daysToSchedule.first == today)
        #expect(result.daysToSchedule.last == today.offset(by: 44))
        #expect(!result.isEmpty)
    }

    @Test("Below the threshold the horizon is topped all the way back up")
    func refillsBelowThreshold() {
        // 19 pending: one short of the threshold, so a refill must restore the
        // full 45 rather than just crossing the line.
        let result = plan(existing: identifiers(19))

        #expect(NotificationHorizonPlanner.shouldRefill(
            pendingCount: 19, horizon: horizon, threshold: threshold
        ))
        #expect(result.daysToSchedule.count == 26, "45 total, 19 already there")
        #expect(result.daysToSchedule.first == today.offset(by: 19))
    }

    @Test("At the threshold the app does not act at all")
    func noChurnAtThreshold() {
        // Two decisions, not one. `shouldRefill` decides *whether* to run;
        // `plan` decides *what* to schedule once it is running. The threshold
        // lives in the first, so an app sitting on exactly 20 never reaches
        // the second and therefore never churns its horizon on every
        // foreground.
        #expect(!NotificationHorizonPlanner.shouldRefill(
            pendingCount: threshold, horizon: horizon, threshold: threshold
        ))

        // And the plan, given that it *was* run, restores the full horizon —
        // because "top up" means top up, not "nudge over the line". An earlier
        // version of this test asserted the plan was empty here, which is only
        // true if the plan knows about the threshold; it deliberately does not,
        // because a partial refill would leave the user with a shorter horizon
        // than they think they have.
        let result = plan(existing: identifiers(20))
        #expect(result.daysToSchedule.count == 25)
    }

    @Test("A full horizon is left completely alone")
    func fullHorizonIsUntouched() {
        let result = plan(existing: identifiers(45))

        #expect(result.isEmpty)
        #expect(result.daysToSchedule.isEmpty)
        // And specifically: no removals. Re-adding what is already there would
        // make the user miss a reminder they were about to get.
        #expect(result.identifiersToRemove.isEmpty)
    }

    @Test("At iOS's 64-request cap the planner adds nothing")
    func atTheSystemCap() {
        // 64 is the hard limit. Memoree's horizon is 45, so this is a user who
        // has accumulated extra requests from somewhere; the planner must not
        // try to add a 65th, because iOS drops it silently.
        #expect(!NotificationHorizonPlanner.shouldRefill(
            pendingCount: 64, horizon: horizon, threshold: threshold
        ))

        let result = plan(existing: identifiers(64))
        #expect(result.daysToSchedule.isEmpty, "no add can succeed past the cap")
    }

    // MARK: - The horizon never exceeds what the system will hold

    @Test("The horizon stays under the system's cap with room to spare")
    func horizonFitsUnderTheCap() {
        #expect(UserNotificationService.horizonDays < UserNotificationService.systemPendingLimit)
        // And the threshold leaves a genuine buffer rather than sitting just
        // under the horizon, which is the point of having two numbers.
        #expect(UserNotificationService.refillThreshold < UserNotificationService.horizonDays)
    }

    // MARK: - Never a wildcard removal

    @Test("No plan ever contains an empty identifier")
    func neverRemovesAWildcard() {
        // `removePendingNotificationRequests(withIdentifiers: [""])` clears
        // every pending request in the process, not just Memoree's. An empty
        // identifier slipping into that array is `removeAllPendingNotificationRequests`
        // with the documentation removed (AGENTS.md §9).
        let cases: [[String]] = [
            [],
            identifiers(1),
            identifiers(19),
            identifiers(45),
            identifiers(64),
            ["", "moment.2026-09-30"],
            [""],
        ]
        for existing in cases {
            let result = plan(existing: existing)
            #expect(
                !result.identifiersToRemove.contains(""),
                "an empty identifier in \(existing)"
            )
            #expect(
                result.identifiersToRemove.allSatisfy { !$0.isEmpty },
                "an empty identifier in \(existing)"
            )
        }
    }

    @Test("Only identifiers this app owns are ever removed")
    func onlyRemovesItsOwn() {
        // A notification the user scheduled elsewhere, or one belonging to
        // another subsystem, must survive a horizon refresh untouched.
        let foreign = ["someone-elses-request", "com.apple.system.something"]
        let result = plan(existing: foreign + identifiers(3))

        #expect(result.identifiersToRemove.allSatisfy { $0.hasPrefix("moment.") })
        #expect(!result.identifiersToRemove.contains { foreign.contains($0) })
    }

    // MARK: - Idempotence

    @Test("A day already pending is never scheduled twice")
    func noDuplicates() {
        // Re-adding a request whose identifier already exists throws, so a
        // duplicate here is not a warning — it is a failure on launch.
        let result = plan(existing: identifiers(45))

        #expect(result.daysToSchedule.isEmpty)
        #expect(
            Set(result.daysToSchedule).count == result.daysToSchedule.count,
            "no day appears twice in one plan"
        )
    }

    @Test("A partially expired horizon fills only the gap")
    func partialHorizon() {
        // Days 0–9 are gone (already fired, or dropped); the rest are pending.
        // A refill must schedule exactly the missing ten and leave the
        // remaining thirty-five alone.
        let remaining = identifiers(45).dropFirst(10)
        let result = plan(existing: Array(remaining))

        #expect(result.daysToSchedule.count == 10)
        #expect(result.daysToSchedule.first == today)
        #expect(result.daysToSchedule.last == today.offset(by: 9))
        #expect(result.identifiersToRemove.count == 10)
    }

    // MARK: - Fire dates

    @Test("Every scheduled day gets the time the scheduler resolved for it")
    func fireDatesComeFromTheScheduler() {
        let result = plan(existing: [])
        #expect(result.fireDates.count == result.daysToSchedule.count)

        for day in result.daysToSchedule {
            #expect(result.fireDates[day] == start(of: day), "\(day) fires at the wrong time")
        }
    }

    @Test("The identifier format is stable and greppable")
    func identifierFormat() {
        #expect(NotificationHorizonPlanner.identifier(for: today) == "moment.2026-09-30")
        // Relaunching must not re-issue, so the format is part of the contract
        // with anything already pending on the device.
        #expect(NotificationHorizonPlanner.identifier(for: today) != "")
    }

    // MARK: - The refill decision

    @Test("The refill decision is monotonic in the pending count")
    func refillDecision() {
        // Below the threshold: refill. At or above: do not. No window where it
        // is true above the threshold.
        for count in 0..<threshold {
            #expect(NotificationHorizonPlanner.shouldRefill(
                pendingCount: count, horizon: horizon, threshold: threshold
            ), "\(count) should refill")
        }
        for count in threshold...UserNotificationService.systemPendingLimit {
            #expect(!NotificationHorizonPlanner.shouldRefill(
                pendingCount: count, horizon: horizon, threshold: threshold
            ), "\(count) should not refill")
        }
    }

    @Test("The two decisions together never produce a short horizon")
    func horizonIsNeverLeftShort() {
        // The property that actually matters: whatever the pending count, a
        // refill either does not run or leaves the horizon full. There is no
        // state where the app decides to act and then tops up by two days.
        for count in 0...UserNotificationService.systemPendingLimit {
            let shouldRun = NotificationHorizonPlanner.shouldRefill(
                pendingCount: count, horizon: horizon, threshold: threshold
            )
            guard shouldRun else { continue }
            let result = plan(existing: identifiers(count))
            let after = count + result.daysToSchedule.count
            #expect(after == horizon, "\(count) pending ended up with \(after)")
        }
    }

    // MARK: - Streak-saver reminders

    @Test("Streak savers are scheduled for upcoming days at 21:00")
    func streakSaversScheduled() {
        let plan = NotificationHorizonPlanner.plan(
            horizon: 45,
            streakHorizon: 7,
            today: today,
            now: today.date, // midnight start of day
            existing: [],
            momentStart: start(of:)
        )

        #expect(plan.streakDaysToSchedule.count == 7)
        #expect(plan.streakFireDates.count == 7)

        for day in plan.streakDaysToSchedule {
            let fireDate = plan.streakFireDates[day]
            let expected = NotificationHorizonPlanner.streakFireDate(for: day)
            #expect(fireDate == expected)
            let hour = Calendar.current.component(.hour, from: try! #require(fireDate))
            #expect(hour == 21)
        }
    }

    @Test("Captured days are excluded from streak saver scheduling and pruned from pending")
    func streakSaversExcludedForCapturedDays() {
        let existingStreakId = NotificationHorizonPlanner.streakIdentifier(for: today)
        let plan = NotificationHorizonPlanner.plan(
            horizon: 45,
            streakHorizon: 7,
            today: today,
            now: today.date,
            existing: [existingStreakId],
            capturedDays: [today],
            momentStart: start(of:)
        )

        #expect(!plan.streakDaysToSchedule.contains(today))
        #expect(plan.identifiersToRemove.contains(existingStreakId))
    }

    @Test("Total scheduled requests (moments + streak savers) stays well under the 64 cap")
    func combinedRequestsUnderCap() {
        let plan = NotificationHorizonPlanner.plan(
            horizon: 45,
            streakHorizon: 7,
            today: today,
            now: today.date,
            existing: [],
            momentStart: start(of:)
        )

        let totalNew = plan.daysToSchedule.count + plan.streakDaysToSchedule.count
        #expect(totalNew == 52)
        #expect(totalNew < UserNotificationService.systemPendingLimit)
    }

    @Test("Streak saver for today is skipped if current time is past 21:00")
    func streakSaverPastTodaySkipped() {
        let pastNinePM = today.date.addingTimeInterval(22 * 3600) // 22:00
        let plan = NotificationHorizonPlanner.plan(
            horizon: 45,
            streakHorizon: 7,
            today: today,
            now: pastNinePM,
            existing: [],
            momentStart: start(of:)
        )

        #expect(!plan.streakDaysToSchedule.contains(today))
        #expect(plan.streakDaysToSchedule.count == 6)
    }
}
