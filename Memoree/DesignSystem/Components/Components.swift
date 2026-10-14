import SwiftUI
import UIKit

/// Memoree's shared components.
///
/// Black canvas, white type, one amber accent used sparingly (AGENTS.md §11).
/// Every colour and spacing value comes from `Theme` — no literals in views.

/// The full-bleed white pill used for the single primary action.
///
/// There is no brand hue: white *is* the verb, with a black label inverted onto
/// it.
struct PrimaryButton: View {

    enum Style {
        case filled
        case outlined
    }

    let title: String
    var style: Style = .filled
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.button)
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity)
                // **`minHeight`, not `height`.**
                //
                // A fixed 52pt on a `.headline` label clips the descenders, and
                // the button grew while the text did not. **Measured, not
                // assumed:** screenshots at every accessibility size show nothing
                // wrong through `accessibility-extra-large`, and at
                // `accessibility-extra-extra-large` the "p" of "Capture" is cut
                // off by the capsule's bottom edge — the descender sits exactly
                // on the boundary with zero padding, which is what clipping
                // looks like the instant before it is obvious.
                //
                // It was not guessed from a point size. The first version of this
                // comment claimed the damage started at `accessibility-x-large`
                // and that ~11pt of the title was lost; both were wrong, and a
                // screenshot at each category in turn is what replaced them.
                //
                // `minHeight` keeps the 52pt tap target at every size the design
                // was drawn at and grows with the label beyond it. The capsule
                // grows with it, so nothing is clipped and the shape holds.
                .frame(minHeight: Theme.Size.tapTargetComfortable)
                // Horizontal padding, for the same reason: `.headline` at an
                // accessibility size is wider than the label, and without this
                // it touches the capsule's edge.
                .padding(.horizontal, Theme.Spacing.m)
                .background(background)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }

    private var background: Color {
        switch style {
        case .filled: return Theme.Color.textPrimary
        case .outlined: return .clear
        }
    }

    private var labelColor: Color {
        switch style {
        case .filled: return Theme.Color.onAccent
        case .outlined: return Theme.Color.textPrimary
        }
    }
}

/// Streak display: flame and count.
///
/// A statistic, not a nag. No "don't break it!" copy, and no notification when
/// it breaks — the number is simply what it is (ADR-015).
struct StreakDisplay: View {

    let streak: Int
    var longest: Int?
    var isCapturedToday: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: (isCapturedToday && streak > 0) ? "flame.fill" : "flame")
                .scaledDisplayFont(20)
                .foregroundStyle(streak > 0 ? Theme.Color.textPrimary : Theme.Color.textTertiary)
            Text("\(streak)")
                .font(Theme.Typography.screenTitle)
                .monospacedDigit()
                .foregroundStyle(streak > 0 ? Theme.Color.textPrimary : Theme.Color.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            streak == 0
                ? "No current streak"
                : "Streak of \(streak) \(streak == 1 ? "day" : "days")"
        )
    }
}

/// A single labelled row for secondary information.
struct MetadataRow: View {

    let label: String
    let value: String
    var valueColor: Color = Theme.Color.textSecondary

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                stacked
            } else {
                row
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Two columns, below the accessibility sizes and only below them.
    ///
    /// **This was a `HStack` and a `Spacer`, unconditionally**, which is fine at
    /// 15pt and wrong at every accessibility size. In an `HStack` both texts are
    /// squeezed into a share of the width, so at AX5 the label got a fraction of
    /// the screen — too narrow for any single word, which is when iOS breaks a
    /// word *mid-word*: "Pho-tographs", "pho-tographed". The values did the same
    /// thing to themselves and wrapped into vertical stacks of digits.
    ///
    /// ## Two attempts that did not work, and why they are not here
    ///
    /// **`fixedSize` on the label.** Stopped the hyphenation and started
    /// clipping instead — "375 days in a row" ran off both edges. Worse than
    /// hyphenating, because a clipped digit is a *wrong number*.
    ///
    /// **`ViewThatFits(in: .horizontal)`.** The obvious idiomatic answer, and it
    /// worked on the Stats screen — until it was used on Today, where the row was
    /// chosen for labels that did not fit and truncated them to "Next mome…" and
    /// "Nothing to do u…". Inside a `ScrollView` the proposal it measures against
    /// is not the screen width, so its measurement is not the measurement that
    /// decides whether the row fits. **A layout that picks a branch from a
    /// measurement that does not hold is worse than no branch at all**, because it
    /// looks like it is handling the problem.
    ///
    /// `isAccessibilitySize` is the answer instead: it does not measure anything,
    /// so it cannot be wrong about a width it was never shown.
    private var row: some View {
        HStack(alignment: .firstTextBaseline) {
            labelText
            Spacer(minLength: Theme.Spacing.m)
            valueText
        }
    }

    /// One column, so the label gets the whole width to wrap on.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            labelText
            valueText
        }
    }

    private var labelText: some View {
        Text(label)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Color.textSecondary)
    }

    private var valueText: some View {
        Text(value)
            .font(Theme.Typography.body)
            .monospacedDigit()
            .foregroundStyle(valueColor)
    }
}

