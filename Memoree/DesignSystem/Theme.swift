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
        /// Hairline separators, pressed states and chips.
        ///
        /// **This absorbed `surfaceElevated`.** Both were `#2C2C2E`, only
        /// `divider` was ever used, and two names for one colour means someone
        /// eventually picks the other one and wonders why the app has two greys.
        static let divider = SwiftUI.Color(hex: 0x2C2C2E)

        static let textPrimary = SwiftUI.Color(hex: 0xFFFFFF)
        static let textSecondary = SwiftUI.Color(hex: 0x8E8E93)

        /// **The old third tier, kept and legible.**
        ///
        /// This was `#636366` — **3.51:1 on the canvas and 2.84:1 on a card**,
        /// against WCAG AA's 4.5:1 for normal text. It carried real content:
        /// "best 500", the retake counts, "Wider is more random". So it was an
        /// accessibility failure and not a decorative grey that could be argued
        /// about.
        ///
        /// **`#848486` is the faintest grey that reaches 4.5:1 on a card**, the
        /// harder of the two backgrounds it is used on. Measured, not chosen by
        /// eye: `#848486` is 5.63:1 on black and 4.56:1 on `#1C1C1E`.
        ///
        /// ## What this cost, stated rather than hidden
        ///
        /// **The ramp is now two tiers, not three**, and the numbers say why.
        /// Secondary is 6.44:1 and this is 5.63:1 — a 13% step, down from the 46%
        /// the old pair had. Thirteen percent does not read as a tier.
        ///
        /// That is not a compromise between two goods. On a **pure black canvas**
        /// a third *distinct* tier that passes AA does not exist: keeping
        /// `#8E8E93` for the middle and pushing the top to `#B0B0B8` does produce
        /// three passing tiers with a 73% step, but it brightens every piece of
        /// secondary text in the app and changes what the thing feels like. The
        /// tone was kept and the tier was given up. That is the right way round:
        /// legibility is not negotiable and a third shade of grey is.
        ///
        /// **Use it for icons, dividers and genuinely decorative marks** — where
        /// 3:1 is the correct threshold — and reach for `textSecondary` whenever
        /// a *word* is what carries the meaning.
        static let textTertiary = SwiftUI.Color(hex: 0x848486)

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
    }

    // MARK: - Size

    /// Fixed dimensions that are not spacing and not type.
    ///
    /// Exists because the app had **ten** numeric literals used as dimensions in
    /// view files — 52 for three button heights, 44 for two tap targets, 72 for
    /// the shutter, 96 and 108 for the two composite insets, 20 and 32 for icon
    /// glyphs. `AGENTS.md` §11 says no hardcoded values in a view, and the
    /// invariant test enforced that for colour only. This closes the rest.
    enum Size {
        /// Apple's minimum comfortable tap target, in points.
        ///
        /// The floor every control must reach, regardless of how small its
        /// *label* is. Five controls in this app were below it — the camera's
        /// "Cancel" was ~17pt tall, because the frame came from the font size
        /// rather than from anything.
        static let tapTarget: CGFloat = 44

        /// The app's primary button height at the default text size.
        ///
        /// A **starting** height, not a fixed one: it grows with the label past
        /// the accessibility sizes rather than clipping it.
        static let tapTargetComfortable: CGFloat = 52

        /// The shutter ring. The largest tap target in the app by design.
        static let shutter: CGFloat = 72

        /// The front-camera inset on the camera review screen. Larger than the
        /// archive's, because that screen is closer to the viewer.
        static let insetCamera: CGFloat = 108

        /// The front-camera inset everywhere else.
        static let insetStandard: CGFloat = 96

        /// A zoom button's visible circle.
        ///
        /// **Smaller than the tap target on purpose.** 34 is what the stock camera
        /// draws and it keeps the row from competing with the 72pt shutter; the
        /// 44pt target sits around it, so nothing is harder to press than it looks.
        static let zoomButton: CGFloat = 34

        /// The tap-to-focus ring on the camera preview.
        ///
        /// The stock camera draws a square of roughly this size, and matching it
        /// matters more than it looks: a ring that is too small reads as a
        /// crosshair and a ring that is too large covers the thing being focused.
        static let focusRing: CGFloat = 76

        /// The Today header's icon buttons.
        static let headerIcon: CGFloat = 20

        /// A standalone icon with no text beside it — the "not in Photos" glyph.
        static let iconStandalone: CGFloat = 32

        /// The inner dot of the shutter ring, inset from its stroke.
        static let shutterInnerInset: CGFloat = 6

        /// The largest the Today screen's composite is drawn, before the screen
        /// scrolls.
        ///
        /// A **maximum**, not a fixed height — the composite is 3:4 and its width
        /// comes from the screen, so on a tall phone this is what stops it from
        /// pushing the shutter off the bottom.
        static let todayCompositeMaxHeight: CGFloat = 360

        /// The largest the Today screen's composite is drawn in landscape orientation.
        static let compositeLandscapeMaxHeight: CGFloat = 240

        /// The full-size photograph the archive detail requests, in points at 1×.
        ///
        /// A downsample on purpose (TRD §6.5): the original 3–5 MB stays in the
        /// user's library and is never copied into memory to fill a screen.
        static let detailImageWidth: CGFloat = 520
        static let detailImageHeight: CGFloat = 693

        /// The largest the archive detail photograph is drawn in landscape orientation.
        static let detailLandscapeMaxHeight: CGFloat = 280

        /// The minimum and maximum item widths for the adaptive archive grid.
        static let gridThumbnailMinimum: CGFloat = 105
        static let gridThumbnailMaximum: CGFloat = 160

        /// The gap between cells in the archive photo grid.
        ///
        /// Tight on purpose — the photographs are the content and the gap is
        /// just enough to show the canvas between them. Half of `Spacing.xs`.
        static let gridSpacing: CGFloat = 2

        /// The number of columns in the archive photo grid.
        static let gridColumns: Int = 3

        /// The width of the navigation and action column on the Today screen in landscape.
        static let todayLandscapeSidebarWidth: CGFloat = 220

        /// The clearance needed at the bottom of the feed scroll view so content
        /// is not obscured by the floating shutter button.
        static let feedBottomClearance: CGFloat = 96
    }

    // MARK: - Radius

    enum Radius {
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

        /// 13. Timestamps, metadata, and anything that is a fact about a
        /// photograph rather than a sentence.
        static let metadata = Font.system(.footnote)

        static let button = Font.system(.headline)

        /// 11. The smallest text in the app, and the one most at risk from an
        /// accessibility size — so it is a text style rather than a literal, and
        /// it is a caption *style* rather than a small custom size.
        static let retakePill = Font.system(.caption2).weight(.semibold)

        /// 11 rounded semibold. Magnification labels inside the camera's zoom buttons.
        static let zoomLabel = Font.system(.caption2, design: .rounded).weight(.semibold)

        /// The Today countdown: 64 at the default setting.
        ///
        /// **A `CGFloat`, not a `Font`.** There is no text style at 64 — the
        /// largest is `.largeTitle` at 34 — so a `Font` here would either not scale
        /// or would be half the size. Use `.scaledDisplayFont(Theme.Typography.displaySize)`
        /// where this goes, which honours the number exactly and applies the user's
        /// text-size setting as a multiplier. See `ScaledFont.swift`.
        static let displaySize: CGFloat = 64
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
