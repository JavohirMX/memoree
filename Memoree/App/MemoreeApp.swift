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
            .task { await bootstrap() }
        }
    }

    private func bootstrap() async {
        guard environment == nil, startupError == nil else { return }
        do {
            let created = try AppEnvironment()
            environment = created
            await created.refreshHorizonIfNeeded(force: true)
        } catch {
            startupError = error.localizedDescription
        }
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

/// Phase 0 placeholder; replaced by onboarding → Today routing in Phase 5.
struct RootView: View {
    var body: some View {
        ZStack {
            Theme.Color.canvas
                .ignoresSafeArea()

            Text("Memoree")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)
        }
    }
}

#Preview {
    RootView()
}
