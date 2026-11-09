import SwiftUI
import UIKit

/// The daily moment window picker with preset chips and stepper controls.
///
/// **Shared between onboarding and Settings, deliberately.** Onboarding had its
/// own copy inline, and the moment there was a first-run wizard and here it is
/// a permanent control — two implementations of the same preference is how they
/// drift apart, and this one already had a defect the copy would not have
/// shared (see `AppEnvironment.updateWindow`).
///
/// The bounds cannot cross and cannot leave less than an hour between them,
/// because a window narrower than that stops being random, and a window that
/// crosses midnight is not what either of these two callers means by it. The
/// bounds are enforced on the `Binding` rather than in the range, so an
/// impossible intermediate value is never even representable.
///
/// The commit is dispatched to `onCommit` when values change.
struct WindowPicker: View {

    /// The window being edited. Held by the caller so the screen can show a
    /// "saved" state and revert a discarded edit.
    @Binding var window: TimeWindow

    /// Called once the user lets go, or finishes a step.
    let onCommit: (TimeWindow) async -> Void

    /// Smallest gap the user can leave between the two bounds.
    ///
    /// An hour, not `TimeWindow.minimumSpanSeconds`. The type permits a
    /// one-minute window, and nothing should ever construct one — a one-minute
    /// band is not "more random", it is a fixed time with extra steps, which is
    /// the opposite of what this control is for.
    private static let minimumGapMinutes = 60

    private static let stepMinutes = 30

    struct Preset: Identifiable, Equatable {
        let id: String
        let title: String
        let window: TimeWindow
    }

    private static let presets: [Preset] = [
        Preset(id: "standard", title: "Standard", window: TimeWindow.default),
        Preset(id: "allday", title: "All Day", window: TimeWindow(startMinutes: 8 * 60, endMinutes: 23 * 60)),
        Preset(id: "daytime", title: "Daytime", window: TimeWindow(startMinutes: 9 * 60, endMinutes: 18 * 60)),
        Preset(id: "evening", title: "Evening", window: TimeWindow(startMinutes: 17 * 60, endMinutes: 23 * 60)),
    ]

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            headerSummary
            presetChips
            timelineVisualizer
            bound(
                label: "From",
                minutes: window.startMinutes,
                range: 0...Double(max(Self.minimumGapMinutes, window.endMinutes - Self.minimumGapMinutes)),
                onChange: { minutes in
                    let clamped = min(max(0, minutes), window.endMinutes - Self.minimumGapMinutes)
                    let updated = TimeWindow(
                        startMinutes: clamped,
                        endMinutes: window.endMinutes
                    )
                    window = updated
                    Task { await onCommit(updated) }
                }
            )

            bound(
                label: "Until",
                minutes: window.endMinutes,
                range: Double(min(24 * 60, window.startMinutes + Self.minimumGapMinutes))...Double(24 * 60),
                onChange: { minutes in
                    let clamped = max(minutes, window.startMinutes + Self.minimumGapMinutes)
                    let updated = TimeWindow(
                        startMinutes: window.startMinutes,
                        endMinutes: min(clamped, 24 * 60)
                    )
                    window = updated
                    Task { await onCommit(updated) }
                }
            )
        }
    }

    private var presetChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(Self.presets) { preset in
                    let isSelected = window.startMinutes == preset.window.startMinutes
                        && window.endMinutes == preset.window.endMinutes
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        window = preset.window
                        Task { await onCommit(preset.window) }
                    } label: {
                        Text(preset.title)
                            .font(Theme.Typography.metadata.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                            .padding(.horizontal, Theme.Spacing.m)
                            .frame(minHeight: Theme.Size.tapTarget)
                            .background(isSelected ? Theme.Color.divider : Theme.Color.surface)
                            .clipShape(Capsule())
                            .overlay {
                                if isSelected {
                                    Capsule().strokeBorder(Theme.Color.textSecondary, lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preset \(preset.title), \(preset.window.displayBounds)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Window presets")
    }

    private var headerSummary: some View {
        HStack {
            Text("Active span")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text("\(spanDescription) (\(TimeWindow.format(minutes: window.startMinutes)) – \(TimeWindow.format(minutes: window.endMinutes)))")
                .font(Theme.Typography.body)
                .monospacedDigit()
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Active window span \(spanDescription), from \(TimeWindow.format(minutes: window.startMinutes)) until \(TimeWindow.format(minutes: window.endMinutes))")
    }

    private var spanDescription: String {
        let spanMinutes = window.endMinutes - window.startMinutes
        let hours = spanMinutes / 60
        let minutes = spanMinutes % 60
        if minutes == 0 {
            return "\(hours)h"
        } else {
            return "\(hours)h \(minutes)m"
        }
    }

    private var timelineVisualizer: some View {
        VStack(spacing: Theme.Spacing.xs) {
            GeometryReader { proxy in
                let totalWidth = proxy.size.width
                let startFraction = CGFloat(window.startMinutes) / 1440.0
                let endFraction = CGFloat(window.endMinutes) / 1440.0
                let activeWidth = max(CGFloat.zero, (endFraction - startFraction) * totalWidth)
                let activeOffset = startFraction * totalWidth

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.Color.divider)
                        .frame(height: Theme.Spacing.s)

                    Capsule()
                        .fill(Theme.Color.textPrimary)
                        .frame(width: activeWidth, height: Theme.Spacing.s)
                        .offset(x: activeOffset)
                }
            }
            .frame(height: Theme.Spacing.s)

            HStack {
                Text("00:00")
                Spacer()
                Text("12:00")
                Spacer()
                Text("24:00")
            }
            .font(Theme.Typography.retakePill)
            .foregroundStyle(Theme.Color.textTertiary)
        }
        .accessibilityHidden(true)
        .padding(.bottom, Theme.Spacing.xs)
    }

    private func bound(
        label: String,
        minutes: Int,
        range: ClosedRange<Double>,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        let canDecrement = Double(minutes - Self.stepMinutes) >= range.lowerBound
        let canIncrement = Double(minutes + Self.stepMinutes) <= range.upperBound

        return HStack {
            Text(label)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()

            HStack(spacing: Theme.Spacing.s) {
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    let newMinutes = max(Int(range.lowerBound), minutes - Self.stepMinutes)
                    onChange(newMinutes)
                } label: {
                    Image(systemName: "minus")
                        .font(Theme.Typography.metadata.weight(.semibold))
                        .foregroundStyle(canDecrement ? Theme.Color.textPrimary : Theme.Color.textTertiary)
                        .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                        .background(Theme.Color.divider)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canDecrement)
                .accessibilityLabel("Decrease \(label) by 30 minutes")

                Text(TimeWindow.format(minutes: minutes))
                    .font(Theme.Typography.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Color.textPrimary)
                    .padding(.horizontal, Theme.Spacing.s)
                    .frame(minWidth: Theme.Size.shutter)
                    .frame(height: Theme.Size.tapTarget)
                    .background(Theme.Color.divider)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous))
                    .accessibilityLabel("\(label) \(TimeWindow.format(minutes: minutes))")

                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    let newMinutes = min(Int(range.upperBound), minutes + Self.stepMinutes)
                    onChange(newMinutes)
                } label: {
                    Image(systemName: "plus")
                        .font(Theme.Typography.metadata.weight(.semibold))
                        .foregroundStyle(canIncrement ? Theme.Color.textPrimary : Theme.Color.textTertiary)
                        .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                        .background(Theme.Color.divider)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canIncrement)
                .accessibilityLabel("Increase \(label) by 30 minutes")
            }
        }
    }
}
