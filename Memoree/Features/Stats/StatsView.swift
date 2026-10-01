import SwiftUI

/// The streak history — in place of BeReal's Memories calendar.
///
/// Reached by tapping the streak on the Today screen, which is deliberate: the
/// header already carries three things and a fourth icon would be one too many,
/// but "tap the number you care about to see its history" needs no explanation.
///
/// **No congratulation and no encouragement.** There is no "keep it up", no
/// milestone confetti, and nothing that reacts to the number. The app deleted the
/// Streak Restore paywall and with it the entire reason to perform a streak
/// (ADR-015); a screen that cheerleads is the same instinct with a smiley face.
/// The numbers are the reward.
struct StatsView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var model: StatsViewModel?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let model {
                    content(model)
                }
            }
            // Background rather than a sibling: a `CanvasBackground()` *above* a
            // `ScrollView` claims vertical space only it wants and pushes the
            // content down. Found by screenshotting Settings, which had it.
            .background(CanvasBackground())
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Lifecycle on the outermost container, never on the `if let model`
        // branch — a `.task` there only runs once the model exists, so it never
        // runs. That black-screened the Today screen in Phase 5.
        .task {
            let created = StatsViewModel(environment: environment)
            model = created
            created.load()
        }
    }

    @ViewBuilder
    private func content(_ model: StatsViewModel) -> some View {
        if model.isEmpty {
            empty
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                headline(model)
                figures(model)
                history(model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.xl)
        }
    }

    /// The current streak, large, and nothing else competing with it.
    private func headline(_ model: StatsViewModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Image(systemName: "flame.fill")
                    // Scaled, and anchored to the same `.largeTitle` the numeral
                    // uses, so the two stay in proportion. At the default setting
                    // this is 28 — unchanged — and at AX5 it grows with the number
                    // beside it instead of sitting there like a period.
                    .scaledDisplayFont(28)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("\(model.summary.currentStreak)")
                    // Scales with the user's text-size setting. `Typography` has
                    // no 56pt text style, so it is the modifier's job — see
                    // `ScaledFont.swift`.
                    .scaledDisplayFont(56)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            Text(model.currentStreakDescription + " in a row")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            model.summary.currentStreak == 0
                ? "No current streak"
                : "Streak of \(model.currentStreakDescription)"
        )
    }

    /// Every other number, as rows.
    ///
    /// `MetadataRow` rather than bespoke components, because the archive detail
    /// already uses it and two row styles in one app is one more thing to keep
    /// consistent. Amber appears **nowhere** in this screen: with the late badge
    /// gone there is nothing to warn about, and the single reserved use is a
    /// declined permission (ADR-025).
    private func figures(_ model: StatsViewModel) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            MetadataRow(label: "Photographs", value: "\(model.summary.totalMoments)")

            // The one place the window's significance is visible at all. See the
            // view model's note on why it is phrased as a count and not a
            // percentage.
            MetadataRow(label: "Timing", value: model.onTimeDescription)

            MetadataRow(label: "Days photographed", value: model.daysCapturedDescription)
            MetadataRow(label: "Longest run", value: model.longestStreakDescription)

            if let retakes = model.retakeDescription {
                MetadataRow(label: "Retakes", value: retakes)
            }
            if let hour = model.busiestHourDescription {
                MetadataRow(label: "Most often at", value: hour)
            }
            if model.summary.missedDays > 0 {
                MetadataRow(label: "Days", value: model.missedDescription)
            }
        }
    }

    /// The recent run of days, newest first.
    ///
    /// **A list, not a calendar.** A calendar grid would be a mostly-empty
    /// month of grey squares with a handful of marks, and it would have to answer
    /// "what does an empty square mean" — did you miss it, or photograph
    /// off-window, or has the day not happened yet? Three states, one glyph, and
    /// a legend. A row per day answers none of that: it is a photograph or it
    /// is not there.
    ///
    /// Capped at thirty. A user with a year of history does not need 365 rows to
    /// learn that they photograph most days, and rendering all of them is the
    /// archive's job.
    private func history(_ model: StatsViewModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Recent")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            VStack(spacing: 0) {
                ForEach(Array(model.days.prefix(Self.historyLimit).enumerated()), id: \.element.id) { index, moment in
                    if index > 0 {
                        Theme.Color.divider
                            .frame(height: 1)
                    }
                    historyRow(moment)
                }
            }
        }
    }

    private static let historyLimit = 30

    private func historyRow(_ moment: MomentFacts) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Text(moment.day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textPrimary)

            Spacer()

            Text(moment.capturedAt.formatted(date: .omitted, time: .shortened))
                .font(Theme.Typography.metadata)
                .monospacedDigit()
                .foregroundStyle(Theme.Color.textSecondary)

            if moment.retakeCount > 0 {
                Text("\(moment.retakeCount)×")
                    .font(Theme.Typography.retakePill)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .accessibilityLabel("\(moment.retakeCount) retakes")
            }
        }
        .padding(.vertical, Theme.Spacing.m)
        .accessibilityElement(children: .combine)
    }

    /// Nothing captured yet.
    private var empty: some View {
        VStack(spacing: Theme.Spacing.l) {
            Text("Nothing yet")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Text("""
                Once you have taken a photograph or two, this is where the \
                numbers live.
                """)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
