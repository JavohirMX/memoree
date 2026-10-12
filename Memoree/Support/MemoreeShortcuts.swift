import AppIntents

/// App Shortcuts provider exposing CaptureMomentIntent to Siri and the Shortcuts app.
///
/// App-target only — the widget extension must not register a second provider.
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
