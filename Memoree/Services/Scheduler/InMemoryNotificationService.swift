import Foundation

/// An in-memory `NotificationService` for tests and previews.
///
/// **This double did not exist until the Today screen needed one.** Every other
/// service protocol has had a test double since it was written; this one had
/// none, which is why Phase 1's refill invariant test was never written — the
/// protocol's only implementation wraps `UNUserNotificationCenter`, which cannot
/// be subclassed into something useful, so the invariant was untestable rather
/// than merely unwritten. AGENTS.md §3: services that cannot be faked are
/// services that cannot be tested.
///
/// The scheduler and the horizon decision are pure and are tested directly on
/// `NotificationHorizonPlanner`. What this double is for is everything
/// *around* them: that a screen asks the right questions, and that a declined
/// permission is a state rather than a failure.
final class InMemoryNotificationService: NotificationService, @unchecked Sendable {

    private struct State {
        var pending: [String] = []
        var refreshes: [Refresh] = []
        var cancelledStreakSavers: [DayIdentifier] = []
        var clearCount = 0
        var failNextRefresh: SchedulerError?
        var requestAuthorizationResult = true
        var authorization: NotificationAuthorization = .authorized
    }

    /// A recorded horizon refresh, so a test can assert on what was asked for
    /// rather than only that something was.
    struct Refresh: Equatable {
        let window: TimeWindow
        let windowDuration: TimeInterval
        let capturedDays: Set<DayIdentifier>
    }

    private let lock = NSLock()
    private var state = State()

    // MARK: - Test configuration

    /// Seeds the pending set, for the 0 / 19 / 20 / 64 boundary cases.
    func setPendingIdentifiers(_ identifiers: [String]) {
        lock.withLock { state.pending = identifiers }
    }

    /// Convenience for the real thing: `moment.<dayIdentifier>` per day.
    func setPendingDays(_ days: [DayIdentifier]) {
        setPendingIdentifiers(days.map { "moment.\($0.rawValue)" })
    }

    func failNextRefresh(with error: SchedulerError) {
        lock.withLock { state.failNextRefresh = error }
    }

    func setAuthorizationResult(_ result: Bool) {
        lock.withLock { state.requestAuthorizationResult = result }
    }

    func setAuthorization(_ status: NotificationAuthorization) {
        lock.withLock { state.authorization = status }
    }

    // MARK: - Inspection

    var pending: [String] { lock.withLock { state.pending } }
    var refreshes: [Refresh] { lock.withLock { state.refreshes } }
    var refreshCount: Int { lock.withLock { state.refreshes.count } }
    var clearCount: Int { lock.withLock { state.clearCount } }
    var lastRefresh: Refresh? { lock.withLock { state.refreshes.last } }
    var cancelledStreakSavers: [DayIdentifier] { lock.withLock { state.cancelledStreakSavers } }

    // MARK: - NotificationService

    func refreshHorizon(
        window: TimeWindow,
        windowDuration: TimeInterval,
        capturedDays: Set<DayIdentifier>
    ) async throws {
        try lock.withLock {
            if let failure = state.failNextRefresh {
                state.failNextRefresh = nil
                throw failure
            }
            state.refreshes.append(Refresh(
                window: window,
                windowDuration: windowDuration,
                capturedDays: capturedDays
            ))
        }
    }

    func cancelStreakSaver(for day: DayIdentifier) async {
        lock.withLock {
            state.cancelledStreakSavers.append(day)
            let streakId = NotificationHorizonPlanner.streakIdentifier(for: day)
            state.pending.removeAll { $0 == streakId }
        }
    }

    func pendingCount() async -> Int {
        lock.withLock { state.pending.count }
    }

    func authorizationStatus() async -> NotificationAuthorization {
        lock.withLock { state.authorization }
    }

    func requestAuthorization() async -> Bool {
        lock.withLock { state.requestAuthorizationResult }
    }

    func clearAll() async {
        lock.withLock {
            state.clearCount += 1
            state.pending = []
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
