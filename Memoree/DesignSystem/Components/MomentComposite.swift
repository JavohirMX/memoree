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

/// The four corners an inset photograph can magnetically snap to.
enum InsetCorner: String, CaseIterable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var accessibilityName: String {
        switch self {
        case .topLeading: "top leading"
        case .topTrailing: "top trailing"
        case .bottomLeading: "bottom leading"
        case .bottomTrailing: "bottom trailing"
        }
    }
}

/// Pure layout geometry for composite insets and corner snapping.
enum InsetPlacement {

    /// Calculates the resting center position for an inset within a container.
    static func restingCenter(
        for corner: InsetCorner,
        in containerSize: CGSize,
        insetWidth: CGFloat,
        margin: CGFloat = Theme.Spacing.m,
        hasBottomChrome: Bool,
        isRTL: Bool = false
    ) -> CGPoint {
        let half = insetWidth / 2
        let bottomMargin = hasBottomChrome
            ? margin + Theme.Size.tapTarget + Theme.Spacing.s
            : margin

        guard containerSize.width > (margin * 2 + insetWidth),
              containerSize.height > (margin + bottomMargin + insetWidth) else {
            return CGPoint(x: margin + half, y: margin + half)
        }

        let leadingX = isRTL ? containerSize.width - margin - half : margin + half
        let trailingX = isRTL ? margin + half : containerSize.width - margin - half

        switch corner {
        case .topLeading:
            return CGPoint(x: leadingX, y: margin + half)
        case .topTrailing:
            return CGPoint(x: trailingX, y: margin + half)
        case .bottomLeading:
            return CGPoint(x: leadingX, y: containerSize.height - bottomMargin - half)
        case .bottomTrailing:
            return CGPoint(x: trailingX, y: containerSize.height - bottomMargin - half)
        }
    }

    /// Resolves which corner is closest to the given center point.
    static func nearestCorner(
        to center: CGPoint,
        in containerSize: CGSize,
        isRTL: Bool = false
    ) -> InsetCorner {
        let midX = containerSize.width / 2
        let midY = containerSize.height / 2

        let isTop = center.y < midY
        let isLeft = center.x < midX
        let isLeading = isRTL ? !isLeft : isLeft

        if isTop {
            return isLeading ? .topLeading : .topTrailing
        } else {
            return isLeading ? .bottomLeading : .bottomTrailing
        }
    }

    /// Clamps a proposed center point so the inset remains within the container bounds.
    static func clampCenter(
        _ proposed: CGPoint,
        insetWidth: CGFloat,
        in containerSize: CGSize,
        padding: CGFloat = Theme.Spacing.xs
    ) -> CGPoint {
        let half = insetWidth / 2
        let minX = half + padding
        let maxX = max(minX, containerSize.width - half - padding)
        let minY = half + padding
        let maxY = max(minY, containerSize.height - half - padding)

        return CGPoint(
            x: min(max(proposed.x, minX), maxX),
            y: min(max(proposed.y, minY), maxY)
        )
    }
}

/// The two photographs of a moment, one large and one inset into a corner.
///
/// BeReal's composite geometry, from their published ad guidelines and TRD §5.6:
/// the rear full-bleed at 3:4, the front inset at a **14pt** radius, overlapping
/// rather than sitting beside.
///
/// The inset is movable and magnetically snaps to any of the four corners with
/// spring physics. Tapping the inset promotes it to large.
///
/// - Parameters:
///   - large: The photograph drawn full-bleed.
///   - inset: The photograph drawn into the inset square. `nil` renders the
///     large one alone, which is what a half-captured moment looks like.
///   - insetWidth: The inset's side length. The camera screen is closer to the
///     viewer than the Today screen and uses a larger one, so it passes
///     `Theme.Size.insetCamera` and the others `Theme.Size.insetStandard`.
///   - initialCorner: The corner the inset starts at (defaults to `.topLeading`).
///   - onCornerChanged: Callback invoked when the user moves the inset to a new corner.
///   - onTapInset: Makes the inset interactive to swap large and small.
struct MomentComposite: View {

    let large: UIImage?
    let inset: UIImage?
    var insetWidth: CGFloat = Theme.Size.insetCamera
    var initialCorner: InsetCorner = .topLeading
    var onCornerChanged: ((InsetCorner) -> Void)?
    var onTapInset: (() -> Void)?
    var onTapLarge: (() -> Void)?
    var onDoubleTapLarge: (() -> Void)?
    var onFlip: (() -> Void)?
    var onPlayBTS: (() -> Void)?
    var timestamp: String? = nil

    @Environment(\.layoutDirection) private var layoutDirection
    @State private var corner: InsetCorner
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false

