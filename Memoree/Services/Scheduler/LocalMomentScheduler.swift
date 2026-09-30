import Foundation

/// The production `MomentScheduler`, backed by HMAC-SHA256 over a per-install
/// Keychain secret.
///
/// No UI, no UserNotifications, no SwiftUI (AGENTS.md §3). Notifications are
/// `NotificationService`'s job; this type only answers "when".
struct LocalMomentScheduler: MomentScheduler {

    private let secret: InstallSecret

    init(secret: InstallSecret) {
        self.secret = secret
    }

    func momentStart(
        for day: DayIdentifier,
        window: TimeWindow,
        windowDuration: TimeInterval
    ) -> Date {
        MomentDerivation.momentStart(
            for: day,
            window: window,
            secret: secret.value,
            windowDuration: windowDuration
        )
    }

    func momentInterval(
        for day: DayIdentifier,
        window: TimeWindow,
        windowDuration: TimeInterval
    ) -> MomentInterval {
        let start = momentStart(for: day, window: window, windowDuration: windowDuration)
        return MomentInterval(start: start, end: start.addingTimeInterval(windowDuration))
    }
}
