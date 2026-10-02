import SwiftUI

/// The Today screen.
///
/// The whole app in one view: streak, what is true right now, and the shutter.
/// There is no feed, no discovery and no engagement — what remains after the
/// social layer is removed is this.
///
/// Copy follows one rule: state the facts, do not plead. Nothing here mentions
/// the streak having failed, because nothing on screen is allowed to know
/// whether it did (ADR-023). The streak is a number that changed, or did not.
struct TodayView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var model: TodayViewModel?
    @State private var isShowingCamera = false
    @State private var isConfirmingRecapture = false
    @State private var isShowingSettings = false
    @State private var isShowingArchive = false
    @State private var isShowingStats = false

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
        // Sheets, not pushes. The Today screen is the app's root and the only
        // thing it shows, so there is no navigation stack to push onto — and
        // wrapping each destination in its own `NavigationStack` is what gives
        // them a title and a dismiss button without inventing a hierarchy the
        // product does not have.
        // Settings is a **full-screen cover, not a sheet**, and the reason is
        // one a screenshot settled.
        //
        // It shipped as a sheet and rendered as iOS presents sheets by default:
        // the `.medium` detent, about half the screen. `.presentationDetents
        // ([.large])` was tried in both places a modifier can go — on the
        // `NavigationStack` inside `SettingsView`, and on the content at the
        // `.sheet` — and was **silently ignored both times**. The drag indicator
        // appeared and the sheet stayed at `.medium`, which is the worst kind of
        // failure: evidence the modifier was applied, and no effect from it.
        //
        // Rather than keep fighting it, the screen was made what it actually is.
        // Four sections of real content with a title and a Done button is a task,
        // not a peek — and a full-screen cover has no detent to get wrong. It
        // also matches the camera, which is already a full-screen cover, so there
        // is one convention rather than two.
        //
        // The archive stays a sheet. A grid you flick through and dismiss is
        // exactly what a sheet is for.
        .fullScreenCover(isPresented: $isShowingSettings) {
            SettingsView()
                .environment(environment)
        }
        // Stats is a full-screen cover for the same reason Settings is: it is a
        // screen with a title and a Done button, not a peek.
        .fullScreenCover(isPresented: $isShowingStats) {
            StatsView()
                .environment(environment)
        }
        .sheet(isPresented: $isShowingArchive) {
            ArchiveView()
                .environment(environment)
                // Explicit rather than left to the default, for the same reason
                // as Settings: a grid you have to drag up to fill is a grid that
                // looks broken.
                .presentationDetents([.large])
        }
        .onAppear {
            // Development affordance, open a screen at launch so its first frame
            // can be looked at without a finger on the phone.
            //
            // Exists because the alternative is a blind screen. Two defects in
            // this codebase were invisible to every test and obvious in a
            // screenshot — a `.task` attached to a branch that only renders once
            // its model exists (black screen, Phase 5), and a slider editing a
            // SwiftData managed object mid-gesture. `simctl` cannot tap, so
            // without this there is no way to see a new screen at all short of a
            // human holding the device.
            //
            //   -MemoreeOpen archive
            //   -MemoreeOpen settings
            //   -MemoreeOpen stats
            //
            // The destination is the *next* argument, not part of this one: a
            // command line is a list of separate strings, so
            // `simctl launch … -MemoreeOpen archive` arrives as two entries and
            // parsing the name out of the flag finds nothing. The first version
            // did exactly that and silently did nothing, which is the worst
            // possible failure for a diagnostic — it looks like the screen is
            // broken rather than the flag.
            //
            // **`#if DEBUG`, and it was missing.** The comment above said
            // "DEBUG-only" and the code was not — the whole block was compiled
            // into release builds, where it reads `ProcessInfo.arguments` on
            // every appearance and finds nothing. Inert, yes, and inert code in a
            // shipping binary is still code that ships: a launch argument nobody
            // expects to work, reachable from a scheme, on a user's device.
            #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                guard let flag = arguments.firstIndex(of: "-MemoreeOpen"),
                      arguments.indices.contains(flag + 1)
                else { return }

                switch arguments[flag + 1] {
                case "archive": isShowingArchive = true
                case "settings": isShowingSettings = true
                case "stats": isShowingStats = true
                default: break
                }
            #endif
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

    /// Opens the archive.
    ///
    /// No "start at today" parameter, and that is worth noting because there was
    /// one. The grid is newest-first, so a moment captured today is already its
    /// first cell — tapping the composite lands on it for free. An earlier
    /// version threaded a `DayIdentifier` through the environment to scroll
    /// there, which was thirty lines arranging to be a no-op.
    private func openArchive() {
        isShowingArchive = true
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

            // **The shutter comes before the countdown.**
            //
            // It was the other way round, and it was backwards. The countdown
            // read `05:18` at 64pt — the largest thing on the screen after the
            // streak — directly above a 52pt button. The largest element was
            // reporting a fact and the smallest was offering the only action, so
            // the screen's visual hierarchy said "watch the clock" when what it
            // meant was "you can capture now".
            //
            // That inverts ADR-023 as well. The whole point of the change was
            // that no moment is late, so a big ticking number above the shutter
            // reads as pressure to act *now* — which the product explicitly does
            // not want, since capturing whenever you like is the supported
            // behaviour. The countdown is still here (ADR-024: when
            // notifications are off it is the only way the user learns when the
            // moment was), but it is a footnote under the button rather than a
            // countdown above it. Nothing is hidden; the emphasis is what moved.
            action(model)

            if model.showsMomentTime,
               let remaining = model.timeUntilMoment,
               remaining > 0 {
                CountdownDisplay(text: CountdownFormatter.string(fromSeconds: remaining))
                    .padding(.top, Theme.Spacing.xl)
            }

            Spacer(minLength: Theme.Spacing.l)

            footer(model)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.l)
        // The one structural concession on this screen, and it is a layout one
        // rather than a font one.
        //
        // Below the accessibility sizes this column centres itself with
        // `Spacer(minLength:)` on either side of the state copy. When the content
        // is taller than the screen — at an accessibility text size, or in
        // landscape, where the viewport is short — the column overflows, and
        // because a `VStack` centres its overflowing content the overflow goes off
        // **both** ends at once: "Next moment at" read "Next mome…" and the streak's
        // "375" was sliced through by the status bar.
        //
        // Scrolling cannot fix a `VStack` that centres. Replacing the layout when
        // it cannot fit is what can, and it costs nothing at the sizes and widths
        // where the design was drawn. Landscape is the case that made this a
        // general rule rather than an accessibility one: a landscape phone cannot
        // fit this column, and what falls off the bottom is the shutter.
        .scrollableWhenItCannotFit()
    }

    // MARK: - Header

    /// Streak on the left, the two things you can go somewhere on the right.
    ///
    /// **The streak is tappable and opens Stats.** The header already carries
    /// three things, and a fourth icon would be one too many — but the number the
    /// user cares about is the obvious door to its own history, and "tap the
    /// number to see the numbers" needs no explanation.
    ///
    /// The archive icon is present even with no moments, and stays greyed rather
    /// than disappearing. A control that appears on first use is a control the
    /// user has to discover by having already succeeded — and the empty archive
    /// is the screen that explains what the app is for.
    private func header(_ model: TodayViewModel) -> some View {
        HStack(alignment: .top) {
            Button {
                isShowingStats = true
            } label: {
                StreakDisplay(streak: model.streak, longest: model.longestStreak)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                model.streak == 0
                    ? "No current streak"
                    : "Streak of \(model.streakDescription)"
            )
            .accessibilityHint("Opens your statistics")

            Spacer()

            Button {
                isShowingArchive = true
            } label: {
                Image(systemName: "square.grid.3x3")
                    // `.scaledDisplayFont`, not a fixed `.system(size:)`. A symbol's
                    // glyph size does not follow Dynamic Type on its own, so the
                    // icon stayed 20pt while the streak beside it grew to 140.
                    .scaledDisplayFont(Theme.Size.headerIcon, weight: .regular)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.summary.totalMoments == 0)
            .opacity(model.summary.totalMoments == 0 ? 0.35 : 1)
            .accessibilityLabel("Archive")
            .accessibilityHint(model.summary.totalMoments == 0
                ? "No moments yet"
                : "Shows every moment you have captured")

            Button {
                isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .scaledDisplayFont(Theme.Size.headerIcon, weight: .regular)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: Theme.Size.tapTarget, height: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Today's moment

    /// Today's pair, streamed back out of the user's own library.
    ///
    /// **Tappable, and goes to today's moment in the archive.** It was
    /// deliberately not tappable while there was no archive to open — a control
    /// that looks live and does nothing is a dead end (AGENTS.md §6) — and that
    /// is no longer the situation. The navigation target is today's row rather
    /// than the top of the grid, because the user's reason for tapping the
    /// photograph on this screen is to look at *this* photograph.
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
                insetWidth: Theme.Size.insetStandard
            )
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxHeight: Theme.Size.todayCompositeMaxHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Color.divider, lineWidth: 1)
            }
            .onTapGesture { openArchive() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CompositeAccessibility.label)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens today's moment in your archive")
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
                .frame(maxHeight: Theme.Size.todayCompositeMaxHeight)
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
                // The time is a secret unless notifications are off (ADR-024).
                // With them on, the notification is the alert and naming the
                // hour here would spend the surprise for nothing — the clock and
                // the notification are the same information twice.
                Text(model.showsMomentTime
                    ? "Next moment at \(model.momentClockTime)"
                    : "Memoree will ask you once today")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(model.showsMomentTime
                    ? "Nothing to do until then — but you can capture whenever you like."
                    : "Your phone will remind you. Nothing to do until then.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

        case .open:
            VStack(spacing: Theme.Spacing.s) {
                Text("It's time")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                // A duration, not a deadline. Nothing here counts down and
                // nothing is lost when it elapses — the two minutes decide
                // whether this photograph grows the streak, and that is the
                // whole of what they now do (ADR-023).
                Text("Two minutes. The scene, and you.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

        case .captured:
            VStack(spacing: Theme.Spacing.m) {
                Text("Saved")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                // No late badge, and no sentence about the streak.
                //
                // Both existed until ADR-023, and both said the same thing
                // twice: this photo was outside the window, and that is why your
                // streak did not grow. The decision was to say neither — an
                // off-window moment looks exactly like an on-time one, and the
                // streak simply does not move. `MomentState.captured` carries no
                // lateness, so this view *cannot* render the badge even by
                // accident.
                Text("Your photo is in your library.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

        case .windowPassed:
            VStack(spacing: Theme.Spacing.s) {
                Text("Today's moment has passed")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                // The same information `scheduled` gives, from the other side.
                // No amber, no "late", and nothing about what it cost — the two
                // minutes were the only thing that ended, and the streak is
                // untouched either way (ADR-023).
                //
                // The time is not printed here even with notifications off: a
                // moment that has already been and gone is history, and ADR-024
                // already stopped showing it.
                Text("You can still photograph whenever you like.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Action

    /// The shutter.
    ///
    /// **Unconditional since ADR-023.** It used to render only when
    /// `MomentState.allowsCapture` was true, which was false for `scheduled` —
    /// so before your moment there was no button at all. That was the FR-5
    /// early-post refusal, built structurally rather than as a disabled
    /// control, and it was answering the wrong question: the app's own
    /// onboarding promised you could photograph whenever you liked.
    ///
    /// There is no state in which this is absent and no permission behind it.
    /// Capture is allowed at any time on any day; whether the photograph counts
    /// is a different question, and one the screen is not allowed to answer.
    ///
    /// Re-capture goes through a confirmation, because it orphans the previous
    /// pair in Photos and the user cannot get it back.
    private func action(_ model: TodayViewModel) -> some View {
        PrimaryButton(title: model.shutterTitle) {
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

    // MARK: - Footer

    private func footer(_ model: TodayViewModel) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            // Shown only when the time is being shown at all, and only while it
            // still lies ahead. After the moment has passed it is history, and
            // repeating it is noise (ADR-024).
            if model.showsMomentTime, model.timeUntilMoment != nil {
                MetadataRow(
                    label: "Moment today",
                    value: model.momentClockTime
                )
            }
            // "Reminders off" now does two jobs: it reports a missing
            // permission, and it explains why a clock is visible at all. Same
            // copy, different reason — which is worth checking reads correctly
            // beside the rows above it. It is also the app's only use of the
            // amber accent (ADR-025), which is why it is worth the colour: a
            // permission the user declined and can only restore in the system
            // Settings app is the one thing here worth flagging.
            if !model.notificationsAuthorized {
                MetadataRow(
                    label: "Reminders",
                    value: "off",
                    valueColor: Theme.Color.accent
                )
            }
            if model.summary.totalMoments > 0 {
                MetadataRow(
                    label: "Captured",
                    value: "\(model.summary.totalMoments)"
                )
            }
            // Reported, in secondary grey rather than amber. The photographs are
            // in the user's library and the archive knows about them — nothing has
            // been lost — so this is a note about an organisation failing, not a
            // permission the user declined. Amber has exactly one job (ADR-025).
            if let albumFailure = model.albumFailure {
                Text(albumFailure)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The whole footer is hidden when there is nothing to say — no moments
        // and no missing permission.
        //
        // **This used to hide a control rather than just rows.** The DEBUG camera
        // reset button lived here, so on a fresh install with notifications
        // granted the footer was at `opacity(0)` and the button was still there,
        // still hit-testable, and invisible: a recovery hook guarding the camera's
        // one silent failure that nobody could see or press (TRD §5.5,
        // AGENTS.md §6). The hook now lives in Settings' diagnostics section,
        // where being visible is the entire point, and this is a layout decision
        // about rows only.
        .opacity(
            model.summary.totalMoments > 0
                || !model.notificationsAuthorized
                || model.albumFailure != nil
                ? 1 : 0
        )
    }
}
