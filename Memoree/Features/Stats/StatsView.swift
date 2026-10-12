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
    @State private var selectedMoment: MomentFacts?
    @State private var isConfirmingDelete = false
    @State private var isShowingDeleteError = false

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
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { dismiss() }
                }
            }
        }
        // Same confirm-then-tombstone path as Archive: `onDelete` only opens the
        // dialog; the store write happens after the user confirms. The sheet also
        // needs `AppEnvironment` — without it photo/BTS loading inside detail
        // has nowhere to go.
        .sheet(item: $selectedMoment) { moment in
            MomentDetailView(
                moment: moment,
                moments: model?.days ?? [moment],
                onDelete: { isConfirmingDelete = true }
            )
            .environment(environment)
        }
        .confirmationDialog(
            Self.deleteTitle,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Remove from archive", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.deleteMessage)
        }
        .alert(
            "Couldn’t remove from archive",
            isPresented: $isShowingDeleteError
        ) {
            Button("OK", role: .cancel) {
                model?.clearDeleteError()
            }
        } message: {
            Text(model?.deleteError ?? "Please try again.")
        }
        .onChange(of: model?.deleteError) { _, newValue in
            isShowingDeleteError = newValue != nil
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

    private static let deleteTitle = "Remove from archive?"

    private static let deleteMessage = """
        Your streak will be recalculated without it.

        The two photos stay in your library. Memoree never deletes from Photos.
        """

    private func deleteSelected() {
        guard let model, let selectedMoment else { return }
        model.delete(selectedMoment)
        // Only dismiss detail when the tombstone landed — a failure leaves the
        // sheet open so the user can retry (same as Archive).
        if model.deleteError == nil {
            self.selectedMoment = nil
        }
    }

    @ViewBuilder
    private func content(_ model: StatsViewModel) -> some View {
        if model.isEmpty {
            empty
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                heroStreakCard(model)
                rhythmCard(model)
                activityCard(model)
                recentHistoryCard(model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.l)
        }
    }

    // MARK: - Hero Streak Card

    /// The current streak, longest run, and recent 14-day habit continuity strip.
    private func heroStreakCard(_ model: StatsViewModel) -> some View {
        StatCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                        Image(systemName: (model.isStreakActiveToday && model.summary.currentStreak > 0) ? "flame.fill" : "flame")
                            .scaledDisplayFont(28)
                            .foregroundStyle(model.summary.currentStreak > 0 ? Theme.Color.textPrimary : Theme.Color.textTertiary)
                        Text("\(model.summary.currentStreak)")
                            .scaledDisplayFont(48)
                            .monospacedDigit()
                            .foregroundStyle(Theme.Color.textPrimary)
                    }
                    Text(model.streakStatusDescription)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                    Text("Longest run")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textSecondary)
                    Text("\(model.summary.longestStreak)")
                        .font(Theme.Typography.screenTitle)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text(model.longestStreakDescription)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                model.summary.currentStreak == 0
                    ? "No current streak, longest run \(model.longestStreakDescription)"
                    : "Streak of \(model.currentStreakDescription), longest run \(model.longestStreakDescription)"
            )

            Theme.Color.divider
                .frame(height: 1)

            // 14-day habit continuity strip
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack(spacing: Theme.Spacing.s) {
                    ForEach(model.habitDays) { item in
                        Circle()
                            .fill(item.isCaptured ? Theme.Color.textPrimary : Theme.Color.divider)
                            .frame(width: Theme.Size.habitDotSize, height: Theme.Size.habitDotSize)
                            .overlay {
                                if item.isToday && !item.isCaptured {
                                    Circle()
                                        .strokeBorder(Theme.Color.textSecondary, lineWidth: 1)
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Text("14 days ago")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textTertiary)
                    Spacer()
                    Text("Today")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Last 14 days activity strip")
        }
    }

    // MARK: - Capture Rhythm Card

    /// 24-hour minimalist capture distribution.
    private func rhythmCard(_ model: StatsViewModel) -> some View {
        StatCard {
            Text("Rhythm")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            // Minimalist 24-hour bars
            HStack(alignment: .bottom, spacing: Theme.Spacing.xs) {
                ForEach(model.hourlyDistribution, id: \.hour) { bin in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(bin.count > 0 ? Theme.Color.textPrimary : Theme.Color.divider)
                        .frame(
                            width: Theme.Size.rhythmBarWidth,
                            height: max(1, bin.ratio * Theme.Size.rhythmBarMaxHeight)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                model.busiestHourDescription != nil
                    ? "Hourly capture rhythm. Most captures at \(model.busiestHourDescription!)"
                    : "Hourly capture rhythm"
            )

            HStack {
                Text("00")
                Spacer()
                Text("06")
                Spacer()
                Text("12")
                Spacer()
                Text("18")
                Spacer()
                Text("24")
            }
            .font(Theme.Typography.metadata)
            .foregroundStyle(Theme.Color.textTertiary)

            if let hour = model.busiestHourDescription {
                Theme.Color.divider
                    .frame(height: 1)
                MetadataRow(label: "Most often at", value: hour)
            }
        }
    }

    // MARK: - Activity Card

    /// Memory aggregates and journaling metrics.
    private func activityCard(_ model: StatsViewModel) -> some View {
        StatCard {
            Text("Activity")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            VStack(spacing: Theme.Spacing.s) {
                MetadataRow(label: "Photographs", value: "\(model.summary.totalMoments)")
                MetadataRow(label: "Days photographed", value: model.daysCapturedDescription)

                if let consistency = model.consistencyDescription {
                    MetadataRow(label: "Consistency", value: consistency)
                }
                if let first = model.firstMemoryDescription {
                    MetadataRow(label: "First photograph", value: first)
                }
                if let notes = model.notesDescription {
                    MetadataRow(label: "Notes written", value: notes)
                }
                if let retakes = model.retakeDescription {
                    MetadataRow(label: "Retakes", value: retakes)
                }
                if let clips = model.btsDescription {
                    MetadataRow(label: "Behind the Scenes", value: clips)
                }
                if model.summary.missedDays > 0 {
                    MetadataRow(label: "Days", value: model.missedDescription)
                }
            }
        }
    }

    // MARK: - Recent History Card

    private static let historyLimit = 30

    /// Interactive list of past moments opening full detail view on tap.
    private func recentHistoryCard(_ model: StatsViewModel) -> some View {
        StatCard {
            Text("Recent")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            VStack(spacing: 0) {
                ForEach(Array(model.days.prefix(Self.historyLimit).enumerated()), id: \.element.id) { index, moment in
                    if index > 0 {
                        Theme.Color.divider
                            .frame(height: 1)
                    }
                    Button {
                        selectedMoment = moment
                    } label: {
                        historyRow(moment)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func historyRow(_ moment: MomentFacts) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Text(moment.day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textPrimary)

            if let note = moment.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "note.text")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .accessibilityLabel("Has note")
            }

            if moment.hasBTS {
                Image(systemName: "video.fill")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .accessibilityLabel("Has video")
            }

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

            Image(systemName: "chevron.right")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textTertiary)
        }
        .padding(.vertical, Theme.Spacing.m)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Empty State

    /// Nothing captured yet.
    ///
    /// Matches Archive's quieter empty treatment: an icon, a short title, and
    /// thesis copy — not an apology for being empty.
    private var empty: some View {
        VStack(spacing: Theme.Spacing.l) {
            Image(systemName: "number")
                .scaledDisplayFont(Theme.Size.iconStandalone, weight: .regular)
                .foregroundStyle(Theme.Color.textTertiary)
                .accessibilityHidden(true)
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

// MARK: - Card Container

/// Elevated dark container card for statistics sections.
private struct StatCard<Content: View>: View {

    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            content()
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}