/// The plain black screen background every root uses.
struct CanvasBackground: View {
    var body: some View {
        Theme.Color.canvas
            .ignoresSafeArea()
    }
}

// MARK: - Liquid Glass (iOS 27)

/// Adopts Apple's iOS 27 Liquid Glass design language with backward compatibility.
///
/// In iOS 26 and iOS 27, Apple introduced the Liquid Glass visual material system.
/// Interactive controls use `.buttonStyle(.glass)` with `.buttonBorderShape(.circle)`
/// to produce dynamic optical lensing, light reflections, and fluid touch interactions.
struct LiquidGlassCircleModifier: ViewModifier {

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
        } else {
            content
                .buttonStyle(.pressDip)
                .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                .background(Circle().fill(Theme.Color.surface.opacity(0.85)))
                .overlay {
                    Circle().strokeBorder(Theme.Color.divider, lineWidth: 1)
                }
                .contentShape(Circle())
        }
    }
}

/// A container that groups adjacent Liquid Glass elements, enabling cohesive
/// optical blending on iOS 26/27+ and standard layout on earlier iOS versions.
struct LiquidGlassGroup<Content: View>: View {

    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                content()
            }
        } else {
            content()
        }
    }
}

/// The standard navigation bar Back button used across sheets and navigation views.
///
/// Features a leading chevron and "Back" label, matching native iOS navigation style.
struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "chevron.left")
                    .font(Theme.Typography.body.weight(.semibold))
                Text("Back")
                    .font(Theme.Typography.body)
            }
            .foregroundStyle(Theme.Color.textPrimary)
        }
        .accessibilityLabel("Back")
    }
}

/// A compact circular icon over a photograph, with a HIG-sized hit region.
///
/// The drawn chrome stays small so it does not cover the image; the tappable
/// region is always at least `Theme.Size.tapTarget` (44pt). Used for composite
/// flip/BTS chrome and BTS play/mute.
struct ChromeIconButton: View {

    let systemName: String
    let label: String
    var font: Font = Theme.Typography.retakePill
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: systemName)
                .font(font)
                .foregroundStyle(Theme.Color.textPrimary)
                .padding(Theme.Spacing.s)
                .background(Theme.Color.canvas.opacity(0.6))
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(Theme.Color.divider, lineWidth: 1)
                }
                // Visual stays compact; hit region meets the 44pt floor (HIG).
                .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                .contentShape(Circle())
        }
        .buttonStyle(.pressDip)
        .accessibilityLabel(label)
    }
}

/// A compact translucent pill displaying capture time over a photograph.
///
/// Matches the semi-transparent chrome aesthetic of `ChromeIconButton`.
struct ChromeTimePill: View {

    let text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "clock")
                .font(Theme.Typography.retakePill)
            Text(text)
                .font(Theme.Typography.metadata)
        }
        .foregroundStyle(Theme.Color.textPrimary)
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Color.canvas.opacity(0.6))
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.Color.divider, lineWidth: 1)
        }
        .accessibilityLabel("Captured at \(text)")
    }
}

extension View {

    /// Applies Apple's native Liquid Glass circular styling to an interactive control.
    func liquidGlassCircle() -> some View {
        modifier(LiquidGlassCircleModifier())
    }

    /// Expands a smaller drawn control to Apple's minimum hit region.
    ///
    /// The visual size is unchanged; only the tappable frame grows. Matches
    /// `Theme.Size.zoomButton`'s documented "34 visual, 44 target" pattern.
    func expandedCircularHitTarget(
        _ size: CGFloat = Theme.Size.tapTarget
    ) -> some View {
        self
            .frame(width: size, height: size)
            .contentShape(Circle())
    }
}

