import Foundation
import Observation
import SwiftUI

/// Drives the Today screen.
///
/// Owns the only ticking clock in the app. Rather than a `Timer` per view, a
/// single timer updates `now` once a second while the screen is on-screen, and
/// the state is re-derived from it. That gives every derived value one source of
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
    private(set) var todayMoments: [MomentFacts] = []
    private(set) var todayImagesMap: [UUID: (large: UIImage, inset: UIImage)] = [:]
    private(set) var todayMissingMap: Set<UUID> = []

    /// All moments for the feed, newest first.
    private(set) var feedMoments: [MomentFacts] = []
    private(set) var feedImagesMap: [UUID: (large: UIImage, inset: UIImage)] = [:]
    private(set) var feedMissingMap: Set<UUID> = []

    /// Today's photographs are gone from Photos.
    ///
    /// The user may have deleted them deliberately — that is their library, and
    /// Memoree never reached back into it (ADR-008). The moment is still a real
    /// moment and still in the archive; it just has nothing to show, and saying
    /// so beats rendering an empty black rectangle that reads as a bug.
    private(set) var todayMissingFromPhotos = false

    /// Diagnostics for the Settings screen: how many notifications are pending.
    private(set) var pendingNotificationCount = 0

    /// A recent moment was saved but not filed into the album.
    ///
    /// **Surfaced on Today rather than only in Settings** because the user has to
    /// open the camera to trigger it, and by the time they reach Settings the
    /// moment is over. The photographs are safe; what failed was an organisation
    /// of them, and saying so once here costs one line.
    private(set) var albumFailure: String?

    private let environment: AppEnvironment

    /// The clock.
    ///
    /// Injected rather than read from `Date()` at each use, because `now` is
    /// the input to every derived value on this screen — the state, the time
    /// until the moment, the day rollover, and whether the photographs to show
    /// belong to today. A view model that reads the real clock cannot be tested
    /// at a chosen time at all.
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
        let allMoments = environment.momentStore.facts()
            .sorted { $0.capturedAt > $1.capturedAt }
        self.feedMoments = allMoments
        let moments = allMoments
            .filter { $0.day == today }
            .sorted { $0.capturedAt < $1.capturedAt }
        self.todayMoments = moments
        self.todayMoment = moments.last
        self.summary = environment.momentStore.summary(today: today)
    }

    // MARK: - Derived state

    var state: MomentState {
        MomentStateResolver.resolve(
            now: now,
            interval: interval,
            todayMoment: todayMoment
        )
    }

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
        Self.clockTime(for: interval.start)
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
            let all = environment.momentStore.facts().sorted { $0.capturedAt > $1.capturedAt }
            feedMoments = all
            let moments = all
                .filter { $0.day == today }
                .sorted { $0.capturedAt < $1.capturedAt }
            todayMoments = moments
            todayMoment = moments.last
            summary = environment.momentStore.summary(today: today)
            Task { await loadTodayImages() }
        }
        now = current
    }

    /// Full refresh: state, streak, notification diagnostics, and today's pair.
    func reload() async {
        refreshNow()
        let today = DayIdentifier(date: now)
        let all = environment.momentStore.facts().sorted { $0.capturedAt > $1.capturedAt }
        feedMoments = all
        let moments = all
            .filter { $0.day == today }
            .sorted { $0.capturedAt < $1.capturedAt }
        todayMoments = moments
        todayMoment = moments.last
        summary = environment.momentStore.summary(today: today)
        // Re-read on every reload, not only at construction: the Settings screen
        // can change the window while the Today screen exists underneath it, and
        // a stale value here would be a Settings screen that appears not to work.
        notificationsAuthorized = await refreshAuthorization()
        pendingNotificationCount = await environment.notificationService.pendingCount()
        // Cleared on every reload: the album may have been fixed by the user, or
        // the add may have been turned off in Settings, and a footer that reports
        // a problem the user has already resolved is noise.
        albumFailure = environment.consumeAlbumFailure()
        await loadTodayImages()
    }

    /// Loads image pair lazily for a feed moment.
    func loadImage(for moment: MomentFacts) async {
        guard feedImagesMap[moment.id] == nil, !feedMissingMap.contains(moment.id) else { return }
        guard let assets = moment.assets else { return }
        let size = Self.compositeTargetSize
        async let large = environment.photoLibrary.image(for: assets.back, targetSize: size)
        async let inset = environment.photoLibrary.image(for: assets.front, targetSize: size)
        let (largeImage, insetImage) = await (large, inset)
        if let largeImage, let insetImage {
            feedImagesMap[moment.id] = (large: largeImage, inset: insetImage)
            todayImagesMap[moment.id] = (large: largeImage, inset: insetImage)
        } else {
            let backExists = await environment.photoLibrary.assetExists(assets.back)
            let frontExists = await environment.photoLibrary.assetExists(assets.front)
            if !(backExists && frontExists) {
                feedMissingMap.insert(moment.id)
                todayMissingMap.insert(moment.id)
            }
        }
    }

    /// User-friendly relative date header for feed items.
    func relativeHeader(for moment: MomentFacts) -> String {
        let calendar = Calendar.current
        let time = moment.capturedAt.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(moment.capturedAt) {
            return "Today · \(time)"
        } else if calendar.isDateInYesterday(moment.capturedAt) {
            return "Yesterday · \(time)"
        } else {
            let dateStr = moment.capturedAt.formatted(.dateTime.month(.abbreviated).day())
            return "\(dateStr) · \(time)"
        }
    }

    /// Streams today's photographs back out of Photos.
    private func loadTodayImages() async {
        guard !todayMoments.isEmpty else {
            todayImages = nil
            todayImagesMap = [:]
            todayMissingMap = []
            todayMissingFromPhotos = false
            return
        }

        let size = Self.compositeTargetSize
        var newImagesMap: [UUID: (large: UIImage, inset: UIImage)] = [:]
        var newMissingMap = Set<UUID>()

        for moment in todayMoments {
            guard let assets = moment.assets else {
                continue
            }

            async let large = environment.photoLibrary.image(for: assets.back, targetSize: size)
            async let inset = environment.photoLibrary.image(for: assets.front, targetSize: size)
            let (largeImage, insetImage) = await (large, inset)

            if let largeImage, let insetImage {
                newImagesMap[moment.id] = (large: largeImage, inset: insetImage)
            } else {
                let backExists = await environment.photoLibrary.assetExists(assets.back)
                let frontExists = await environment.photoLibrary.assetExists(assets.front)
                if !(backExists && frontExists) {
                    newMissingMap.insert(moment.id)
                }
            }
        }

        todayImagesMap = newImagesMap
        todayMissingMap = newMissingMap
        for (k, v) in newImagesMap { feedImagesMap[k] = v }
        feedMissingMap.formUnion(newMissingMap)

        if let latestID = todayMoment?.id, let pair = newImagesMap[latestID] {
            todayImages = pair
            todayMissingFromPhotos = false
        } else if let latestID = todayMoment?.id, newMissingMap.contains(latestID) {
            todayImages = nil
            todayMissingFromPhotos = true
        } else {
            todayImages = nil
            todayMissingFromPhotos = false
        }
    }

    /// The size the composite asks Photos for.
    ///
    /// Derived from the screen rather than hardcoded, so it is right on an
    /// iPhone SE and on a Pro Max without a second number to keep honest.
    private static var compositeTargetSize: CGSize {
        let scale = UIScreen.main.scale
        let side = max(Theme.Size.detailImageWidth, Theme.Size.detailImageHeight)
        return CGSize(
            width: side * scale,
            height: side * scale
        )
    }

    private func refreshAuthorization() async -> Bool {
        await environment.notificationService.authorizationStatus().willDeliver
    }

    // MARK: - Derived helpers

    /// The moment's clock time, in the user's own format.
    ///
    /// **`.formatted(time: .shortened)`, not `"HH:mm"`.**
    ///
    /// This was a `DateFormatter` with `dateFormat = "HH:mm"` — always 24-hour,
    /// always a colon, ignoring the device entirely. It reached the user in two
    /// places, including **the one screen and the one number they act on**: "Next
    /// moment at 17:59", and the footer row "Moment today · 17:59". A user in the
    /// United States read a 24-hour clock on the screen that tells them when to be
    /// ready, while eight other screens in the same app — Stats, the archive, the
    /// detail view — said "11:38 AM" in the locale's own way.
    ///
    /// `StatsViewModel` had already been through this exact bug and its comment
    /// records the rule: *matching whatever the device does everywhere else*. This
    /// file had simply not been converted. That is the same shape as the
    /// twenty-moment capture fix — a correct change made where the symptom
    /// appeared and nowhere else.
    private static func clockTime(for date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
