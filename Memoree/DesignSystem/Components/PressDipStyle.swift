import SwiftUI

/// A button that dips while it is held down.
///
/// ## Why it exists
///
/// The stock camera's shutter shrinks on press, and it is the **only** feedback
/// between the finger leaving the glass and the photograph existing — a gap of a
/// few hundred milliseconds, during which the app is reconfiguring the capture
/// session. Without it, pressing the shutter has no visible consequence until the
/// inset photograph appears in the corner.
///
/// Every other control on this screen changes state on tap (the zoom buttons fill,
/// the focus ring appears) or ends a screen. The shutter does neither.
///
/// ## Why the animation goes through `appAnimation`
///
/// A `ButtonStyle` that called `.animation(_:value:)` directly would animate under
/// Reduce Motion, which `AGENTS.md` §11 forbids: Reduce Motion means the
/// animation is *removed*, not shortened. `appAnimation` substitutes `nil`, and
/// because it reads `@Environment` itself a call site cannot forget.
struct PressDipStyle: ButtonStyle {

    /// How far the label shrinks while pressed.
    var scale: CGFloat = 0.92

    /// How long the dip takes to return.
    ///
    /// **Short.** A slow return reads as sluggishness rather than as feedback —
    /// the press is confirmed, not narrated. 0.12s is under the threshold where a
    /// user notices the animation rather than the button.
    var release: Double = 0.12

    func makeBody(configuration: Configuration) -> some View {
        // Pressing in is faster than releasing, which is what makes it read as a
        // press rather than as a transition. The trailing closure is the animation
        // `appAnimation` substitutes `nil` for under Reduce Motion.
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .appAnimation(configuration.isPressed) {
                .easeOut(duration: configuration.isPressed ? 0.06 : release)
            }
    }
}

extension ButtonStyle where Self == PressDipStyle {

    /// The default dip, for the shutter and anything else the same size.
    static var pressDip: PressDipStyle { PressDipStyle() }
}
