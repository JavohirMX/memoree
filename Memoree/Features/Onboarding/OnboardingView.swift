import SwiftUI
import UserNotifications

/// First-run setup.
///
/// Four steps, each asking for one thing and saying why. There is no account
/// screen because there is no account (ADR-001), and no tour of features,
/// because the mechanic is self-explanatory once you have used it once.
///
/// Every permission is deniable and the app remains usable without any of them.
/// That is a real constraint, not politeness: with no server, nothing can
/// re-notify you later (AGENTS.md §9).
struct OnboardingView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var step: Step = .welcome

    /// The window being edited, held locally while the step is on screen.
    ///
    /// `@State` rather than reading the store inside the `Binding`, because the
    /// old inline version wrote to the `AppSettings` managed object on every
    /// slider step. A SwiftData managed object mutated sixty times in a second
    /// is a write sixty times in a second, and the slider's `get` read it back
    /// mid-gesture — so the control was fighting the object it was editing.
    @State private var draftWindow = TimeWindow.default

    enum Step: Int, CaseIterable {
        case welcome
        case notifications
        case camera
        case window
    }

    var body: some View {
        CanvasBackground()

        VStack(spacing: 0) {
            Spacer()

            content

            Spacer()

            footer
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.xl)
        .scrollableWhenItCannotFit()
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            stepBody(
                title: "Memoree",
                body: """
                A daily photo of your life — no account, no feed. \
                Saved to the Photos library you already own.
                """
            )

        case .notifications:
            stepBody(
                title: "When should we interrupt you?",
                body: """
                Once a day Memoree asks for a photo at a random time in your window. \
                Capture anytime; every day you shoot counts. The window only times the reminder.
                """
            )

        case .camera:
            stepBody(
                title: "The camera",
                body: """
                Two photographs each moment: the scene, and you. Unedited. \
                Nothing leaves this device.
                """
            )

        case .window:
            windowStep
        }
    }

    private func stepBody(title: String, body: String) -> some View {
        VStack(spacing: Theme.Spacing.l) {
            Text(title)
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(body)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The daily window.
    ///
    /// Defaults to 11:00–23:00, the band production BeReal observes, so the
    /// reminder never lands at 3am. Wider is more random; narrower is more
    /// predictable.
    ///
    /// The window sets **when the notification arrives** and nothing else
    /// (ADR-023, ADR-032). Capture is permitted at any time; every capture day
    /// counts toward the streak. Which is why this screen can be shown at all —
    /// asking someone to narrow the band that decides when they get asked is a
    /// real preference, and it would be a strange thing to collect if it had no
    /// effect.
    ///
    /// The picker itself is `WindowPicker`, shared with Settings. The reason it
    /// can be shared is that on first run there is nothing to re-derive: no
    /// `DayRecord` exists yet, so writing the setting *is* the whole operation.
    /// The Settings copy of the same control has to do considerably more, and
    /// the comment there explains what.
    private var windowStep: some View {
        VStack(spacing: Theme.Spacing.l) {
            stepBody(
                title: "Your window",
                body: "Memoree picks a random moment inside this, each day."
            )

            WindowPicker(
                window: $draftWindow,
                onCommit: { window in await environment.updateWindow(window) }
            )

            // True now, and the reason it is here. The window is the only thing
            // that decides when the phone interrupts you, so being able to move
            // it afterwards is the difference between a preference and a
            // one-time question. The sentence was previously a promise the app
            // could not keep — there was no Settings screen to keep it in, and
            // shipping a window picker without this line is how that came about.
            Text("Wider is more random. You can change this later in Settings.")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .onAppear { draftWindow = environment.momentStore.settings().timeWindow }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: Theme.Spacing.m) {
            PrimaryButton(title: step == .window ? "Start" : "Continue") {
                Task { await advance() }
            }

            if step != .welcome && step != .window {
                Button("Not now") { advanceWithoutPermission() }
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(minHeight: Theme.Size.tapTarget)
                    .contentShape(.rect)
            }
        }
    }

    // MARK: - Flow

    /// Requests whatever this step needs, then advances. A denied permission is
    /// not an error: the app works without it and the button still advances.
    private func advance() async {
        switch step {
        case .welcome:
            break
        case .notifications:
            await requestNotificationPermission()
        case .camera:
            await requestCameraPermission()
        case .window:
            break
        }
        advanceWithoutPermission()
    }

    private func advanceWithoutPermission() {
        let settings = environment.momentStore.settings()
        settings.onboardingComplete = true
        try? environment.momentStore.saveSettings(settings)

        // The window the user actually chose, on first run.
        //
        // `updateWindow` rather than a direct write, so onboarding and Settings
        // go through one path. On first run there is nothing to re-derive, so
        // this is close to a plain assignment — but "close to" is the point. The
        // Settings version of this control has to discard 44 `DayRecord`s and
        // rebuild the notification horizon to have any effect at all, and a
        // second code path that skips that step is a bug waiting for the first
        // person to reach Settings.
        Task { await environment.updateWindow(draftWindow) }

        // Schedule only after the prompt, so the horizon is not thrown away by
        // a later authorisation.
        Task { await environment.refreshHorizonIfNeeded(force: true) }
        advanceStep()
    }

    private func advanceStep() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        }
        // Leaving the last step is driven by the root's onboarding flag.
    }

    private func requestNotificationPermission() async {
        _ = await environment.notificationService.requestAuthorization()
    }

    /// Asks for the camera, through the service.
    ///
    /// **This used to call `AVCaptureDevice.requestAccess(for: .video)` directly
    /// and import AVFoundation to do it**, which broke `AGENTS.md` §3 twice over
    /// — "Features contains SwiftUI views and view models only. No AVFoundation" —
    /// and it had been sitting there since Phase 0 without anything noticing.
    /// The file also imported `Photos`, which it never used at all.
    ///
    /// The service already had `requestAuthorization()` and `AppEnvironment` hands
    /// out the one cached instance, so the view was reaching past the boundary
    /// for something sitting on the other side of it. Now it does not, and both
    /// imports are gone.
    ///
    /// Found by `DesignSystemInvariantTests`, which is the first check in this
    /// project to assert the layering rather than describe it.
    private func requestCameraPermission() async {
        _ = await environment.captureService.requestAuthorization()
    }
}
