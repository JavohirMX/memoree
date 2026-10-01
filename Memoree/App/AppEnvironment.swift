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
        captureService: CapturePhotoService? = nil
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

        #if DEBUG
        // Development affordance: skip first-run so the Today screen can be
        // inspected without walking the permission prompts. Debug builds only,
        // so it can never ship.
        if ProcessInfo.processInfo.arguments.contains("-MemoreeSkipOnboarding") {
            momentStore.settings().onboardingComplete = true
        }
        #endif
    }

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
