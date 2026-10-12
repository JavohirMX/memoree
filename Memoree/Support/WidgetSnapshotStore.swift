import Foundation

/// Reads and writes `WidgetSnapshot` in the App Group suite (ADR-040).
enum WidgetSnapshotStore {

    private static let key = "widget.snapshot.v1"

    static func load() -> WidgetSnapshot {
        let defaults = WidgetAppGroup.defaults
        guard let data = defaults.data(forKey: key) else { return .empty }
        return (try? JSONDecoder().decode(WidgetSnapshot.self, from: data)) ?? .empty
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        WidgetAppGroup.defaults.set(data, forKey: key)
    }
}
