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
            windowPicker
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
    private var windowPicker: some View {
        let settings = environment.momentStore.settings()
        return VStack(spacing: Theme.Spacing.l) {
            stepBody(
                title: "Your window",
                body: "Memoree picks a random moment inside this, each day."
            )

            VStack(spacing: Theme.Spacing.m) {
                HStack {
                    Text("From")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                    Spacer()
                    Text(Self.clock.string(from: settings.windowStartMinutes))
                        .font(Theme.Typography.body)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Color.textPrimary)
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.windowStartMinutes) },
                        set: { newValue in
                            let minutes = Int(newValue)
                            guard minutes < settings.windowEndMinutes else { return }
                            settings.windowStartMinutes = minutes
                            try? environment.momentStore.saveSettings(settings)
                        }
                    ),
                    in: 0...Double(max(60, settings.windowEndMinutes - 60)),
                    step: 30
                )
                .tint(Theme.Color.textPrimary)

                HStack {
                    Text("Until")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                    Spacer()
                    Text(Self.clock.string(from: settings.windowEndMinutes))
                        .font(Theme.Typography.body)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Color.textPrimary)
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.windowEndMinutes) },
                        set: { newValue in
                            let minutes = Int(newValue)
                            guard minutes > settings.windowStartMinutes else { return }
                            settings.windowEndMinutes = min(minutes, 24 * 60)
                            try? environment.momentStore.saveSettings(settings)
                        }
                    ),
                    in: Double(min(24 * 60, settings.windowStartMinutes + 60))...Double(24 * 60),
                    step: 30
                )
                .tint(Theme.Color.textPrimary)
            }

            Text("Wider is more random. You can change this later.")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textTertiary)
                .multilineTextAlignment(.center)
        }
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

    // MARK: - Formatting

    private static let clock: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}

extension DateComponentsFormatter {
    /// Formats minutes-from-midnight as a clock time.
    func string(from minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        return string(from: components) ?? "00:00"
    }
}
