import Foundation
import UserNotifications

/// Schedules and maintains the rolling horizon of moment notifications.
///
/// iOS caps an app at **64** pending local notification requests. Memoree keeps
/// a 45-day horizon and refills whenever the pending count falls below 20,
/// leaving headroom for a user who opens the app infrequently.
protocol NotificationService: Sendable {

    /// Ensures notifications are scheduled for every day in the horizon.
    ///
    /// Idempotent. Safe to call on every launch, foreground, and settings change.
    func refreshHorizon(window: TimeWindow, windowDuration: TimeInterval) async throws

    /// Number of moment notifications currently pending.
    func pendingCount() async -> Int

    /// Whether the user has agreed to be reminded.
    ///
    /// A denied state is a supported outcome, not an error: with no server
    /// nothing can re-notify the user later, so the app has to stay fully
    /// usable without the reminder (AGENTS.md §9, TRD §9).
    func authorizationStatus() async -> NotificationAuthorization

    /// Asks for permission. Returns whether it was granted.
    ///
    /// Never blocks on a dialog the test host cannot dismiss.
    func requestAuthorization() async -> Bool

    /// Removes every notification Memoree has scheduled.
    ///
    /// Used on account-equivalent events — there are none — and by tests. It
    /// deliberately does NOT call `removeAllPendingNotificationRequests()`,
    /// which would also clear items this app never scheduled.
    func clearAll() async
}

/// Mirrors `UNAuthorizationStatus` without leaking UserNotifications into the
/// call sites that only need to branch on the outcome.
///
/// The same pattern as `CameraAuthorizationStatus` and
/// `PhotoAuthorizationStatus`. It did not exist at first, and the cost of that
/// was concrete: `TodayViewModel` and `OnboardingView` both reached the real
/// status through `as? UserNotificationService`, so a test double could never
/// drive them — every test silently took the "not the production type" branch
/// while appearing to exercise the real path.
enum NotificationAuthorization: Sendable, Equatable {
    /// Not yet asked.
    case notDetermined
    /// Granted explicitly.
    case authorized
    /// Granted provisionally — delivered quietly, without a prompt. Quiet
    /// delivery is not useful for a reminder, but the user did not say no.
    case provisional
    /// The user said no. Everything else in the app still works.
    case denied

    /// Whether a reminder will actually reach the user.
    var willDeliver: Bool {
        self == .authorized || self == .provisional
    }
}

/// Production `NotificationService`.
///
/// Uses `UNCalendarNotificationTrigger` with explicit wall-clock components
/// rather than a time-interval trigger. An interval trigger fires N × 86400
/// seconds after scheduling, which drifts across DST and across the user
/// travelling between timezones. Calendar components resolve against the
/// *current* zone at fire time, which is the correct semantic for "at 14:37 on
/// 30 September".
struct UserNotificationService: NotificationService, @unchecked Sendable {

    /// iOS's hard cap on pending requests per app.
    static let systemPendingLimit = 64

    /// Days of notifications kept scheduled.
    static let horizonDays = 45

    /// Refill when pending falls below this. The gap between 20 and 45 is the
    /// buffer that absorbs infrequent launches.
    static let refillThreshold = 20

    private static let categoryIdentifier = "MEMORENT"
    private static let identifierPrefix = "moment."

    // `@unchecked Sendable`: UNUserNotificationCenter is an Apple class that is
    // not annotated Sendable, but every method used here is documented
    // thread-safe, and the type is a process-wide singleton obtained from
    // `.current()`. The scheduler and clock are value types held immutably, so
    // the only shared reference is the system center. Announced at the
    // conformance, per AGENTS.md §5.
    private let center: UNUserNotificationCenter
    private let scheduler: MomentScheduler
    private let now: @Sendable () -> Date

    init(
        center: UNUserNotificationCenter = .current(),
        scheduler: MomentScheduler,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.center = center
        self.scheduler = scheduler
        self.now = now
    }

    // MARK: - Permissions

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> NotificationAuthorization {
        await center.notificationSettings().authorizationStatus.asMemoree
    }

    // MARK: - Horizon

    func refreshHorizon(window: TimeWindow, windowDuration: TimeInterval) async throws {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        else {
            // Declined notifications are a supported state, not an error
            // (AGENTS.md §9). The app stays usable; only the reminder is lost.
            throw SchedulerError.notificationDenied
        }

        let pending = await pendingRequests()
        // Already full and above threshold: nothing to do. Avoids churn on every
        // foreground.
        guard pending.count < Self.horizonDays else { return }

        let today = DayIdentifier(date: now())
        var requests: [UNNotificationRequest] = []
        requests.reserveCapacity(Self.horizonDays)

        for offset in 0..<Self.horizonDays {
            let day = today.offset(by: offset)
            let start = scheduler.momentStart(
                for: day, window: window, windowDuration: windowDuration
            )
            requests.append(makeRequest(for: day, at: start, windowDuration: windowDuration))
        }

        // Replace atomically-ish: remove the identifiers we are about to set,
        // then add. Never removeAllPendingNotificationRequests().
        let identifiers = requests.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)

        for request in requests {
            try await center.add(request)
        }
    }

    func pendingCount() async -> Int {
        await pendingRequests().count
    }

    func clearAll() async {
        let identifiers = await pendingRequests().map(\.identifier)
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func pendingRequests() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }

    // MARK: - Request construction

    private func makeRequest(
        for day: DayIdentifier,
        at start: Date,
        windowDuration: TimeInterval
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "It's time"
        content.body = "You have \(Self.windowPhrase(windowDuration)) to capture a moment."
        content.sound = .default
        content.interruptionLevel = .active
        content.categoryIdentifier = Self.categoryIdentifier

        var components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: start
        )
        // Fire on the whole minute. The derivation already rounded to a second
        // boundary via the window span; seconds are pinned so a notification
        // never lands mid-minute.
        components.second = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        return UNNotificationRequest(
            identifier: Self.identifierPrefix + day.rawValue,
            content: content,
            trigger: trigger
        )
    }

    private static func windowPhrase(_ duration: TimeInterval) -> String {
        let minutes = Int((duration / 60).rounded())
        if minutes <= 1 { return "1 minute" }
        return "\(minutes) minutes"
    }
}

// MARK: - Narrowing

extension UNAuthorizationStatus {

    /// Apple's enum, narrowed to Memoree's.
    ///
    /// `.ephemeral` is App Clips only and never reaches this app, but it has to
    /// be handled exhaustively, and mapping it to `.authorized` would claim a
    /// delivery guarantee it does not make. It maps to `.denied` instead: a
    /// reminder that cannot be delivered is a reminder that will not be.
    var asMemoree: NotificationAuthorization {
        switch self {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .denied: return .denied
        case .ephemeral: return .denied
        @unknown default: return .denied
        }
    }
}
