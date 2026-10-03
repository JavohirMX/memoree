import Foundation
import SwiftData
import SwiftUI

/// Composition root.
///
/// Services are constructed once here and handed to the views that need them.
/// Nothing else in the app reaches for a singleton — that is what keeps the
/// service protocols fakable in tests (AGENTS.md §3).
@MainActor
@Observable
final class AppEnvironment {

    let container: ModelContainer
    let momentStore: MomentStore
    let momentScheduler: MomentScheduler
    let notificationService: NotificationService

    /// The production capture service. Built lazily so the first launch does
    /// not open a camera session before the user has asked for one.
    let photoLibrary: PhotoLibraryService
    private var _captureService: CapturePhotoService?

    /// Haptics, injected like every other service.
    ///
    /// A protocol rather than a direct `UIImpactFeedbackGenerator` call, because
    /// a Taptic Engine cannot be observed: "the shutter buzzes" would otherwise
    /// be untestable, and the three events are exactly the kind of detail that
    /// drifts — one view buzzing on shutter, the other not.
    let haptics: HapticFeedback

    /// The capture service.
    ///
    /// `lazy` because constructing a `CaptureSessionController` creates an
    /// `AVCaptureSession`, and doing that on launch — before the user has
    /// granted camera access or opened the camera screen — is work with no
    /// purpose and a real cost in power on first run.
    var captureService: CapturePhotoService {
        if let existing = _captureService { return existing }
        let created = SequentialCaptureService()
        _captureService = created
        return created
    }

    /// Resolved lazily so the first launch does not block on Keychain I/O.
    private var didRefreshHorizon = false

