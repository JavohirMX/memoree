import SwiftUI
import UIKit

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

    /// One description for both callers.
    ///
    /// The composite is two images with no text between them, so VoiceOver
    /// would otherwise announce nothing at all — or, worse, two unlabelled
    /// images, which is worse than silence because it invites a tap.
    static let accessibilityLabel = "Your moment: two photographs, the scene and you."
}
