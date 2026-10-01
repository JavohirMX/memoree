import SwiftUI
import UIKit

/// Builds the composite's one accessibility element.
///
/// **A function, not the `static let` that was here.** The label has to vary by
/// whether the inset can be tapped, and there was no way to express "this is
/// interactive" in a constant while the caller set the hint and the trait beside
/// it. Three modifiers in one place is what keeps them consistent, and the reason
/// the constant could not.
///
/// ## What each caller gets
///
/// - **Camera review** — a button. The hint says what a double tap does.
/// - **Archive detail and Today** — not a button, and no hint. A tappable image
///   that goes nowhere is a dead end (`AGENTS.md` §6), and VoiceOver announcing
///   "button" on something that is not one is the same lie in a different
///   direction.
///
/// ## Why the photographs are described rather than announced
///
/// They are announced as *photographs*, not as image data. VoiceOver would
/// otherwise try to describe the contents of a scene through an alt-text service,
/// which is both slow and irrelevant — what the user needs to know is that there
/// are two, and which is which.
struct CompositeAccessibility {

    /// The label, shared by every caller.
    static let label = "Your moment: two photographs, the scene and you."

    /// One element, labelled, with the hint and trait that follow from whether
    /// the composite is interactive.
    @ViewBuilder
    static func element(
        for view: some View,
        isInteractive: Bool
    ) -> some View {
        if isInteractive {
            view
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityHint("Double tap to swap which photo is large")
                .accessibilityAddTraits(.isButton)
        } else {
            view
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }
}

/// The two photographs of a moment, one large and one inset top-left.
///
/// BeReal's composite geometry, from their published ad guidelines and TRD §5.6:
/// the rear full-bleed at 3:4, the front inset into the top-left corner at a
/// **14pt** radius, overlapping rather than sitting beside.
///
/// One implementation, two callers. The camera screen's review state and the
/// Today screen both show this, and they were the same twenty lines of `ZStack`
/// written twice — which is how a composite ends up with a 108pt inset on one
/// screen and a 96pt one on the other.
///
/// - Parameters:
///   - large: The photograph drawn full-bleed.
///   - inset: The photograph drawn into the top-left square. `nil` renders the
///     large one alone, which is what a half-captured moment looks like.
///   - insetWidth: The inset's side length. The camera screen is closer to the
///     viewer than the Today screen and uses a larger one.
///   - onTapInset: Makes the inset a button that promotes it. `nil` means the
///     inset is **not** interactive, which is deliberate in both callers: the
///     large view has to stay live while composing, and on the Today screen a
///     tappable image that goes nowhere is a dead end (AGENTS.md §6).
struct MomentComposite: View {

    let large: UIImage?
    let inset: UIImage?
    var insetWidth: CGFloat = 108
    var onTapInset: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let large {
                Image(uiImage: large)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Theme.Color.canvas
            }

            if let inset {
                insetLayer(inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func insetLayer(_ inset: UIImage) -> some View {
        let image = Image(uiImage: inset)
            .resizable()
            .scaledToFill()
            .frame(width: insetWidth, height: insetWidth)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.inset)
                    .strokeBorder(Theme.Color.textPrimary, lineWidth: 1)
            }

        if let onTapInset {
            Button(action: onTapInset) { image }
                .buttonStyle(.plain)
                .padding(Theme.Spacing.m)
        } else {
            image
                .padding(Theme.Spacing.m)
                .allowsHitTesting(false)
        }
    }
}