    init(
        container: ModelContainer? = nil,
        momentScheduler: MomentScheduler? = nil,
        notificationService: NotificationService? = nil,
        photoLibrary: PhotoLibraryService? = nil,
        captureService: CapturePhotoService? = nil,
        haptics: HapticFeedback? = nil
    ) throws {
        let resolved = try container ?? Persistence.makeContainer()
        self.container = resolved

        let context = ModelContext(resolved)
        self.momentStore = MomentStore(context: context)
        // Injectable because this is the composition root, and a root that
        // cannot be given a fake is a root that cannot be tested: the default
        // reads the Keychain and derives a real moment time, so any test of the
        // Today screen would be asserting on whatever the Keychain happened to
        // hold on that run.
        self.momentScheduler = momentScheduler
            ?? LocalMomentScheduler(secret: InstallSecret())
        self.notificationService = notificationService
            ?? UserNotificationService(scheduler: self.momentScheduler)
        self.photoLibrary = photoLibrary ?? PhotoKitLibrary()
        self._captureService = captureService
        self.haptics = haptics ?? SystemHapticFeedback()

        // **Every DEBUG affordance is here, and the helpers they call are in a second
        // block that ends at the `#endif` below `seedSyntheticArchive`.** Both have
        // to be DEBUG, and getting that wrong is invisible in Debug: the helpers
        // were briefly outside a block, so Debug built clean and **Release failed**,
        // because `allImageAssetIdentifiers()` and `attachPhotographsForSeeding`
        // are themselves DEBUG-only. Every gate this project had ever run was a
        // Debug gate, which is why it went unnoticed. `AGENTS.md` §12 asks for
        // zero warnings; it does not say "in the configuration you usually build".
        //
        // **Build Release before believing a change compiles.**
        #if DEBUG
        // Development affordance: skip first-run so the Today screen can be
        // inspected without walking the permission prompts. Debug builds only,
        // so it can never ship.
        if ProcessInfo.processInfo.arguments.contains("-MemoreeSkipOnboarding") {
            momentStore.settings().onboardingComplete = true
        }

        // Development affordance: seed a synthetic archive, so the Phase 6 exit
        // criterion is reachable at all.
        //
        // **This exists because the exit criterion is unreachable without it.**
        // "A 500-moment library scrolls smoothly" cannot be checked with three
        // moments in it, and the alternative to a seeder is 500 real captures —
        // which is a day of the user's life to test a scroll. There is no UI test
        // target in this project, and adding one is a larger decision than the
        // phase deserved.
        //
        //   xcodebuild ... -MemoreeSeedMoments 500     (or launch with the argument)
        //
        // The rows carry **no asset identifiers**, deliberately. Seeding real
        // photographs would mean writing 500 pairs into the user's actual camera
        // roll, which is the user's library and which Memoree has add-only
        // authorisation and can therefore never clean up (ADR-008). Synthetic
        // rows give the grid, the scroll and the prefetcher the shape they need
        // to be measured against, and the cells correctly report "no photographs
        // on record" rather than pretending.
        for argument in ProcessInfo.processInfo.arguments {
            guard argument.hasPrefix("-MemoreeSeedMoments") else { continue }
            let count = Int(argument.split(separator: "=").last ?? "") ?? 500
            seedSyntheticArchive(count: min(max(count, 0), 2_000))
        }

        // `-MemoreeSeedWithPhotos` attaches **real** photographs to the seeded
        // rows, so the archive and Today screens can be looked at with pictures
        // in them rather than as an empty grid.
        //
        // **Only ever on a simulator, and the guard is a precondition rather than
        // a `guard`.** `-MemoreeSeedMoments` deliberately writes no asset
        // identifiers, because seeding real photographs would write into the
        // *user's* camera roll and Memoree has add-only authorisation and can
        // never clean them up (ADR-008). On a simulator that library is synthetic
        // and disposable, so the objection does not apply — and the layout audit
        // needs actual pixels in the cells, since a grid of empty rectangles
        // exercises none of the geometry that matters: the `scaledToFit` mat, the
        // front inset sized from the short side, and the composite renderer.
        //
        // The images are read out of the simulator's own library rather than
        // bundled, so nothing ships and nothing is downloaded. `simctl addmedia`
        // puts them there first.
        if ProcessInfo.processInfo.arguments.contains("-MemoreeSeedWithPhotos") {
            // **A `precondition` and not a `guard`**, because the alternative on
            // hardware is the most literal available violation of ADR-008: an
            // archive pointing at assets the user never captured, written by a flag
            // someone typed on a phone by mistake. Trap loudly instead.
            precondition(Self.isRunningOnASimulator,
                         "-MemoreeSeedWithPhotos writes real assets and must never run on a device")
            attachSimulatorPhotographsToSeededArchive()
        }
        #endif
    }

    #if DEBUG
    /// Whether this process is a simulator, by the one test that does not lie.
    ///
    /// `#if targetEnvironment(simulator)` is a **compile-time** answer, so it
    /// cannot guard a runtime flag: a Debug build compiled for the simulator is
    /// also what gets installed on a device during a device run. Reading
    /// `TARGET_DEVICE_SIMULATOR` at runtime is the check that means what it says.
    private static var isRunningOnASimulator: Bool {
        ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
            || ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil
    }

    /// Points the newest seeded moments at real photographs from the library.
    ///
    /// Alternates portrait and landscape so both geometries are on screen at
    /// once — which is the whole point of the audit, since the archive cell uses
    /// `scaledToFit` with a mat and the portrait case is the one that could hide a
    /// landscape regression.
    private func attachSimulatorPhotographsToSeededArchive() {
        let fetched = photoLibrary.allImageAssetIdentifiers()
        guard !fetched.isEmpty else {
            print("Memoree seed: -MemoreeSeedWithPhotos found no assets. "
                  + "Run `xcrun simctl addmedia <udid> …` first.")
            return
        }

        // Alternating so a single screenshot shows both. Two of each is enough:
        // this is for looking at, not for measuring a grid.
        let back = [fetched[0 % fetched.count], fetched[2 % fetched.count]]
        let front = [fetched[1 % fetched.count], fetched[3 % fetched.count]]

        let moments = momentStore.allMoments      // already newest-first
        let targets = Array(moments.prefix(4).filter { $0.backAssetIdentifier == nil })
        guard !targets.isEmpty else {
            print("Memoree seed: seeded moments already carry photographs")
            return
        }
        // A managed-object edit does not reach disk on its own, so the store has to
        // save — and `save()` is private because the store owns when it persists.
        // The whole operation therefore lives in the store, and this reads like the
        // one call it is rather than an edit here plus a hopeful save elsewhere.
        try? momentStore.attachPhotographsForSeeding(to: targets, back: back, front: front)
        print("Memoree seed: attached photographs to \(targets.count) seeded moment(s)")
    }

