import SwiftUI

/// Token subset for the widget extension — mirrors `Theme` in the app (ADR-012 / ADR-040).
///
/// The extension cannot import the app module. Hex values must stay in lockstep
/// with `Memoree/DesignSystem/Theme.swift`; source-scan invariants cover the app
/// target, not this file — change both together.
enum WidgetTheme {
    enum Color {
        static let canvas = SwiftUI.Color(red: 0, green: 0, blue: 0)
        static let textPrimary = SwiftUI.Color.white
        /// `#8E8E93`
        static let textSecondary = SwiftUI.Color(
            red: 142 / 255,
            green: 142 / 255,
            blue: 147 / 255
        )
        /// `#848486` — decorative marks only
        static let textTertiary = SwiftUI.Color(
            red: 132 / 255,
            green: 132 / 255,
            blue: 134 / 255
        )
    }
}
