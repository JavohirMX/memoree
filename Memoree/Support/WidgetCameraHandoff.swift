import Foundation

/// Cross-process / cold-start camera request from the widget App Intent (ADR-040).
///
/// `CaptureMomentIntent` cannot rely on `AppEnvironment.shared` existing yet —
/// the intent may run before bootstrap finishes.
///
/// Persistence uses two channels:
/// 1. **Process-local flag** — same-process warm path and unit tests (App Group
///    suites are flaky under Simulator without a full provisioning dance).
/// 2. **App Group** — real device / cross-process widget → app launches.
enum WidgetCameraHandoff {

    static let didRequestNotification = Notification.Name("memoree.widget.cameraHandoff")

    private static let key = "widget.pendingCameraRequest"

    /// Serialises the process-local pending bit. `@unchecked Sendable` because
    /// all access goes through `lock` (same pattern as capture queue owners).
    private final class LocalFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false

        func set() {
            lock.lock()
            pending = true
            lock.unlock()
        }

        func consume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let value = pending
            pending = false
            return value
        }
    }

    private static let local = LocalFlag()

    /// Optional hook the app installs so a warm intent can set
    /// `pendingCameraRequest` without importing `AppEnvironment` into the
    /// widget extension.
    @MainActor
    static var onRequest: (() -> Void)?

    /// Records a request to open the camera as soon as the app can.
    ///
    /// Prefer calling from the main actor (App Intent `perform` is `@MainActor`)
    /// so `onRequest` runs synchronously and tests do not race a `Task`.
    @MainActor
    static func request() {
        local.set()
        WidgetAppGroup.defaults.set(true, forKey: key)
        onRequest?()
        NotificationCenter.default.post(name: didRequestNotification, object: nil)
    }

    /// Returns whether a camera open was requested, and clears both channels.
    static func consume() -> Bool {
        let fromLocal = local.consume()
        let defaults = WidgetAppGroup.defaults
        let fromRemote = defaults.bool(forKey: key)
        if fromRemote {
            defaults.set(false, forKey: key)
        }
        return fromLocal || fromRemote
    }
}
