import SwiftUI

/// Display numerals that scale with Dynamic Type.
///
/// ## Why this exists rather than a text style
///
/// Every other token in `Theme.Typography` is a `TextStyle`, because every one of
/// them has a text style that is *the same size at the default setting* —
/// `.title2` is 22, `.headline` is 17, `.caption2` is 11. Writing them as text
/// styles was free.
///
/// **The big numerals are not.** The streak on the Stats screen is 56pt and the
/// countdown on Today is 64pt, and there is no text style at either size — the
/// largest is `.largeTitle` at 34pt. A `Font` has no "64pt but scales" API, so
/// there are two options and one of them is wrong:
///
/// - **Leave it as `Font.system(size: 64)`.** Does not scale. This is what the
///   app did, and it is the defect this type fixes — the whole typography ramp
///   was fixed point sizes and a user at the largest accessibility size saw a
///   pixel-identical screen.
/// - **`Font.system(.largeTitle)`.** Scales, but is nearly half the size at the
///   default setting, so the design collapses to fit the API.
///
/// `@ScaledMetric` is the third option: the base size is honoured exactly, and
/// the user's text-size setting is applied as a multiplier relative to a named
/// text style. So 56pt stays 56pt for a user who has not changed anything, and
/// grows for one who has.
///
/// ## `relativeTo` is not decorative
///
/// The multiplier comes from a fixed anchor of `.largeTitle` — the largest text
/// style there is, which is the right anchor for the largest text in the app.
///
/// ## The cap, and why it is there
///
/// `maximumScale` exists because these numerals sit in fixed layouts: a 56pt
/// streak that grows to 180pt does not wrap, it clips, and a clipped digit is
/// worse than a small one. Capping means a user at the largest setting gets the
/// largest number the layout can honestly show, rather than half of one.
///
/// **The cap is a compromise, and it is recorded as one.** The alternative is
/// letting the layout grow, which for the Today countdown means the number
/// collides with the shutter button. Nothing is truncated by this cap — the
/// digits are always all there, and the *font* is what gives way.
struct ScaledDisplayFont: ViewModifier {

    /// The size at the default Dynamic Type setting.
    let base: CGFloat

    let weight: Font.Weight

    /// The largest multiple of `base` that will be used.
    var maximumScale: CGFloat

    /// The multiplier the user's text-size setting implies.
    ///
    /// Initialised to `1` because that *is* the default setting, and
    /// `@ScaledMetric` needs an initial value: the property holds the default
    /// and SwiftUI rewrites it when the setting changes. So `1` means "the size
    /// they asked for is exactly `base`" and it is the honest default rather
    /// than a placeholder.
    ///
    /// **The anchor is `.largeTitle` and cannot be a parameter**, which is the
    /// one limitation worth knowing: `@ScaledMetric(relativeTo:)` takes the
    /// style as an attribute argument, not a value, so there is no way to pass
    /// one in. `.largeTitle` is also the honest choice — it is the largest text
    /// style there is, and these numerals are the largest text in the app, so
    /// the anchor and the role agree.
    @ScaledMetric(relativeTo: Font.TextStyle.largeTitle) private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content.font(
            .system(
                size: min(base * scale, base * maximumScale),
                weight: weight
            )
        )
    }
}

extension View {
    /// A numeral large enough to be the point of the screen, and large enough to
    /// scale for a user who asked it to.
    ///
    /// `maximumScale` defaults to 2.5 — a 64pt countdown becomes 160pt, which
    /// fits the Today screen, and a 56pt streak becomes 140pt, which fits the
    /// Stats screen. Both are one step below the largest Dynamic Type setting, so
    /// the numeral grows across the range and then holds.
    func scaledDisplayFont(
        _ base: CGFloat,
        weight: Font.Weight = .bold,
        maximumScale: CGFloat = 2.5
    ) -> some View {
        modifier(
            ScaledDisplayFont(
                base: base,
                weight: weight,
                maximumScale: maximumScale
            )
        )
    }
}
