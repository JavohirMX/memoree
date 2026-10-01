import SwiftUI

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
                .frame(height: 52)
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

/// A time, in tabular figures so the digits do not jitter once a second.
///
/// Used for the countdown to the *reminder*, which is shown only when
/// notifications are off (ADR-024). There is deliberately no "urgent" state:
/// the amber variant existed to mark the last thirty seconds of a window that
/// no longer closes, and a number that changed colour as it approached a
/// deadline nobody had would be decoration with consequences attached.
struct CountdownDisplay: View {

    let text: String

    var body: some View {
        Text(text)
            // Not `.font(...)`: the 64pt numeral has no text style, so it is
            // applied as a scaled modifier. See `Theme.Typography.displaySize`.
            .scaledDisplayFont(Theme.Typography.displaySize)
            .monospacedDigit()
            .foregroundStyle(Theme.Color.textPrimary)
            // **A `HH:MM:SS` string cannot wrap, so it is truncated instead** —
            // "4:53:…" is a countdown to nothing. `minimumScaleFactor` lets the
            // font give way rather than the digits, which is the whole point: the
            // number is the number, and a smaller complete one beats a larger
            // broken one.
            //
            // This is the one place in the app where the text shrinks rather than
            // the layout growing, and it is a deliberate exception to the cap in
            // `ScaledDisplayFont`: the cap sets how large it may *try* to be, and
            // this is what happens when even that is too large for the width.
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .contentTransition(.numericText())
            .appAnimation(text)
    }
}

/// Streak display: flame and count.
///
/// A statistic, not a nag. No "don't break it!" copy, and no notification when
/// it breaks — the number is simply what it is (ADR-015).
struct StreakDisplay: View {

    let streak: Int
    var longest: Int?

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "flame.fill")
                    // Scales with the number beside it, for the same reason as the
                    // Stats screen's flame: 20 at the default setting, and it does
                    // not stay 20 while the streak's `.title2` becomes a wall.
                    .scaledDisplayFont(20)
                    .foregroundStyle(streak > 0 ? Theme.Color.textPrimary : Theme.Color.textTertiary)
                Text("\(streak)")
                    .font(Theme.Typography.screenTitle)
                    .monospacedDigit()
                    .foregroundStyle(streak > 0 ? Theme.Color.textPrimary : Theme.Color.textTertiary)
            }

            Text(streak == 1 ? "day in a row" : "days in a row")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textSecondary)

            if let longest, longest > streak {
                Text("best \(longest)")
                    .font(Theme.Typography.retakePill)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
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
