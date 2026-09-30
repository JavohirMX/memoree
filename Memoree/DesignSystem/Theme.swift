import SwiftUI

/// Memoree's design tokens.
///
/// Dark only, by construction. There is no `colorScheme` branch anywhere in this
/// codebase and no light appearance — see AGENTS.md §2.6 and ADR-012.
///
/// The canvas is `#000000` exactly. A near-black like `#0A0A0A` reads as dark
/// grey and destroys the effect the whole app depends on: photographs are the
/// only saturated content on screen.
///
/// There is no brand hue. White is the verb. Amber appears only for lateness,
/// and red only for destructive confirmation. If you are reaching for a second
/// colour, re-read docs/DECISION_LOG.md §10.
enum Theme {

    // MARK: - Colour

    enum Color {
        /// Every screen background. Exactly black.
        static let canvas = SwiftUI.Color(hex: 0x000000)
        /// Cards, sheets, rows.
        static let surface = SwiftUI.Color(hex: 0x1C1C1E)
        /// Pressed states, chips.
        static let surfaceElevated = SwiftUI.Color(hex: 0x2C2C2E)
        /// Hairline separators.
        static let divider = SwiftUI.Color(hex: 0x2C2C2E)

        static let textPrimary = SwiftUI.Color(hex: 0xFFFFFF)
        static let textSecondary = SwiftUI.Color(hex: 0x8E8E93)
        static let textTertiary = SwiftUI.Color(hex: 0x636366)

        /// Label on a white fill. Intentional inversion.
        static let onAccent = SwiftUI.Color(hex: 0x000000)

        /// THE ONLY amber. Late badges and a sub-30s countdown. Nothing else.
        static let late = SwiftUI.Color(hex: 0xFFD60A)

        /// Destructive confirmation only. Never a general error colour.
        static let destructive = SwiftUI.Color(hex: 0xFF453A)
    }

    // MARK: - Spacing

    /// Base unit is 4pt. Everything is a multiple.
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Full-bleed dual-lens cards sit edge to edge: 0pt side inset.
        static let none: CGFloat = 0
    }

    // MARK: - Radius

    enum Radius {
        /// Buttons and the countdown pill.
        static let pill: CGFloat = 500
        /// Modals and sheets.
        static let modal: CGFloat = 24
        /// Content cards.
        static let card: CGFloat = 18
        /// The front-camera inset. Matches the BeReal composite geometry.
        static let inset: CGFloat = 14
        /// Grid thumbnails.
        static let thumbnail: CGFloat = 6
    }

    // MARK: - Typography

    /// SF Pro, the system face. No custom typeface.
    ///
    /// Named `Typography`, not `Type`: a nested type member may not be called
    /// `Type` (it collides with the `foo.Type` metatype expression), and not
    /// `Font` either, because that would shadow SwiftUI's `Font` inside this
    /// scope and silently break every call site.
    enum Typography {
        /// The countdown. 700 weight, TABULAR figures so digits do not jitter
        /// as they change once per second. This is not a nicety.
        static let countdown = Font.system(size: 24, weight: .bold).monospacedDigit()

        static let screenTitle = Font.system(size: 22, weight: .bold)
        static let cardUsername = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 15, weight: .regular)
        static let caption = Font.system(size: 16, weight: .regular)
        static let metadata = Font.system(size: 13, weight: .regular)
        static let badge = Font.system(size: 12, weight: .bold)
        static let button = Font.system(size: 17, weight: .semibold)
        static let retakePill = Font.system(size: 11, weight: .semibold)

        /// Large display type for the Today screen's primary moment state.
        static let display = Font.system(size: 64, weight: .bold).monospacedDigit()
    }

    // MARK: - Shadow

    /// On a black canvas a shadow does not read as darkening — it reads as
    /// opacity. Prefer omitting shadows entirely over stacking them.
    enum Elevation {
        static let card = (color: SwiftUI.Color.black.opacity(0.6), radius: CGFloat(24))
    }
}

// MARK: - Helpers

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