    /// Inserts `count` moments on consecutive past days, with no photographs.
    ///
    /// **This `#if` wraps the seeder, `isRunningOnASimulator` and
    /// `attachSimulatorPhotographsToSeededArchive` together**, so a Release build
    /// contains none of it and `allImageAssetIdentifiers()` — which is itself
    /// DEBUG-only on the protocol — is never named outside a Debug build. That is
    /// not tidiness: the first version nested a *second* `#if` around the call
    /// site, and the outer block's `#endif` was left matching the inner one, so
    /// Release compiled against methods that did not exist in it.
    ///
    /// `-1` days is the *newest* day, so the rows land in the past and cannot
    /// collide with the one-per-day invariant for today. `DayRecord`s are not
    /// written: without them `interval(for:)` re-derives, which is the path a
    /// fresh install takes and therefore the one worth exercising.
    private func seedSyntheticArchive(count: Int) {
        let calendar = Calendar.current
        let today = DayIdentifier(date: Date())
        let duration: TimeInterval = 120

        for offset in 1...max(count, 1) {
            let day = today.offset(by: -offset, calendar: calendar)
            guard momentStore.moment(for: day) == nil else { continue }

            // A plausible spread of capture times, so the grid is not a column of
            // identical timestamps and the busiest-hour statistic has something
            // to chew on if it is opened.
            let minuteOfDay = (offset * 37) % (12 * 60)
            let start = day.date.addingTimeInterval(Double(11 * 60 + minuteOfDay) * 60)
            let capturedAt = start.addingTimeInterval(duration / 2)
            // Every fourth day off-window, so the streak arithmetic is not
            // looking at a perfect record — which is the boring case.
            let isLate = offset % 4 == 0

            // `try?` and discarding: a row that will not insert is a day this
            // seeder skips, not a launch failure. The alternative — a thrown
            // error out of `init` — would make a debug affordance capable of
            // bricking the app.
            _ = try? momentStore.record(
                day: day,
                interval: MomentInterval(start: start, end: start.addingTimeInterval(duration)),
                capturedAt: isLate ? start.addingTimeInterval(duration * 8) : capturedAt,
                retakeCount: offset % 3,
                backAssetIdentifier: nil,
                frontAssetIdentifier: nil
            )
        }
    }
    #endif

    // MARK: - Moment resolution

    /// The moment interval for `day`.
    ///
    /// A previously resolved and persisted day always wins, so changing the
    /// moment window mid-day cannot move a notification that has already been
    /// scheduled (docs/TRD.md §4.1).
    func interval(for day: DayIdentifier) -> MomentInterval {
        let settings = momentStore.settings()

        if let record = momentStore.dayRecord(for: day) {
            return MomentInterval(
                start: record.momentStart,
                end: record.momentStart.addingTimeInterval(settings.captureDuration)
            )
        }

        let derived = momentScheduler.momentInterval(
            for: day,
            window: settings.timeWindow,
            windowDuration: settings.captureDuration
        )
        try? momentStore.saveDayRecord(day: day, momentStart: derived.start)
        return derived
    }

