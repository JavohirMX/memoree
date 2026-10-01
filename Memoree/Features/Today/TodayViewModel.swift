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

    /// Today's moment, read back out of the user's photo library.
    ///
    /// **The first thing in the app that reads from Photos.** Everything up to
    /// here only writes. This is TRD §6.5's read path, and it is the reason the
    /// row stores `PHAsset.localIdentifier` values at all: the photographs are
    /// the user's, and Memoree streams them back rather than keeping copies
    /// (ADR-007).
    ///
    /// The rear is large and the front is inset, which is the geometry TRD §5.6
    /// states. The random opening camera (ADR-021) decided *which* the user shot
    /// first, not which one is prominent — that is a review-screen behaviour,
    /// and the review screen is the only place where both slots are photographs.
    private(set) var todayImages: (large: UIImage, inset: UIImage)?

    /// Today's photographs are gone from Photos.
    ///
    /// The user may have deleted them deliberately — that is their library, and
    /// Memoree never reached back into it (ADR-008). The moment is still a real
    /// moment and still in the archive; it just has nothing to show, and saying
    /// so beats rendering an empty black rectangle that reads as a bug.
    private(set) var todayMissingFromPhotos = false

    /// Diagnostics for the Settings screen: how many notifications are pending.
    private(set) var pendingNotificationCount = 0

    /// Set while the camera is unavailable in this build phase.
    private(set) var cameraAvailable = false

    private let environment: AppEnvironment

    /// The clock.
    ///
    /// Injected rather than read from `Date()` at each use, because `now` is
    /// the input to every derived value on this screen — the state, the
    /// countdown, the day rollover, and whether the photographs to show belong
    /// to today. A view model that reads the real clock cannot be tested at a
    /// chosen time at all.
    ///
    /// This was not theoretical. The model took a `now: Date` in its initialiser
    /// and then overwrote it with `Date()` on the first `reload()` — so a test
    /// could construct the exact state it wanted and watch the real clock
    /// replace it a line later. Every one of these tests failed that way first.
    private let clock: @Sendable () -> Date

    private var ticker: Task<Void, Never>?

    init(
        environment: AppEnvironment,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.environment = environment
        self.clock = now

        let current = now()
        let today = DayIdentifier(date: current)
        self.now = current
        self.interval = environment.interval(for: today)
        // Compared against `today` explicitly rather than through `isToday`,
        // which asks the system clock. Same clock as everything else here.
        self.todayMoment = environment.momentStore.facts().last { $0.day == today }
        self.summary = environment.momentStore.summary(today: today)
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
    ///
    /// **Always `nil` since ADR-024.** The countdown was inherited from the era
    /// when the window closed and missing it cost something. It does not any
    /// more — you can photograph at any time (ADR-023) — so a number ticking
    /// like a deadline now sits above a rule where missing the window costs the
    /// streak. It was not left in place neutrally; it was actively untrue.
    ///
    /// Kept as a property rather than deleted so the view and its tests have one
    /// place to look, and so a future decision to bring timing back is a change
    /// here rather than a reconstruction.
    var countdown: String? { nil }

    /// Amber under thirty seconds — the only colour besides white.
    var countdownIsUrgent: Bool { false }

    /// Whether today's moment time may be shown at all.
    ///
    /// **False whenever notifications are authorised** (ADR-024). The
    /// notification and the clock are the same information delivered twice, and
    /// showing both spends the surprise for nothing. The notification is the
    /// alert; the app's job is to have delivered one and then shut up.
    ///
    /// True only when the user has declined notifications, because then the
    /// clock is the *only* way they could ever learn when the moment was —
    /// declining must not mean keeping the app open all day hoping (AGENTS.md §6).
    var showsMomentTime: Bool { !notificationsAuthorized }

    /// Seconds until the moment, or `nil` if it has passed.
    ///
    /// Gated on `showsMomentTime`, so a caller cannot accidentally render a
    /// countdown to someone who is supposed to be surprised. The caller is
    /// expected to check `showsMomentTime` as well — this is a second line of
    /// defence, not the only one, because the cost of leaking the time is that
    /// the moment stops being a moment.
    var timeUntilMoment: TimeInterval? {
        guard showsMomentTime else { return nil }
        let remaining = interval.start.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }

    /// Wall-clock time of today's moment, e.g. "14:37".
    ///
    /// Always computed, never always displayed — the caller asks
    /// `showsMomentTime` first. Keeping the formatting separate from the
    /// decision means the tests can check the value without also having to stand
    /// up a notification state to see it.
    var momentClockTime: String {
        Self.timeFormatter.string(from: interval.start)
    }

    var streak: Int { summary.currentStreak }

    var longestStreak: Int { summary.longestStreak }

    /// "3 days" / "1 day"
    var streakDescription: String {
        "\(streak) \(streak == 1 ? "day" : "days")"
    }

    /// The shutter's label, which differs when a moment already exists today.
    ///
    /// Re-capture is allowed and replaces the day (ADR-011: unlimited retakes,
    /// no deletion limit), so the button says so rather than pretending this
    /// is the first attempt.
    var shutterTitle: String {
        state.isCaptured ? "Capture again" : "Capture"
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
        let current = clock()
        let today = DayIdentifier(date: current)

        // Day rollover: the window and moment both belong to a specific day.
        if today != DayIdentifier(date: now) {
            interval = environment.interval(for: today)
            todayMoment = environment.momentStore.facts().last { $0.day == today }
            summary = environment.momentStore.summary(today: today)
            Task { await loadTodayImages() }
        }
        now = current
    }

    /// Full refresh: state, streak, notification diagnostics, and today's pair.
    func reload() async {
        refreshNow()
        summary = environment.momentStore.summary(today: DayIdentifier(date: now))
        notificationsAuthorized = await refreshAuthorization()
        pendingNotificationCount = await environment.notificationService.pendingCount()
        await loadTodayImages()
    }

    /// Streams today's two photographs back out of Photos.
    ///
    /// Awaited from `reload()` rather than fired off, so a caller that reloads
    /// and immediately renders sees the photographs. The images are small — a
    /// screen-sized downsample, not the original 3–5 MB — because the originals
    /// are already on the device in the user's own library, and copying them
    /// here would be a pointless use of memory (TRD §6.5, ADR-007).
    private func loadTodayImages() async {
        guard let moment = todayMoment,
              let back = moment.assets?.back,
              let front = moment.assets?.front
        else {
            todayImages = nil
            todayMissingFromPhotos = false
            return
        }

        let size = Self.compositeTargetSize
        async let large = environment.photoLibrary.image(for: back, targetSize: size)
        async let inset = environment.photoLibrary.image(for: front, targetSize: size)
        let (largeImage, insetImage) = await (large, inset)

        if let largeImage, let insetImage {
            todayImages = (large: largeImage, inset: insetImage)
            todayMissingFromPhotos = false
        } else {
            todayImages = nil
            // Only call it missing if the assets are genuinely gone. A `nil`
            // because a request has not resolved yet is a different claim, and a
            // moment that still has its photographs must never be described as
            // having lost them.
            let backExists = await environment.photoLibrary.assetExists(back)
            let frontExists = await environment.photoLibrary.assetExists(front)
            todayMissingFromPhotos = !(backExists && frontExists)
        }
    }

    /// The size the composite asks Photos for.
    ///
    /// Derived from the screen rather than hardcoded, so it is right on an
    /// iPhone SE and on a Pro Max without a second number to keep honest.
    private static var compositeTargetSize: CGSize {
        let scale = UIScreen.main.scale
        return CGSize(width: 520 * scale, height: 693 * scale)
    }

    private func refreshAuthorization() async -> Bool {
        await environment.notificationService.authorizationStatus().willDeliver
    }

    // MARK: - Derived helpers

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
