import SwiftUI

/// Lets a fixed layout scroll when it no longer fits.
///
/// ## The problem it solves
///
/// `TodayView`'s main column is a `VStack` with `Spacer(minLength:)` above and
/// below the state copy, which centres it. That is the right layout when the
/// content fits and the wrong one when it does not.
///
/// **A `VStack` that centres content taller than its container overflows in both
/// directions at once**, so the visible result is not "too much text" but text
/// *sliced off at the top and the bottom* — the streak's "375" lost its top half
/// to the status bar, "Next moment at 17:59" became "Next mome…", and "Nothing to
/// do until then" became "Nothing to do u…". Wrapping in a `ScrollView` is the
/// usual advice and it does not work here: the column still centres, and a
/// centring stack inside a scroll view still puts half its content above the
/// scroll view's own top edge.
///
/// So the fix is to change the *layout* when it will not fit rather than to wrap
/// the existing one — the spacers become nothing, the content becomes top-aligned,
/// and the whole column becomes scrollable.
///
/// ## The two triggers, and why neither is a measurement
///
/// The original had one: `isAccessibilitySize`. A screen in landscape has a
/// second, and it matters more because it hides the shutter —
///
/// 1. **An accessibility text size.** The copy is several times taller than the
///    screen at any width.
/// 2. **A compact height.** Landscape on a phone is a short viewport, and this
///    column cannot fit in it: header, streak, state copy, countdown, the primary
///    button and the footer together are taller than a landscape phone. The
///    button going off-screen is the whole cost — it is the app's only action.
///
/// **`verticalSizeClass` rather than a measurement of the content**, for the same
/// reason `MetadataRow` uses a branch rather than `ViewThatFits`: a branch driven
/// by a measurement that does not hold is worse than no branch, because it looks
/// like it is handling the problem. A size class is a system classification of the
/// viewport, not an estimate of one view inside it — and it holds.
///
/// At a portrait phone in portrait, neither fires and this modifier does nothing
/// at all, which is deliberate: a scroll view on the Today screen at the default
/// size would be a worse experience than a centred column.
private struct ScrollableWhenItCannotFit: ViewModifier {

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize || verticalSizeClass == .compact {
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
            }
            // Never bounce, never scroll a screen that fits. A scroll view that
            // has nothing to scroll is a promise the layout cannot keep.
            .scrollBounceBehavior(.basedOnSize)
        } else {
            content
        }
    }
}

extension View {
    /// Makes a self-sizing, vertically centred layout scrollable when it cannot
    /// fit — because the text is very large, or because the viewport is short.
    ///
    /// Applied to `TodayView`'s main column and nowhere else, because it is the
    /// only screen that both centres its content vertically and has enough content
    /// to overflow in either of those cases.
    func scrollableWhenItCannotFit() -> some View {
        modifier(ScrollableWhenItCannotFit())
    }
}
