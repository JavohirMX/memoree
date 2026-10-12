import Foundation

/// Shared App Group identity for the widget snapshot and camera handoff (ADR-040).
enum WidgetAppGroup {
    static let identifier = "group.com.javohirmx.memoree"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }
}
