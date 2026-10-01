import SwiftUI

/// The daily moment window, as two sliders.
///
/// **Shared between onboarding and Settings, deliberately.** Onboarding had its
/// own copy inline, and the moment there was a first-run wizard and here it is
/// a permanent control — two implementations of the same preference is how they
/// drift apart, and this one already had a defect the copy would not have
/// shared (see `AppEnvironment.updateWindow`).
///
/// The sliders cannot cross and cannot leave less than an hour between them,
/// because a window narrower than that stops being random, and a window that
/// crosses midnight is not what either of these two callers means by it. The
/// bounds are enforced on the `Binding` rather than in the range, so an
/// impossible intermediate value is never even representable.
///
/// The commit is deferred to `onCommit` rather than fired on every drag step.
/// Two reasons, and the second is the real one: dragging fires dozens of times,
/// and each commit discards 44 `DayRecord`s and rebuilds the notification
/// horizon. A user nudging the slider would fire 44 deletions and 45
/// notification requests per second.
struct WindowPicker: View {

    /// The window being edited. Held by the caller so the screen can show a
    /// "saved" state and revert a discarded edit.
    @Binding var window: TimeWindow

    /// Called once the user lets go, or finishes a step.
    let onCommit: (TimeWindow) async -> Void

    /// Whether a commit is in flight, to keep the controls from being dragged
    /// underneath one.
    var isCommitting = false

    /// Smallest gap the user can leave between the two bounds.
    ///
    /// An hour, not `TimeWindow.minimumSpanSeconds`. The type permits a
    /// one-minute window, and nothing should ever construct one — a one-minute
    /// band is not "more random", it is a fixed time with extra steps, which is
    /// the opposite of what this control is for.
    private static let minimumGapMinutes = 60

    private static let stepMinutes = 30

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            bound(
                label: "From",
                minutes: window.startMinutes,
                range: 0...Double(max(Self.minimumGapMinutes, window.endMinutes - Self.minimumGapMinutes)),
                onChange: { minutes in
                    // A whole new `TimeWindow` rather than mutating one field.
                    // The stored properties are `let` on purpose — a window is a
                    // value, and an immutable one cannot end up half-updated. The
                    // initialiser validates, so the clamp below is belt and
                    // braces: it makes the *intent* legible, and it is what stops
                    // a slider at its range edge from producing a window the
                    // validator would have to widen behind the user's back.
                    let clamped = min(max(0, minutes), window.endMinutes - Self.minimumGapMinutes)
                    window = TimeWindow(
                        startMinutes: clamped,
                        endMinutes: window.endMinutes
                    )
                }
            )

            bound(
                label: "Until",
                minutes: window.endMinutes,
                range: Double(min(24 * 60, window.startMinutes + Self.minimumGapMinutes))...Double(24 * 60),
                onChange: { minutes in
                    let clamped = max(minutes, window.startMinutes + Self.minimumGapMinutes)
                    window = TimeWindow(
                        startMinutes: window.startMinutes,
                        endMinutes: min(clamped, 24 * 60)
                    )
                }
            )
        }
        .opacity(isCommitting ? 0.4 : 1)
        .disabled(isCommitting)
    }

    private func bound(
        label: String,
        minutes: Int,
        range: ClosedRange<Double>,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            HStack {
                Text(label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Text(TimeWindow.format(minutes: minutes))
                    .font(Theme.Typography.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Color.textPrimary)
                    // Announced as a bound, not as a bare number, so VoiceOver
                    // reads "From, 11:00" rather than just the digits.
                    .accessibilityLabel("\(label) \(TimeWindow.format(minutes: minutes))")
            }

            Slider(
                value: Binding(
                    get: { Double(minutes) },
                    set: { onChange(Int($0.rounded())) }
                ),
                in: range,
                step: Double(Self.stepMinutes)
            )
            .tint(Theme.Color.textPrimary)
        }
    }
}
