import Foundation
import WidgetKit

/// Writes the App Group snapshot and asks WidgetKit to reload (ADR-040).
@MainActor
enum WidgetSnapshotPublisher {

    static func publish(from store: MomentStore, calendar: Calendar = .current, now: Date = Date()) {
        let today = DayIdentifier(date: now, calendar: calendar)
        let snapshot = WidgetSnapshotBuilder.make(
            facts: store.facts(),
            today: today,
            calendar: calendar,
            now: now
        )
        WidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
