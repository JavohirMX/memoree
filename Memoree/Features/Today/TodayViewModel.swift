import Foundation
import Observation
import SwiftUI

/// Drives the Today screen.
///
/// Owns the only ticking clock in the app. Rather than a `Timer` per view, a
/// single timer updates `now` once a second while the screen is on-screen, and
/// the state is re-derived from it. That keeps the countdown to one source of
/// truth and means the screen cannot drift out of sync with the resolver.
@MainActor
@Observable
final class TodayViewModel {

    /// The instant the state was last computed from.
    private(set) var now: Date

    /// Today's resolved window.
    private(set) var interval: MomentInterval

    /// Today's moment, if captured.
    private(set) var todayMoment: MomentFacts?

    /// Streak statistics, recomputed rather than cached.
    private(set) var summary: StreakSummary

    /// Whether notifications were granted. A denied state is fully supported,
    /// not an error (AGENTS.md §9).
    private(set) var notificationsAuthorized = false

    /// Diagnostics for the Settings screen: how many notifications are pending.
    private(set) var pendingNotificationCount = 0

    /// Set while the camera is unavailable in this build phase.
    private(set) var cameraAvailable = false

    private let environment: AppEnvironment
    private var ticker: Task<Void, Never>?

    init(environment: AppEnvironment, now: Date = Date()) {
        self.environment = environment
        self.now = now
        self.interval = environment.interval(for: DayIdentifier(date: now))
        self.todayMoment = environment.momentStore.facts().last { $0.day.isToday }
        self.summary = environment.momentStore.summary()
    }

    // MARK: - Derived state

    var state: MomentState {
        MomentStateResolver.resolve(
            now: now,
            interval: interval,
            todayMoment: todayMoment,
            dayEnd: MomentStateResolver.endOfDay(containing: now)
        )
    }

    /// `mm:ss` for the open window, or the countdown to it. Empty otherwise.
    var countdown: String? {
        switch state {
        case .open(let remaining):
            return CountdownFormatter.string(fromSeconds: remaining)
        case .scheduled(let until):
            return CountdownFormatter.string(fromSeconds: until)
        default:
            return nil
        }
    }

    /// Amber under thirty seconds — the only colour besides white.
    var countdownIsUrgent: Bool {
        if case .open(let remaining) = state { return remaining <= 30 }
        return false
    }

    /// Wall-clock time of today's moment, e.g. "14:37".
    var momentClockTime: String {
        Self.timeFormatter.string(from: interval.start)
    }

    var streak: Int { summary.currentStreak }

    var longestStreak: Int { summary.longestStreak }

    /// "3 days" / "1 day"
    var streakDescription: String {
        "\(streak) \(streak == 1 ? "day" : "days")"
    }

    // MARK: - Lifecycle

    /// Starts the once-a-second tick while the screen is on-screen.
    func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.refreshNow()
            }
        }
    }

    func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    /// Recomputes everything that depends on the clock.
    ///
    /// Re-reads the interval each time because the moment window can be changed
    /// in Settings, and re-resolves the day identity so the state rolls over at
    /// local midnight rather than at UTC midnight.
    func refreshNow() {
        let current = Date()
        let today = DayIdentifier(date: current)

        // Day rollover: the window and moment both belong to a specific day.
        if today != DayIdentifier(date: now) {
            interval = environment.interval(for: today)
            todayMoment = environment.momentStore.facts().last { $0.day == today }
            summary = environment.momentStore.summary(today: today)
        }
        now = current
    }

    /// Full refresh: state, streak, and notification diagnostics.
    func reload() async {
        refreshNow()
        summary = environment.momentStore.summary()
        notificationsAuthorized = await refreshAuthorization()
        pendingNotificationCount = await environment.notificationService.pendingCount()
    }

    private func refreshAuthorization() async -> Bool {
        guard let service = environment.notificationService as? UserNotificationService
        else { return notificationsAuthorized }
        let status = await service.authorizationStatus()
        return status == .authorized || status == .provisional
    }

    // MARK: - Derived helpers

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
