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
            .font(Theme.Typography.display)
            .monospacedDigit()
            .foregroundStyle(Theme.Color.textPrimary)
            .contentTransition(.numericText())
            .animation(.default, value: text)
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
                    .font(.system(size: 20))
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

    var body: some View {
        HStack {
            Text(label)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(value)
                .font(Theme.Typography.body)
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The plain black screen background every root uses.
struct CanvasBackground: View {
    var body: some View {
        Theme.Color.canvas
            .ignoresSafeArea()
    }
}
