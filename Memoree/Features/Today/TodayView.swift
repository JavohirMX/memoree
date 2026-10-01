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
    @State private var isConfirmingRecapture = false

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
        // Reload when the camera closes, not when this view appears.
        //
        // `refreshNow()` only re-reads `todayMoment` on a day rollover, so
        // without this the screen keeps whatever it had when it was created:
        // capture a moment, dismiss, and you are still looking at "It's time"
        // with a streak that never moved. Cancelling without capturing is
        // harmless — the reload finds the same state it already had.
        .onChange(of: isShowingCamera) { _, isShowing in
            guard !isShowing else { return }
            Task { await self.model?.reload() }
        }
        // A tapped reminder opens the camera — the tap is the intent (TRD §9).
        //
        // Checked on appear as well as on change, because a cold launch
        // delivers the tap *before* this observer is registered, and
        // `.onChange` only fires for changes that happen after it exists.
        // Reading the flag once on appearance is what makes a cold launch work;
        // the observer is what makes a tap while the app is already running.
        .task {
            presentCameraIfRequested()
        }
        .onChange(of: environment.pendingCameraRequest) { _, _ in
            presentCameraIfRequested()
        }
        .confirmationDialog(
            Self.recaptureTitle,
            isPresented: $isConfirmingRecapture,
            titleVisibility: .visible
        ) {
            Button("Capture again") { isShowingCamera = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.recaptureMessage)
        }
    }

    /// Opens the camera if a reminder was tapped, and clears the request.
    ///
    /// Consumption is what makes this idempotent: `TodayView` reappears every
    /// time the camera is dismissed, and a tap from twenty minutes ago should
    /// not throw the user back into the camera screen on their next visit.
    private func presentCameraIfRequested() {
        guard environment.pendingCameraRequest else { return }
        environment.consumeCameraRequest()
        isShowingCamera = true
    }

    private static let recaptureTitle = "Capture again?"

    /// Says the cost of the tap before the tap, not after.
    ///
    /// Re-capturing writes a second pair to Photos and replaces the archive
    /// row. The earlier pair stays in the camera roll — permanently, because
    /// Memoree holds **add-only** authorisation and physically cannot delete an
    /// asset it created (ADR-008). That is not a bug to be fixed later; it is
    /// the cost of the ownership thesis, and the user is entitled to know it
    /// before they commit rather than after.
    private static let recaptureMessage = """
        Today's moment will be replaced in your archive.

        The two photos already in your library stay there. Memoree never \
        deletes from Photos.
        """

    // MARK: - Content

    @ViewBuilder
    private func content(_ model: TodayViewModel) -> some View {
        VStack(spacing: 0) {
            header(model)

            if model.state.isCaptured {
                todayComposite(model)
                    .padding(.bottom, Theme.Spacing.xl)
            }

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

    // MARK: - Today's moment

    /// Today's pair, streamed back out of the user's own library.
    ///
    /// **Not tappable.** There is nowhere for it to go yet — the archive is
    /// Phase 6 — and a control that looks live and does nothing is a dead end
    /// (AGENTS.md §6). It carries an accessibility label instead, because two
    /// unlabelled images are worse than silence: they invite a tap that does
    /// nothing.
    ///
    /// Three states, and all of them are real: captured with both photographs
    /// present, captured with them deleted from Photos, and captured with the
    /// read still in flight.
    @ViewBuilder
    private func todayComposite(_ model: TodayViewModel) -> some View {
        if let images = model.todayImages {
            MomentComposite(
                large: images.large,
                inset: images.inset,
                insetWidth: 96
            )
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxHeight: 360)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(MomentComposite.accessibilityLabel)
        } else if model.todayMissingFromPhotos {
            Text("Today's photos are no longer in your library. The moment is still in your archive.")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.xxl)
                .background(Theme.Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        } else {
            // The read has not resolved. A flat placeholder is honest here; a
            // spinner would imply work that is usually a few milliseconds.
            Theme.Color.surface
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .frame(maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .accessibilityHidden(true)
        }
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
                // Re-capture goes through a confirmation, because it orphans the
                // previous pair in Photos and the user cannot get it back.
                if model.state.isCaptured {
                    isConfirmingRecapture = true
                } else {
                    isShowingCamera = true
                }
            }
            .accessibilityHint(model.state.isCaptured
                ? "Replaces today's moment. The earlier photos stay in your library."
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

            #if DEBUG
            // The camera reset hook, reachable (TRD §5.5, AGENTS.md §6).
            //
            // `mediaServicesWereReset` is silent and lethal: no error, no
            // callback, no log — the preview just freezes. It is also the most
            // common cause of "my camera app froze" in the field. A recovery path
            // only a test can reach is a recovery path nobody has watched work,
            // so this goes through the real service rather than a fake. Debug
            // builds only, so it cannot ship.
            Button("Reset camera services") {
                Task { await environment.simulateMediaServicesReset() }
            }
            .font(Theme.Typography.metadata)
            .foregroundStyle(Theme.Color.textTertiary)
            .padding(.top, Theme.Spacing.m)
            #endif
        }
        .opacity(model.summary.totalMoments > 0 || !model.notificationsAuthorized ? 1 : 0)
    }
}
