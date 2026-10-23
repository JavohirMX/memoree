import Foundation
import Testing

@testable import Memoree

/// Which moment the detail screen shows — the tapped one, not today's latest.
///
/// The detail view used to fall back to `moments[0]` when the selected id was
/// missing from the pager list. In a newest-first archive that entry is today's
/// latest capture. These cases pin the resolve rule so that regression cannot
/// return silently.
@Suite("MomentDetailSelection")
struct MomentDetailSelectionTests {

    private let calendar = Calendar(identifier: .gregorian)

    @Test("A later id in the list is not replaced by the first moment")
    func selectedIdInListWins() {
        let newest = facts(id: UUID(), dayOffset: 0)
        let older = facts(id: UUID(), dayOffset: -1)
        let list = [newest, older]

        let shown = MomentDetailSelection.resolve(
            opened: older,
            moments: list,
            selectedID: older.id
        )

        #expect(shown.id == older.id)
    }

    @Test("A missing id returns the opened moment, never moments[0]")
    func missingIdKeepsOpened() {
        let today = facts(id: UUID(), dayOffset: 0)
        let yesterday = facts(id: UUID(), dayOffset: -1)
        // Home feed used to pass today-only; the tapped yesterday id is absent.
        let todayOnly = [today]

        let shown = MomentDetailSelection.resolve(
            opened: yesterday,
            moments: todayOnly,
            selectedID: yesterday.id
        )

        #expect(shown.id == yesterday.id)
        #expect(shown.id != todayOnly[0].id)
    }

    @Test("Opening the newest moment still returns that moment")
    func newestMomentStillResolves() {
        let newest = facts(id: UUID(), dayOffset: 0)
        let older = facts(id: UUID(), dayOffset: -2)
        let list = [newest, older]

        let shown = MomentDetailSelection.resolve(
            opened: newest,
            moments: list,
            selectedID: newest.id
        )

        #expect(shown.id == newest.id)
    }

    // MARK: - Fixtures

    private func facts(id: UUID, dayOffset: Int) -> MomentFacts {
        let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: Date())!
        let day = DayIdentifier(date: dayDate, calendar: calendar)
        let captured = calendar.date(
            bySettingHour: 14, minute: 0, second: 0, of: day.date
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