    /// Records an accepted pair as a moment.
    ///
    /// Built here, and only here, because this is the one place that can see
    /// both the store and the derived window. The camera screen cannot reach
    /// `Persistence` to do it itself, and a `Services` type may not import
    /// `Persistence` at all (AGENTS.md §3) — so the operation is handed across
    /// as a closure rather than reached for.
    ///
    /// The window is resolved **here rather than by the caller** because
    /// lateness is derived from it inside `MomentStore.record`, and the whole
    /// point of that derivation is that no caller can disagree with it. Passing
    /// an interval in from the camera would put that guarantee one refactor away
    /// from being lost.
    func makeMomentRecorder() -> MomentRecorder {
        let store = momentStore
        let calendar = Calendar.current

        return { capture in
            let day = DayIdentifier(date: capture.capturedAt, calendar: calendar)
            try store.record(
                day: day,
                interval: self.interval(for: day),
                capturedAt: capture.capturedAt,
                retakeCount: capture.retakeCount,
                backAssetIdentifier: capture.assets.back,
                frontAssetIdentifier: capture.assets.front
            )
        }
    }

    /// A moment reminder was tapped and the camera should be presented.
    ///
    /// There is no URL scheme to route through — `Info.plist` deliberately
    /// registers none, because Memoree makes no network calls (AGENTS.md §2.1) —
    /// so the tap arrives from `MemoreeAppDelegate` and lands here as a flag.
    ///
    /// A flag rather than something the view reads once, because delivery is not
    /// ordered against the scene: a cold launch sets it before `TodayView` has
    /// registered an observer, and a foreground delivery sets it long after.
    /// One flag plus `consumeCameraRequest()` covers both, and consuming it means
    /// a later re-presentation of the screen does not re-open the camera for a
    /// tap the user made minutes ago.
    private(set) var pendingCameraRequest = false

    /// Called from the notification delegate.
    func requestCamera() {
        pendingCameraRequest = true
    }

    /// A note about the last moment that could not be filed into the album.
    ///
    /// **Stored here and read once**, because the camera screen has already been
    /// dismissed by the time anyone could react to it, and there is no other
    /// object alive that outlives both. Consuming it clears it, so a footer that
    /// reports it does not report it forever.
    private var pendingAlbumFailure: String?

    /// Records a failure from the capture screen's album add.
    func noteAlbumFailure(_ message: String) {
        pendingAlbumFailure = message
    }

    /// Takes the pending album failure, if any, and clears it.
    func consumeAlbumFailure() -> String? {
        defer { pendingAlbumFailure = nil }
        return pendingAlbumFailure
    }

    func consumeCameraRequest() {
        pendingCameraRequest = false
    }

    // An earlier version of the archive took a "scroll to this day" request
    // through the environment, so tapping today's composite could open the grid
    // at today rather than at the top. It was thirty lines for no behaviour:
    // the grid is newest-first, so a moment captured today is *already* the first
    // cell. A `DayIdentifier` would have been the right payload — an index goes
    // stale before the sheet presents, and a `Moment` is not `Sendable` — but
    // the request itself was unnecessary, so `TodayView` just opens the archive
    // and the ordering does the rest.

    // MARK: - Debug

    /// Rebuilds the camera session from scratch.
    ///
    /// `mediaServicesWereReset` is the one failure in the camera stack that
    /// raises no error, fires no delegate callback, and leaves no log line — the
    /// preview simply freezes. It is also the most common cause of "my camera
    /// app froze" in the field, which means the recovery path is the part of this
    /// code that most needs exercising and least gets to (TRD §5.5, AGENTS.md §6).
    ///
    /// Reachable from a DEBUG-only row in the Today footer for exactly that
    /// reason. The earlier version exposed `CameraViewModel
    /// .simulateMediaServicesReset()` and **nothing called it** — a hook only a
    /// test could reach, guarding a path no user would ever see. This one goes
    /// through the real service, so what it exercises is the production rebuild.
    func simulateMediaServicesReset() async {
        try? await captureService.rebuildSession()
    }

    // MARK: - Horizon maintenance

