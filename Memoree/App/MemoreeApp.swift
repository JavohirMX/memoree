import SwiftData
import SwiftUI

/// The application root.
///
/// Phase 0 proved the build pipeline. Phase 1 adds the scheduler: the moment
/// window is resolved on launch and the notification horizon is topped up, so a
/// real notification is pending before the user reaches the Today screen.
@main
struct MemoreeApp: App {

    @State private var environment: AppEnvironment?
    @State private var startupError: String?

    /// The notification delegate.
    ///
    /// Exists because `didFinishLaunchingWithOptions` is the only place a
    /// `UNUserNotificationCenterDelegate` can be installed in time, and SwiftUI's
    /// `App` has no such hook. The property wrapper is how SwiftUI owns it; the
    /// local name is how the rest of the app reaches it to route a tapped
    /// reminder once there is an environment to route into.
    @UIApplicationDelegateAdaptor(MemoreeAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            Group {
                if let environment {
                    RootView()
                        .environment(environment)
                        .modelContainer(environment.container)
                } else if let startupError {
                    StartupFailureView(message: startupError)
                } else {
                    // Black, not a spinner: Memoree's canvas is #000000 even
                    // during startup (ADR-012).
                    Theme.Color.canvas.ignoresSafeArea()
                }
            }
            .preferredColorScheme(.dark)
            .modifier(DebugForcedOrientation())
            // Reduce Motion, published once here and read by every
            // `.appAnimation` in the tree.
            //
            // Applied at the root rather than per screen because the setting is
            // global: a per-screen subscription is a per-screen chance to be
            // wrong, and a screen that forgot it would animate for a user who
            // asked it not to — invisibly, because the rest of the app would be
            // behaving correctly.
            .observingReduceMotion()
            .task { await bootstrap() }
        }
    }

    private func bootstrap() async {
        guard environment == nil, startupError == nil else { return }
        do {
            let created = try AppEnvironment()
            environment = created

            // Wired after construction, because it is the environment that has
            // to be told. The delegate outlives the SwiftUI scene, which is why
            // this is a closure it holds rather than a reference it takes — and
            // why neither of them is a singleton: each has exactly one owner.
            appDelegate.setOnMomentNotification { [weak created] in
                created?.requestCamera()
            }

            await created.refreshHorizonIfNeeded(force: true)
        } catch {
            startupError = error.localizedDescription
        }
    }
}

/// Forces the window sideways when `-MemoreeForceLandscape` is passed.
///
/// ## Why this exists
///
/// **Landscape was declared allowed but has never been *seen*.** Phase 4 enabled
/// landscape left and right because a landscape photograph could not otherwise be
/// taken, and four latent layout bugs were fixed by reasoning. **No landscape
/// screenshot has ever been taken of any screen**, because rotating a simulator
/// needs the Simulator GUI — which is not installed on this machine, and cannot be
///: there is no `simctl` subcommand for orientation. `simctl io … screenshot`
/// captures whatever the device is showing and nothing can change what that is.
///
/// A layout that has never been rendered is a layout nobody has checked, and the
/// project's own record is that reasoning about a layout finds strictly fewer
/// problems than looking at it: four of the four bugs fixed during the orientation
/// work were found by holding the phone, and every one of them was invisible in the
/// code.
///
/// ## `-MemoreeForceLandscape`, not a settings row
///
/// A user-facing orientation switch would be a feature nobody asked for, in an app
/// whose premise is that it does one thing. This is a **DEBUG launch argument**,
/// alongside `-MemoreeSkipOnboarding`, `-MemoreeSeedMoments` and `-MemoreeOpen`,
/// and it compiles out of release entirely for the same reason they do: inert code
/// in a shipping binary is still code that ships.
///
/// ## Why it asks rather than asserts
///
/// `requestGeometryUpdate` is the supported way to rotate programmatically, and it
/// needs the app to declare that its orientations changed — hence the second
/// `UIViewController.setNeedsUpdateOfSupportedInterfaceOrientations()`. Forcing
/// `supportedInterfaceOrientations` to portrait-only and back would be shorter and
/// is **not** done: the simulator honours the device's real rotation settings, and
/// a screenshot that came out landscape because the app fought the system would be
/// evidence about the flag rather than about the layout.
private struct DebugForcedOrientation: ViewModifier {

    func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-MemoreeForceLandscape") {
            content.onAppear {
                guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first else { return }
                scene.requestGeometryUpdate(
                    .iOS(interfaceOrientations: .landscapeRight)
                )
                // Declares that this controller's supported orientations changed,
                // so the request above is honoured. Called on the *instance* —
                // it is not a class method, and the compiler says so.
                scene.keyWindow?.rootViewController?
                    .setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Shown only if the SwiftData container cannot be created.
///
/// Unreachable in normal operation, but a dead-end failure state is a bug
/// (AGENTS.md §6), so it explains itself rather than showing a blank screen.
private struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Text("Memoree could not start")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)

            Text("Your photos are untouched — they were never in this app's storage.")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.canvas)
    }
}

/// Routes between first-run setup and the Today screen.
///
/// Onboarding is shown once. There is no account, so "complete" is a single
/// boolean in local settings rather than a session or a profile.
struct RootView: View {

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if environment.momentStore.settings().onboardingComplete {
                TodayView()
            } else {
                OnboardingView()
            }
        }
        .appAnimation(environment.momentStore.settings().onboardingComplete)
    }
}

#Preview {
    RootView()
}
