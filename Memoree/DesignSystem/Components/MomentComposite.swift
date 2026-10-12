import SwiftUI
import UIKit

/// The composite's one accessibility label.
///
/// **Removed: `element(for:isInteractive:)`.** This function was written for a
/// real reason — three call sites, three copies of the same three modifiers, and
/// a rule that they must not drift. Then all three call sites kept their
/// hand-rolled copies and the function was never called once. `grep '\.element('`
/// returns nothing.
///
/// Recorded rather than quietly deleted, because it is the more interesting
/// half of the story: a helper whose entire justification was consistency does
/// not deliver consistency unless something *stops* people from writing their
/// own copy, and a function nobody calls is a function nobody stops anybody
/// replacing. The three copies are checked by `VoiceOverTests` instead, which
/// actually can fail.
///
/// ## What each caller gets
///
/// - **Camera review** — a button. The hint says what a double tap does.
/// - **Today feed card** — a button. Activate opens the moment in the archive.
/// - **Archive detail** — not a button, and no hint. A tappable image that goes
///   nowhere is a dead end (`AGENTS.md` §6), and VoiceOver announcing "button"
///   on something that is not one is the same lie in a different direction.
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
///     viewer than the Today screen and uses a larger one, so it passes
///     `Theme.Size.insetCamera` and the others `Theme.Size.insetStandard`.
///   - onTapInset: Makes the inset a button that promotes it. `nil` means the
///     inset is **not** interactive, which is deliberate in both callers: the
///     large view has to stay live while composing, and on the Today screen a
///     tappable image that goes nowhere is a dead end (AGENTS.md §6).
struct MomentComposite: View {

    let large: UIImage?
    let inset: UIImage?
    var insetWidth: CGFloat = 108
    var onTapInset: (() -> Void)?
    var onTapLarge: (() -> Void)?
    var onDoubleTapLarge: (() -> Void)?
    var onFlip: (() -> Void)?
    var onPlayBTS: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let large {
                Image(uiImage: large)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Single tap only — double-tap flip was undiscoverable.
                        // Prefer `onTapLarge`; fall back to legacy double-tap
                        // handler only when no single-tap action is wired.
                        if let onTapLarge {
                            onTapLarge()
                        } else {
                            onDoubleTapLarge?()
                        }
                    }
            } else {
                Theme.Color.canvas
            }

            if let inset {
                insetLayer(inset)
            }

            // Flip (leading) and BTS (trailing) are independent — both can show.
            HStack(spacing: Theme.Spacing.s) {
                if let onFlip {
                    compositeChromeButton(
                        systemName: "arrow.triangle.2.circlepath",
                        label: "Flip camera angles",
                        action: onFlip
                    )
                }
                Spacer(minLength: 0)
                if let onPlayBTS {
                    compositeChromeButton(
                        systemName: "play.fill",
                        label: "Play Behind the Scenes clip",
                        action: onPlayBTS
                    )
                }
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func compositeChromeButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: systemName)
                .font(Theme.Typography.retakePill)
                .foregroundStyle(Theme.Color.textPrimary)
                .padding(Theme.Spacing.s)
                .background(Theme.Color.canvas.opacity(0.6))
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(Theme.Color.divider, lineWidth: 1)
                }
        }
        .buttonStyle(.pressDip)
        .accessibilityLabel(label)
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
