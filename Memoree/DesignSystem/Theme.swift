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

        /// THE ONLY amber, and the app's single accent.
        ///
        /// It used to be reserved for late badges and a sub-30s countdown, both
        /// of which ADR-023 and ADR-024 removed — an off-window moment is now
        /// deliberately indistinguishable from an on-time one, so there is
        /// nothing left for the colour to *mean*. It is no longer called `late`,
        /// because a token whose name contradicts its only use is the same
        /// mistake as the badge was. See ADR-025.
        ///
        /// Reserved for: a permission the user declined and can only restore in
        /// the system Settings app. One use, deliberately.
        static let accent = SwiftUI.Color(hex: 0xFFD60A)

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
        /// Buttons.
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
    ///
    /// ## Every token is a text style, and that is load-bearing
    ///
    /// **This whole ramp used to be `Font.system(size:)`, which does not scale
    /// with Dynamic Type at all.** Not "scaled a little" — not at all. A fixed
    /// point size is a fixed point size, so a user who had raised their text size
    /// to the largest accessibility setting saw a pixel-identical screen, in an
    /// app whose settings screen explains what a permission is for.
    ///
    /// Found by screenshotting the same screen at
    /// `accessibility-extra-extra-extra-large` and at the default size and
    /// comparing. The two were the same picture.
    ///
    /// `Font.system(_:weight:)` takes a `TextStyle` and scales with the setting.
    /// The weights are kept because the design leans on weight for hierarchy —
    /// white is the verb, and boldness is the only other emphasis available in a
    /// single-hue app — and `.weight(_:)` on a text style preserves both.
    ///
    /// The point sizes are preserved at the default setting, which is what keeps
    /// the design intact: `.title2` *is* 22, `.headline` *is* 17 semibold,
    /// `.subheadline` *is* 15, `.callout` *is* 16, `.footnote` *is* 13,
    /// `.caption2` *is* 11. So this is not a redesign — it is the same ramp that
    /// finally responds to the setting.
    enum Typography {
        /// 22 at the default size. The largest role on any screen except the
        /// numerals themselves.
        static let screenTitle = Font.system(.title2).weight(.bold)

        /// 17 semibold. Named for BeReal's username row, which Memoree does not
        /// have — kept so the ramp stays a ramp and a future card has a slot.
        static let cardUsername = Font.system(.headline)

        /// 15. The workhorse: every paragraph of copy in the app.
        static let body = Font.system(.subheadline)

        /// 16. Slightly larger than `body`, for copy that is read rather than
        /// scanned.
        static let caption = Font.system(.callout)

        /// 13. Timestamps, metadata, and anything that is a fact about a
        /// photograph rather than a sentence.
        static let metadata = Font.system(.footnote)

        static let button = Font.system(.headline)

        /// 11. The smallest text in the app, and the one most at risk from an
        /// accessibility size — so it is a text style rather than a literal, and
        /// it is a caption *style* rather than a small custom size.
        static let retakePill = Font.system(.caption2).weight(.semibold)

        /// The Today countdown: 64 at the default setting.
        ///
        /// **A `CGFloat`, not a `Font`.** There is no text style at 64 — the
        /// largest is `.largeTitle` at 34 — so a `Font` here would either not scale
        /// or would be half the size. Use `.scaledDisplayFont(Theme.Typography.displaySize)`
        /// where this goes, which honours the number exactly and applies the user's
        /// text-size setting as a multiplier. See `ScaledFont.swift`.
        static let displaySize: CGFloat = 64
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