    /// Tops up the notification horizon and persists newly resolved days.
    ///
    /// Safe to call on every launch and every foreground. Declined
    /// notifications are a supported state, not an error: the app stays fully
    /// usable, it just cannot remind you (AGENTS.md §9).
    func refreshHorizonIfNeeded(force: Bool = false) async {
        // `shouldRefill` is awaited before the guard rather than inside it: an
        // `async` call cannot appear in an autoclosure.
        let isDue: Bool
        if force || !didRefreshHorizon {
            isDue = true
        } else {
            isDue = await notificationService.pendingCount()
                < UserNotificationService.refillThreshold
        }
        guard isDue else { return }

        didRefreshHorizon = true

        let settings = momentStore.settings()
        let window = settings.timeWindow
        let duration = settings.captureDuration

        // Persist each day's resolved moment so the schedule is stable even if
        // the horizon is rebuilt.
        let today = DayIdentifier(date: Date())
        for offset in 0..<UserNotificationService.horizonDays {
            let day = today.offset(by: offset)
            guard momentStore.dayRecord(for: day) == nil else { continue }
            let start = momentScheduler.momentStart(for: day, window: window, windowDuration: duration)
            try? momentStore.saveDayRecord(day: day, momentStart: start)
        }

        try? await notificationService.refreshHorizon(
            window: window,
            windowDuration: duration
        )
    }

    // MARK: - Changing the window

    /// Applies a new moment window, starting tomorrow.
    ///
    /// **A window change is a real operation, not a settings write.** Every day
    /// in the horizon has a persisted `DayRecord`, and `interval(for:)` always
    /// prefers a persisted record over the configured window so that a
    /// notification cannot move retroactively (TRD §4.1, FR-2). Which means
    /// writing the new window to settings and stopping there would change
    /// *nothing at all* for the next 45 days — a control that silently does
    /// nothing, and the exact failure ADR-023 was written about.
    ///
    /// So the future is re-derived and the past is left alone:
    ///
    /// - **Today keeps its resolved moment**, even if it now falls outside the
    ///   new window. It may already have been notified, and re-rolling it would
    ///   break FR-2 for the one day the user can actually see.
    /// - **Tomorrow onward is re-derived** from the new window. Any
    ///   `DayRecord` for those days is discarded so the derivation runs again.
    /// - **The horizon is refilled immediately**, because the persisted times
    ///   for the next 45 days are what the notification centre is holding.
    ///
    /// Re-deriving a day also has to remove its pending notification, since
    /// `refreshHorizon` re-adds by identifier and a stale request for the same
    /// identifier would otherwise leave two notifications for one day. That is
    /// handled by `NotificationService.refreshHorizon`, which removes before it
    /// adds and never calls `removeAllPendingNotificationRequests` (AGENTS.md §9).
    ///
    /// - Parameter settings: the row to mutate. It is saved here so the caller
    ///   cannot save the window and forget to re-derive.
    /// - Returns: whether the window actually changed, so a no-op edit does not
    ///   churn 45 days of records and 45 notification requests.
    @discardableResult
    func updateWindow(_ newWindow: TimeWindow) async -> Bool {
        let settings = momentStore.settings()
        guard settings.timeWindow != newWindow else { return false }

        settings.timeWindow = newWindow
        do {
            try momentStore.saveSettings(settings)
        } catch {
            // The store refused. Leaving the row untouched means the horizon
            // still matches what is persisted, which is the consistent state.
            return false
        }

        // Today is deliberately excluded. See above.
        let today = DayIdentifier(date: Date())
        // `try?` because a failure here is recoverable in a way the settings
        // write above was not: the window is saved, the days that could not be
        // cleared keep their old times, and the next launch re-derives them.
        // Discarding a record and failing to save are different failures, and
        // only the second one needs handling here.
        _ = try? momentStore.discardDayRecords(from: today.offset(by: 1))

        await refreshHorizonIfNeeded(force: true)
        return true
    }
}
