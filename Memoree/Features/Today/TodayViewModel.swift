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

    /// Flashback moments from previous years on today's calendar date ("On This Day").
    private(set) var flashbackMoments: [MomentFacts] = []

    /// Chronological feed items, excluding flashbacks already shown under ON THIS DAY.
    ///
    /// Flashbacks are a subset of `feedMoments`. Showing both sections without this
    /// filter duplicates the same card.
    var chronologicalFeedMoments: [MomentFacts] {
        let flashbackIDs = Set(flashbackMoments.map(\.id))
        return feedMoments.filter { !flashbackIDs.contains($0.id) }
    }

    /// Chronological feed grouped by calendar day for section titles on Today.
    var chronologicalFeedDayGroups: [FeedDayGroup] {
        FeedDayGroup.grouping(chronologicalFeedMoments)
    }

    /// Clock time only — the day title lives on the section, not on every card.
    func feedCardTime(for moment: MomentFacts) -> String {
        moment.capturedAt.formatted(date: .omitted, time: .shortened)
    }

    /// Maximum active image pairs cached in memory for the feed.
    static let maxFeedCacheSize = 15
    private var feedAccessOrder: [UUID] = []

    /// Moment IDs with an in-flight feed image load, so the dual `.task`
    /// attachments on a card do not stampede Photos for the same pair.
    private var feedImageLoadsInFlight: Set<UUID> = []

    /// How many times a nil image load is retried when the assets still exist.
    ///
    /// Photos occasionally hands back nil under memory pressure even though the
    /// asset is present. Without a retry the card stays blank forever: the
    /// `.task` already finished, and neither map was updated so there is no
    /// missing-state UI either.
    private static let transientImageRetryLimit = 2

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
        self.flashbackMoments = environment.momentStore.flashbackMoments(for: current)
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

    /// Whether today's moment has already been captured.
    var isCapturedToday: Bool { todayMoment != nil }

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
            flashbackMoments = environment.momentStore.flashbackMoments(for: current)
            summary = environment.momentStore.summary(today: today)
            Task { await loadTodayImages() }
        }
        now = current
    }

    /// Full refresh: state, streak, notification diagnostics, and today's pair.
    func reload() async {
        refreshNow()
        environment.refreshWidgetSnapshot()
        let today = DayIdentifier(date: now)
        let all = environment.momentStore.facts().sorted { $0.capturedAt > $1.capturedAt }
        feedMoments = all
        let moments = all
            .filter { $0.day == today }
            .sorted { $0.capturedAt < $1.capturedAt }
        todayMoments = moments
        todayMoment = moments.last
        flashbackMoments = environment.momentStore.flashbackMoments(for: now)
        summary = environment.momentStore.summary(today: today)
        // Re-read on every reload, not only at construction: the Settings screen
        // can change the window while the Today screen exists underneath it, and
        // a stale value here would be a Settings screen that appears not to work.
        notificationsAuthorized = await refreshAuthorization()
        pendingNotificationCount = await environment.notificationService.pendingCount()
        // Peek, do not consume: Settings also shows this note, and a one-shot
        // handoff would race whichever screen reloads first. Cleared when the
        // album preference changes (`AppEnvironment.clearAlbumFailure`).
        albumFailure = environment.albumFailureNote
        await loadTodayImages()
    }

    /// Loads image pair lazily for a feed moment.
    ///
    /// Retries when Photos returns nil but both assets still exist. Marks the
    /// card missing when either asset is gone, and tombstones the metadata row
    /// when both are confirmed gone — never touches the Photos library
    /// (ADR-008).
    func loadImage(for moment: MomentFacts) async {
        guard feedImagesMap[moment.id] == nil, !feedMissingMap.contains(moment.id) else { return }
        guard !feedImageLoadsInFlight.contains(moment.id) else { return }
        guard let assets = moment.assets else { return }

        feedImageLoadsInFlight.insert(moment.id)
        defer { feedImageLoadsInFlight.remove(moment.id) }

        let size = Self.compositeTargetSize
        for attempt in 0...Self.transientImageRetryLimit {
            async let large = environment.photoLibrary.image(for: assets.back, targetSize: size)
            async let inset = environment.photoLibrary.image(for: assets.front, targetSize: size)
            let (largeImage, insetImage) = await (large, inset)

            if let largeImage, let insetImage {
                storeFeedImages(momentID: moment.id, large: largeImage, inset: insetImage)
                return
            }

            let backExists = await environment.photoLibrary.assetExists(assets.back)
            let frontExists = await environment.photoLibrary.assetExists(assets.front)

            if backExists && frontExists {
                // Transient miss — leave both maps alone so a later call can
                // retry, and try again inside this load while the card is up.
                if attempt < Self.transientImageRetryLimit { continue }
                return
            }

            if !backExists && !frontExists {
                tombstoneOrphan(moment)
            } else {
                feedMissingMap.insert(moment.id)
                todayMissingMap.insert(moment.id)
            }
            return
        }
    }

    private func storeFeedImages(momentID: UUID, large: UIImage, inset: UIImage) {
        feedImagesMap[momentID] = (large: large, inset: inset)
        todayImagesMap[momentID] = (large: large, inset: inset)

        feedAccessOrder.removeAll { $0 == momentID }
        feedAccessOrder.append(momentID)

        if feedAccessOrder.count > Self.maxFeedCacheSize {
            let todayIDs = Set(todayMoments.map(\.id))
            if let evictCandidate = feedAccessOrder.first(where: { !todayIDs.contains($0) }) {
                feedAccessOrder.removeAll { $0 == evictCandidate }
                feedImagesMap.removeValue(forKey: evictCandidate)
            }
        }
    }

    /// Soft-deletes an orphan whose Photos assets are both gone.
    ///
    /// Metadata only — Memoree never deletes from the user's library
    /// (ADR-008 / AGENTS.md §8). Local lists update only when the store write
    /// succeeds; a failed tombstone leaves the missing-from-Photos treatment.
    private func tombstoneOrphan(_ moment: MomentFacts) {
        guard let row = environment.momentStore.allMoments
            .first(where: { $0.id == moment.id })
        else { return }
        do {
            try environment.momentStore.delete(row)
        } catch {
            feedMissingMap.insert(moment.id)
            todayMissingMap.insert(moment.id)
            return
        }

        feedMoments.removeAll { $0.id == moment.id }
        todayMoments.removeAll { $0.id == moment.id }
        flashbackMoments.removeAll { $0.id == moment.id }
        if todayMoment?.id == moment.id {
            todayMoment = todayMoments.last
        }
        feedImagesMap.removeValue(forKey: moment.id)
        todayImagesMap.removeValue(forKey: moment.id)
        feedMissingMap.remove(moment.id)
        todayMissingMap.remove(moment.id)
        feedAccessOrder.removeAll { $0 == moment.id }

        let today = DayIdentifier(date: now)
        summary = environment.momentStore.summary(today: today)
        if let latestID = todayMoment?.id, let pair = todayImagesMap[latestID] {
            todayImages = pair
            todayMissingFromPhotos = false
        } else {
            todayImages = nil
            todayMissingFromPhotos = false
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

    /// User-friendly label for flashback items (e.g. "1 year ago today").
    func flashbackDescription(for moment: MomentFacts) -> String {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)
        let momentYear = calendar.component(.year, from: moment.capturedAt)
        let diff = max(1, currentYear - momentYear)
        return "\(diff) \(diff == 1 ? "year" : "years") ago today"
    }

    // MARK: - Same-day flipbook (ADR-038)

    /// Moments on today's calendar month/day across every year, oldest first.
    ///
    /// Includes today when captured. Used for the flipbook export, not for the
    /// ON THIS DAY cards (those stay prior-year-only via `flashbackMoments`).
    var sameDayAcrossYearsMoments: [MomentFacts] {
        SameDayFlipbook.moments(from: feedMoments, matching: now)
    }

    /// True when the selection spans at least two calendar years.
    var canExportSameDayFlipbook: Bool {
        SameDayFlipbook.isExportable(sameDayAcrossYearsMoments)
    }

    private(set) var isExportingSameDayFlipbook = false
    private(set) var sameDayFlipbookExportError: String?

    /// Exports the same-day-across-years selection through the Archive flipbook path.
    ///
    /// Device Photos write — covered by `InMemoryPhotoLibraryService` in unit
    /// tests; real encoding is device-only via `PhotoKitLibrary`.
    func exportSameDayFlipbook() async -> Bool {
        let moments = sameDayAcrossYearsMoments
        guard SameDayFlipbook.isExportable(moments), !isExportingSameDayFlipbook else {
            return false
        }
        isExportingSameDayFlipbook = true
        sameDayFlipbookExportError = nil
        defer { isExportingSameDayFlipbook = false }

        do {
            _ = try await environment.photoLibrary.exportFlipbookVideo(
                for: moments,
                framesPerSecond: 2
            )
            return true
        } catch {
            sameDayFlipbookExportError = error.localizedDescription
            return false
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
        var orphaned: [MomentFacts] = []

        for moment in todayMoments {
            guard let assets = moment.assets else {
                continue
            }

            var loaded: (UIImage, UIImage)?
            for attempt in 0...Self.transientImageRetryLimit {
                async let large = environment.photoLibrary.image(for: assets.back, targetSize: size)
                async let inset = environment.photoLibrary.image(for: assets.front, targetSize: size)
                let (largeImage, insetImage) = await (large, inset)

                if let largeImage, let insetImage {
                    loaded = (largeImage, insetImage)
                    break
                }

                let backExists = await environment.photoLibrary.assetExists(assets.back)
                let frontExists = await environment.photoLibrary.assetExists(assets.front)
                if backExists && frontExists {
                    if attempt < Self.transientImageRetryLimit { continue }
                    break
                }
                if !backExists && !frontExists {
                    orphaned.append(moment)
                } else {
                    newMissingMap.insert(moment.id)
                }
                break
            }

            if let loaded {
                newImagesMap[moment.id] = (large: loaded.0, inset: loaded.1)
            }
        }

        for orphan in orphaned {
            tombstoneOrphan(orphan)
        }

        // Re-read the live today list after any tombstones above.
        let liveTodayIDs = Set(todayMoments.map(\.id))
        newImagesMap = newImagesMap.filter { liveTodayIDs.contains($0.key) }
        newMissingMap = newMissingMap.intersection(liveTodayIDs)

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
