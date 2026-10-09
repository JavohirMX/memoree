import AppIntents
import Foundation

/// App Intent enabling direct opening of the capture screen.
///
/// Integrates with the iOS Action Button, Control Center, Siri Shortcuts, and Lock Screen.
/// Conforms to zero-network, local-only architecture principles.
struct CaptureMomentIntent: AppIntent {

    static let title: LocalizedStringResource = "Capture Moment"
    static let description = IntentDescription("Opens the camera directly to capture your daily moment.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppEnvironment.shared?.requestCamera()
        return .result()
    }
}

/// App Shortcuts provider exposing CaptureMomentIntent to Siri and the Shortcuts app.
struct MemoreeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureMomentIntent(),
            phrases: [
                "Capture \(.applicationName)",
                "Take my \(.applicationName)",
                "Open camera in \(.applicationName)"
            ],
            shortTitle: "Capture Moment",
            systemImageName: "camera"
        )
    }
}
