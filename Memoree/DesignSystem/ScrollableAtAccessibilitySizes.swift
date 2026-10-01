import SwiftUI

/// Lets a fixed layout scroll when it no longer fits.
///
/// ## The problem it solves
///
/// `TodayView`'s main column is a `VStack` with `Spacer(minLength:)` above and
/// below the state copy, which centres it. That is the right layout at the
/// default text size and the wrong one at every accessibility size, because the
/// copy is then several times taller than the screen.
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
/// So the fix is to change the *layout* at accessibility sizes rather than to
/// wrap the existing one — the spacers become nothing, the content becomes
/// top-aligned, and the whole column becomes scrollable.
///
/// ## Why the branch, and why at accessibility sizes only
///
/// At the sizes the design was drawn at, this modifier does nothing at all, and
/// that is deliberate. A scroll view on the Today screen at the default size
/// would be a worse experience than a centred column: the user would be offered
/// a scroll that has nothing to scroll to, on the screen they use most.
///
/// The trigger is `isAccessibilitySize` rather than a measurement, for the same
/// reason `MetadataRow` uses it — and the same reason it stopped using
/// `ViewThatFits`. A branch driven by a measurement that does not hold is worse
/// than no branch, because it looks like it is handling the problem.
private struct ScrollableAtAccessibilitySizes: ViewModifier {

    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
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
    /// Makes a self-sizing, vertically centred layout scrollable when the user's
    /// text size has outgrown it.
    ///
    /// Applied to `TodayView`'s main column and nowhere else, because it is the
    /// only screen that both centres its content vertically and has enough text to
    /// overflow at a large size.
    func scrollableAtAccessibilitySizes() -> some View {
        modifier(ScrollableAtAccessibilitySizes())
    }
}
