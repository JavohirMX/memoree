import AppIntents
import Foundation

/// App Intent enabling direct opening of the capture screen.
///
/// Integrates with the iOS Action Button, Control Center, Siri Shortcuts,
/// Lock Screen, and the Home Screen widget (ADR-040). Conforms to zero-network,
/// local-only architecture principles.
///
/// Compiled into both the app and the widget extension. Does **not** reference
/// `AppEnvironment` — cold launch may run this before bootstrap. The App Group
/// handoff is consumed by the environment when it is ready.
struct CaptureMomentIntent: AppIntent {

    static let title: LocalizedStringResource = "Capture Moment"
    static let description = IntentDescription("Opens the camera directly to capture your daily moment.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetCameraHandoff.request()
        return .result()
    }
}