    init(
        large: UIImage?,
        inset: UIImage?,
        insetWidth: CGFloat = Theme.Size.insetCamera,
        initialCorner: InsetCorner = .topLeading,
        onCornerChanged: ((InsetCorner) -> Void)? = nil,
        onTapInset: (() -> Void)? = nil,
        onTapLarge: (() -> Void)? = nil,
        onDoubleTapLarge: (() -> Void)? = nil,
        onFlip: (() -> Void)? = nil,
        onPlayBTS: (() -> Void)? = nil,
        timestamp: String? = nil
    ) {
        self.large = large
        self.inset = inset
        self.insetWidth = insetWidth
        self.initialCorner = initialCorner
        self.onCornerChanged = onCornerChanged
        self.onTapInset = onTapInset
        self.onTapLarge = onTapLarge
        self.onDoubleTapLarge = onDoubleTapLarge
        self.onFlip = onFlip
        self.onPlayBTS = onPlayBTS
        self.timestamp = timestamp
        self._corner = State(initialValue: initialCorner)
    }

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
                GeometryReader { proxy in
                    insetLayer(inset, in: proxy.size)
                }
            }

            // Flip/time (leading) and BTS (trailing) are independent — both can show.
            HStack(spacing: Theme.Spacing.s) {
                if let timestamp {
                    ChromeTimePill(text: timestamp)
                } else if let onFlip {
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
        .onChange(of: initialCorner) { _, newValue in
            corner = newValue
        }
    }

    private var hasBottomChrome: Bool {
        timestamp != nil || onFlip != nil || onPlayBTS != nil
    }

    private func compositeChromeButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        ChromeIconButton(
            systemName: systemName,
            label: label,
            action: action
        )
    }

    @ViewBuilder
    private func insetLayer(_ inset: UIImage, in containerSize: CGSize) -> some View {
        let isRTL = layoutDirection == .rightToLeft
        let baseCenter = InsetPlacement.restingCenter(
            for: corner,
            in: containerSize,
            insetWidth: insetWidth,
            hasBottomChrome: hasBottomChrome,
            isRTL: isRTL
        )
        let proposedCenter = CGPoint(
            x: baseCenter.x + dragOffset.width,
            y: baseCenter.y + dragOffset.height
        )
        let clampedCenter = InsetPlacement.clampCenter(
            proposedCenter,
            insetWidth: insetWidth,
            in: containerSize
        )
        let half = insetWidth / 2

        ZStack(alignment: .topLeading) {
            Image(uiImage: inset)
                .resizable()
                .scaledToFill()
                .frame(width: insetWidth, height: insetWidth)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.inset)
                        .strokeBorder(Theme.Color.textPrimary, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.inset))
                .scaleEffect(isDragging ? 1.04 : 1.0)
                .shadow(
                    color: isDragging ? Theme.Color.canvas.opacity(0.4) : .clear,
                    radius: Theme.Spacing.s,
                    y: Theme.Spacing.xs
                )
                .offset(x: clampedCenter.x - half, y: clampedCenter.y - half)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let dist = hypot(value.translation.width, value.translation.height)
                            if dist >= Theme.Spacing.s {
                                if !isDragging {
                                    withAppAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                        isDragging = true
                                    }
                                }
                                dragOffset = value.translation
                            }
                        }
                        .onEnded { value in
                            let dist = hypot(value.translation.width, value.translation.height)
                            if isDragging || dist >= Theme.Spacing.s {
                                let projectedCenter = CGPoint(
                                    x: clampedCenter.x + value.predictedEndTranslation.width * 0.2,
                                    y: clampedCenter.y + value.predictedEndTranslation.height * 0.2
                                )
                                let target = InsetPlacement.nearestCorner(
                                    to: projectedCenter,
                                    in: containerSize,
                                    isRTL: isRTL
                                )
                                let changed = target != corner

                                withAppAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    corner = target
                                    dragOffset = .zero
                                    isDragging = false
                                }

                                if changed {
                                    if !UIAccessibility.isReduceMotionEnabled {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    }
                                    onCornerChanged?(target)
                                }
                            } else {
                                dragOffset = .zero
                                isDragging = false
                                onTapInset?()
                            }
                        }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Secondary photograph, positioned at \(corner.accessibilityName).")
                .accessibilityAction(named: "Move to next corner") {
                    cycleCorner(in: containerSize, isRTL: isRTL)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func cycleCorner(in containerSize: CGSize, isRTL: Bool) {
        let all = InsetCorner.allCases
        guard let idx = all.firstIndex(of: corner) else { return }
        let next = all[(idx + 1) % all.count]
        withAppAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            corner = next
        }
        if !UIAccessibility.isReduceMotionEnabled {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        onCornerChanged?(next)
    }
}
