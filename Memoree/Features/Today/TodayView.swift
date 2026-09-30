import SwiftUI

/// The Today screen.
///
/// The whole app in one view: streak, countdown, and what can be done right now.
/// There is no feed, no discovery and no engagement — what remains after the
/// social layer is removed is this.
///
/// Copy follows one rule: state the facts, do not plead. `missed` is quiet —
/// no red, no guilt, no notification. The streak is a number that changed.
struct TodayView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var model: TodayViewModel?
    @State private var isShowingCamera = false

    var body: some View {
        // The lifecycle modifiers hang off the outermost container, never off
        // `content(model)`. Attaching them inside meant the task that *creates*
        // the model only ran once the model already existed — so it never ran,
        // and the screen stayed black. No unit test caught it; a screenshot did.
        ZStack {
            CanvasBackground()

            if let model {
                content(model)
            }
        }
        .task {
            let created = TodayViewModel(environment: environment)
            self.model = created
            created.startTicking()
            await created.reload()
        }
        .onDisappear { self.model?.stopTicking() }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraHostView { isShowingCamera = false }
                .environment(environment)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ model: TodayViewModel) -> some View {
        VStack(spacing: 0) {
            header(model)

            Spacer(minLength: Theme.Spacing.xl)

            primaryState(model)

            Spacer(minLength: Theme.Spacing.xl)

            if let countdown = model.countdown,
               model.state.allowsCapture || model.state.isAwaitingMoment {
                CountdownDisplay(text: countdown, isUrgent: model.countdownIsUrgent)
                    .padding(.bottom, Theme.Spacing.xl)
            }

            action(model)

            Spacer(minLength: Theme.Spacing.l)

            footer(model)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.l)
    }

    // MARK: - Header

    private func header(_ model: TodayViewModel) -> some View {
        HStack {
            StreakDisplay(streak: model.streak, longest: model.longestStreak)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Primary state

    @ViewBuilder
    private func primaryState(_ model: TodayViewModel) -> some View {
        switch model.state {
        case .scheduled:
            VStack(spacing: Theme.Spacing.s) {
                Text("Next moment at \(model.momentClockTime)")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Your phone will remind you. Nothing to do until then.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

        case .open:
            VStack(spacing: Theme.Spacing.s) {
                Text("It's time")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Two minutes. The scene, and you.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

        case .captured(let late, let lateBy):
            VStack(spacing: Theme.Spacing.m) {
                Text("Saved")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                if late {
                    LateBadge(text: "posted \(CountdownFormatter.lateDescription(from: lateBy)) late")
                    Text("Your photo is in your library. The streak did not grow.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Your photo is in your library.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }

        case .lateAvailable:
            VStack(spacing: Theme.Spacing.m) {
                LateBadge(text: "late")
                Text("The window has closed")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("You can still capture. The streak will not grow.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

        case .missed:
            VStack(spacing: Theme.Spacing.s) {
                Text("Nothing today")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textSecondary)
                Text("Tomorrow is another one.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textTertiary)
            }
        }
    }

    // MARK: - Action

    /// The shutter.
    ///
    /// Present only when capture is actually possible. The states that offer it
    /// are exactly `MomentState.allowsCapture` — so the FR-5 early-post refusal
    /// is structural: there is no affordance to disable, because the state
    /// resolver has already decided the window has not opened (TRD §8).
    ///
    /// Phase 5 shipped this as an `EmptyView()` on purpose. A button that looks
    /// live and does nothing is a dead end (AGENTS.md §6), so the affordance was
    /// withheld until something stood behind it. Phase 4 supplies that.
    @ViewBuilder
    private func action(_ model: TodayViewModel) -> some View {
        if model.state.allowsCapture {
            PrimaryButton(title: model.shutterTitle) {
                isShowingCamera = true
            }
            .accessibilityHint(model.state.isCaptured
                ? "Replaces today's moment"
                : "Opens the camera")
        }
    }

    // MARK: - Footer

    private func footer(_ model: TodayViewModel) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            MetadataRow(
                label: "Moment today",
                value: model.momentClockTime
            )
            if !model.notificationsAuthorized {
                MetadataRow(
                    label: "Reminders",
                    value: "off",
                    valueColor: Theme.Color.late
                )
            }
            if model.summary.totalMoments > 0 {
                MetadataRow(
                    label: "Captured",
                    value: "\(model.summary.totalMoments)"
                )
            }
        }
        .opacity(model.summary.totalMoments > 0 || !model.notificationsAuthorized ? 1 : 0)
    }
}
