import AVFoundation
import Photos
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
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            stepBody(
                title: "Memoree",
                body: """
                One photograph of your actual life, taken at a moment you \
                cannot predict, saved to the library you already own.

                Nothing to sign up for. Nothing to share. Nothing that isn't \
                yours.
                """
            )

        case .notifications:
            stepBody(
                title: "When should we interrupt you?",
                body: """
                Once a day, at a random moment inside your window, \
                Memoree will ask for a photo.

                You can photograph whenever you like — only a photo taken \
                during that moment counts towards your streak.
                """
            )

        case .camera:
            stepBody(
                title: "The camera",
                body: """
                Your moment is two photographs: the scene with the rear camera, \
                and you with the front. Taken together, kept unedited.

                Photos never leave this device.
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
    /// (ADR-023). Capture is permitted at any time; only a photograph taken
    /// inside the resulting two minutes grows the streak. Which is why this
    /// screen can be shown at all — asking someone to narrow the band that
    /// decides when they get asked is a real preference, and it would be a
    /// strange thing to collect if it had no effect.
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
                .foregroundStyle(Theme.Color.textTertiary)
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

    private func requestCameraPermission() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
    }
}
