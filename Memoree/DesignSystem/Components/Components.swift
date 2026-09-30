import SwiftUI

/// Memoree's shared components.
///
/// Black canvas, white type, amber for lateness only. Every colour and spacing
/// value comes from `Theme` — no literals in views (AGENTS.md §11).

/// The full-bleed white pill used for the single primary action.
///
/// There is no brand hue: white *is* the verb, with a black label inverted onto
/// it. The amber variant exists only for the open-window urgency state.
struct PrimaryButton: View {

    enum Style {
        case filled
        case amber
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
        case .filled, .amber: return foreground
        case .outlined: return .clear
        }
    }

    private var foreground: Color {
        switch style {
        case .filled: return Theme.Color.textPrimary
        case .amber: return Theme.Color.late
        case .outlined: return .clear
        }
    }

    private var labelColor: Color {
        switch style {
        case .filled, .amber: return Theme.Color.onAccent
        case .outlined: return Theme.Color.textPrimary
        }
    }
}

/// The countdown, in tabular figures so digits do not jitter once a second.
struct CountdownDisplay: View {

    let text: String
    var isUrgent: Bool = false

    var body: some View {
        Text(text)
            .font(Theme.Typography.display)
            .monospacedDigit()
            .foregroundStyle(isUrgent ? Theme.Color.late : Theme.Color.textPrimary)
            .contentTransition(.numericText())
            .animation(.default, value: text)
    }
}

/// The amber `late` badge. The only amber element in the app besides the
/// under-thirty-seconds countdown.
struct LateBadge: View {

    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.badge)
            .foregroundStyle(Theme.Color.onAccent)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Color.late)
            .clipShape(Capsule())
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
