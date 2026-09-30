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
        notificationService: NotificationService? = nil,
        photoLibrary: PhotoLibraryService? = nil,
        captureService: CapturePhotoService? = nil
    ) throws {
        let resolved = try container ?? Persistence.makeContainer()
        self.container = resolved

        let context = ModelContext(resolved)
        self.momentStore = MomentStore(context: context)
        self.momentScheduler = LocalMomentScheduler(secret: InstallSecret())
        self.notificationService = notificationService ?? UserNotificationService(scheduler: momentScheduler)
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
}
