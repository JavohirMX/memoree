import UIKit
import UserNotifications

/// Receives moment reminders and forwards the tap into the app.
///
/// **The app had no notification delegate at all until now**, and that is not a
/// missing feature so much as two broken ones:
///
/// - Without a delegate, iOS **suppresses** a notification that arrives while
///   the app is in the foreground. The user is looking at the screen the
///   reminder is meant to interrupt, and nothing appears. The ritual's one
///   trigger silently degrades to "works if you happen to be elsewhere".
/// - Without `didReceive`, tapping a reminder only launches the app. The tap
///   carries the user's intent — they want to photograph something now — and
///   discarding it makes them navigate to a button themselves.
///
/// There is no URL scheme and no universal link. `Info.plist` says so
/// explicitly, because Memoree makes no network calls and registers no scheme
/// (AGENTS.md §2.1). So the tap is delivered in-process: this delegate raises a
/// flag on `AppEnvironment`, and `TodayView` watches it.
///
/// Not a singleton, deliberately. The delegate is created by
/// `@UIApplicationDelegateAdaptor` and `MemoreeApp` hands it the one handler it
/// needs, once the environment exists. The app delegate outlives the SwiftUI
/// scene, which is why the forwarding is a closure rather than a stored
/// reference to the environment.
///
/// **On the isolation annotations.** `UIApplicationDelegate` is main-actor
/// isolated; `UNUserNotificationCenterDelegate` is not, so conforming to both
/// crosses an isolation boundary and the compiler is right to object. The two
/// callbacks are `nonisolated` because the system genuinely calls them from
/// wherever it likes, and the handler they forward to is held in a lock-guarded
/// box rather than on the main-actor-isolated instance — which is what makes
/// that `nonisolated` honest rather than merely silencing the error.
final class MemoreeAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    private let handler = HandlerBox()

    /// Routes a tapped reminder. Called from `MemoreeApp` once the environment
    /// exists, which is why it is a method and not a settable property.
    func setOnMomentNotification(_ handler: @escaping @MainActor () -> Void) {
        self.handler.value = handler
    }

    // MARK: - UIApplicationDelegate

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // No action buttons. The tap *is* the action (TRD §9), and a button
        // labelled "Post" would be a lie — the window might be closed.
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: UserNotificationService.categoryIdentifier,
                actions: [],
                intentIdentifiers: [],
                options: []
            )
        ])
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // `.banner, .sound` and nothing else. No badge — a number on the icon
        // is a nag, and the streak is a statistic rather than a score
        // (ADR-015).
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let forward = handler.value
        // Completion is called immediately rather than after the hop: Apple
        // requires it promptly, and holding a system callback hostage to our
        // own scheduling is how "the app froze" bug reports are made.
        Task { @MainActor in forward?() }
        completionHandler()
    }
}

// MARK: - Handler box

/// A lock-guarded slot for the tap handler.
///
/// Exists because of the isolation boundary described above: the delegate is
/// main-actor, its callback is not, and a `nonisolated` method cannot read a
/// main-actor property. This is the smallest thing that makes the read safe.
///
/// `@unchecked Sendable` with a justification, because the compiler cannot see
/// the lock: it sees a mutable reference in a `@Sendable` closure. The lock is
/// the whole implementation and it is held across every access.
private final class HandlerBox: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: (@MainActor () -> Void)?

    var value: (@MainActor () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
