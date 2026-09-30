import Foundation
import QuartzCore
import SwiftUI

/// Drives the camera screen.
///
/// The `@MainActor` observable adapter between the capture service and the
/// view. The service publishes no SwiftUI state and knows no UI exists; this
/// type observes it and exposes something a view can render (AGENTS.md §3, §5).
///
/// Deliberately does **not** import AVFoundation. `CameraPosition` and
/// `CapturedPhoto` are Memoree's own types, and the preview arrives as a
/// `CALayer` (ADR-018).
///
/// ## The sequence is the user's
///
/// One shutter press, one photograph. The **second** press is what switches the
/// camera, and it is a user-visible event with a live preview on the other side
/// of it (ADR-021). An earlier version did the whole thing in one call, taking
/// both photographs without asking — which also made "reshoot just this one"
/// inexpressible.
@MainActor
@Observable
final class CameraViewModel {

    /// What the camera screen is doing.
    enum Phase: Equatable {
        /// Session not started, or permission not yet resolved.
        case idle
        /// Session starting.
        case starting
        /// Live preview, shutter armed. At least one half is outstanding.
        case shooting
        /// A capture or a camera switch is in flight. The shutter is disabled.
        case working
        /// Both photographs exist. Tapping the small one swaps which is large.
        case review
        /// The pair was written to Photos. Terminal for this presentation.
        case saved
        /// A recoverable failure. Carries the message and whether to retry.
        case failed(message: String, isRetryable: Bool)
        /// Permission was denied. A terminal state, but not an error — the
        /// archive and settings remain fully usable.
        case permissionDenied
    }

    // MARK: - Observable state

    private(set) var phase: Phase = .idle

    /// The photographs taken so far, keyed by camera.
    private(set) var captured: [CameraPosition: CapturedPhoto] = [:]

    /// Which camera is live right now.
    private(set) var livePosition: CameraPosition = .back

    /// Which camera opened this moment. Random, and held for the session.
    private(set) var firstPosition: CameraPosition = .back

    /// Which photograph is drawn large in the review composite.
    ///
    /// Starts as the *second* one taken, which is the photograph the user was
    /// looking at when they finished. Tapping the small one swaps them.
    private(set) var prominentPosition: CameraPosition?

    /// How many shutter presses have been made, across the whole moment.
    ///
    /// BeReal shows friends this number. With no feed it is a private statistic
    /// rather than a social signal — a high count means a busy or awkward
    /// moment, which is arguably more interesting (ADR-011).
    private(set) var retakeCount = 0

    /// The live preview surface, installed by `CameraPreview` (ADR-018).
    private(set) var previewLayer: CALayer?

    // MARK: - Dependencies

    private let service: CapturePhotoService
    private let photoLibrary: PhotoLibraryService

    /// Persists an accepted pair as a moment.
    ///
    /// `nil` means the camera screen stops at the library write — which is what
    /// SwiftUI previews and any test not exercising the full loop want. It is a
    /// legal state rather than a failure: a moment in Photos with no archive
    /// row is exactly what a half-finished commit looks like, and the recovery
    /// path below already knows how to describe one.
    private let record: MomentRecorder?

    /// Injected in tests so the camera order can be made deterministic.
    /// Production randomises it per moment.
    private let chooseFirstCamera: () -> CameraPosition

    /// The clock.
    ///
    /// Injected because a moment's time is a load-bearing fact — it decides
    /// lateness, and therefore whether the streak grows (ADR-009) — and a test
    /// that reaches for `Date()` is asserting on when it happened to run.
    private let now: @Sendable () -> Date

    // MARK: - Commit state

    /// The identifiers the pair was written under, once it has been.
    ///
    /// Memoised, and the reason `retry()` does not write to Photos twice. A
    /// moment is two steps — write the assets, then record the row — and only
    /// the second can fail after the first has succeeded. Forgetting that would
    /// leave a duplicate pair in the user's camera roll every time the archive
    /// write hiccupped.
    private var writtenAssets: SavedAssetPair?

    /// Whether the current failure came from a commit rather than a capture.
    ///
    /// Without this, `retry()` cannot tell the two apart: a failed *write* and
    /// a failed *capture* both leave `writtenAssets` nil and the pair intact,
    /// and answering "re-arm the shutter" for a failed commit sends the user
    /// back to the camera with photographs already on disk. One boolean, and
    /// the retry rule stops needing case analysis.
    private var isCommitting = false

    /// When the most recent photograph was taken.
    ///
    /// The moment is complete when the last outstanding half is shot, so this
    /// is the capture that closed it — and after a reshoot, the reshoot, which
    /// is when the pair was most recently whole. See `CommittedCapture.capturedAt`.
    private var lastCaptureAt: Date?

    // MARK: - Init

    init(
        service: CapturePhotoService,
        photoLibrary: PhotoLibraryService,
        record: MomentRecorder? = nil,
        chooseFirstCamera: (() -> CameraPosition)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.photoLibrary = photoLibrary
        self.record = record
        self.previewLayer = service.previewLayer
        self.chooseFirstCamera = chooseFirstCamera ?? {
            CameraPosition.allCases.randomElement() ?? .back
        }
        self.now = now
    }

    // MARK: - Lifecycle

    /// Starts the session on a randomly chosen camera.
    ///
    /// **Awaits until the camera is actually live.** An earlier version spawned
    /// a `Task` and returned immediately, which meant `phase` was still `.idle`
    /// when the caller came back — so anything that pressed the shutter straight
    /// after starting was pressing a button on a camera that was not open yet.
    /// Detached setup work is only correct when nothing needs to know when it
    /// finished, and here something always does.
    func start() async {
        guard phase == .idle else { return }
        let opening = chooseFirstCamera()
        firstPosition = opening
        livePosition = opening
        await runSession(openingOn: opening)
    }

    func stop() async {
        await service.stopSession()
        phase = .idle
    }

    private func runSession(openingOn position: CameraPosition) async {
        phase = .starting

        // Request if undetermined, then re-read. Requesting unconditionally
        // would re-prompt a user who already answered, which the system handles
        // by silently returning the old decision — correct, but it skips the
        // branch that distinguishes "not yet asked" from "said no".
        if service.authorizationStatus() == .notDetermined {
            _ = await service.requestAuthorization()
        }

        let status = service.authorizationStatus()
        guard status == .authorized else {
            phase = (status == .restricted) ? .failed(
                message: CaptureError.restricted.errorDescription ?? "",
                isRetryable: false
            ) : .permissionDenied
            return
        }

        do {
            try await service.startSession(on: position)
            previewLayer = service.previewLayer
            phase = .shooting
        } catch {
            phase = Self.phase(for: error)
        }
    }

    // MARK: - The shutter

    /// One press. Captures this camera, or — if it is already captured — moves
    /// to the other one.
    ///
    /// The second press doing the switch is the whole point (ADR-021). The user
    /// sees the other camera come up, composes, and presses again.
    func shutterPressed() async {
        guard phase == .shooting else { return }
        phase = .working

        do {
            if captured[livePosition] == nil {
                // First press on this camera: photograph it.
                let photo = try await service.captureCurrentPhoto()
                captured[livePosition] = photo
                lastCaptureAt = now()

                if captured.count == CameraPosition.allCases.count {
                    enterReview()
                } else {
                    // Second press: bring up the camera they have not shot.
                    let next = CameraPosition.allCases.first { $0 != livePosition } ?? .front
                    phase = .working
                    try await service.switchCamera(to: next)
                    livePosition = next
                    phase = .shooting
                }
            } else {
                // Pressing again on a camera already shot is not a capture; it
                // is a no-op rather than a silent over-write. Reshooting is an
                // explicit action from the review screen.
                phase = .shooting
            }
        } catch {
            phase = Self.phase(for: error)
        }
    }

    // MARK: - Review

    /// Promotes the small photograph to the large one, and vice versa.
    func swapProminent() {
        guard phase == .review, captured.count == 2 else { return }
        let other = CameraPosition.allCases.first { $0 != (prominentPosition ?? livePosition) }
        guard let other, captured[other] != nil else { return }
        prominentPosition = other
    }

    /// Reopens one camera so a single half can be reshot.
    ///
    /// The other photograph is kept — that is the entire point of being able to
    /// do this. Only the chosen half is discarded.
    ///
    /// Any write already made is forgotten, because the pair it covered no
    /// longer exists. Nothing is deleted from Photos to compensate (ADR-008);
    /// those assets simply become orphans the user owns, which the re-capture
    /// notice on the Today screen states up front.
    func reshoot(_ position: CameraPosition) async {
        guard let kept = captured[position.opposite] else { return }
        phase = .working
        retakeCount += 1
        invalidateCommit()

        do {
            try await service.switchCamera(to: position)
            livePosition = position
            captured = [position.opposite: kept]
            prominentPosition = nil
            phase = .shooting
        } catch {
            phase = Self.phase(for: error)
        }
    }

    /// Discards both photographs and starts the moment again.
    func startOver() async {
        phase = .working
        captured = [:]
        prominentPosition = nil
        invalidateCommit()
        let opening = chooseFirstCamera()
        firstPosition = opening
        livePosition = opening

        do {
            try await service.switchCamera(to: opening)
            phase = .shooting
        } catch {
            phase = Self.phase(for: error)
        }
    }

    /// Writes the reviewed pair to Photos and records it as a moment.
    ///
    /// **Two steps, in this order, and the order is the decision.**
    ///
    /// Photos first, then the archive row. The alternative — record, then write
    /// — looks tidier because it means the moment exists before the riskier
    /// operation, but it has a much worse failure. A crash between the two
    /// leaves an archive entry whose images do not exist, which renders as
    /// "missing from Photos" and tells the user a moment was saved when nothing
    /// was. This order's failure leaves two photographs in a library the user
    /// owns, made by an add-only permission that could never delete them anyway
    /// (ADR-008). One is inert; the other lies.
    ///
    /// Only the second step can fail after the first succeeds, which is what
    /// `writtenAssets` remembers and what `retry()` acts on.
    func commit() async {
        guard let pair = capturedPair, phase == .review else { return }
        isCommitting = true
        phase = .working
        await performCommit(pair)
    }

    /// The commit itself, shared with `retry()` so the two cannot drift.
    ///
    /// Re-entrant by design: `writtenAssets` is only non-`nil` once the library
    /// write has succeeded, so re-running after a *record* failure skips
    /// straight past it rather than writing a second pair.
    private func performCommit(_ pair: CapturedPair) async {
        do {
            if writtenAssets == nil {
                // No location passed. The write path and EXIF injector support
                // it, but there is no `CLLocationManager` in the app; that
                // decision is deferred to Phase 10 rather than faked here
                // (ADR-016, Q1).
                writtenAssets = try await photoLibrary.saveMomentPair(
                    backData: pair.back.data,
                    frontData: pair.front.data,
                    location: nil
                )
            }
            try await recordMoment(pair)
            isCommitting = false
            phase = .saved
        } catch {
            phase = Self.phase(for: error)
        }
    }

    /// Hands the finished pair to the archive.
    ///
    /// A no-op when no recorder was injected, which is what makes the camera
    /// screen usable — and testable — without a persistence layer.
    private func recordMoment(_ pair: CapturedPair) async throws {
        guard let record, let assets = writtenAssets else { return }
        try await record(
            CommittedCapture(
                back: pair.back,
                front: pair.front,
                assets: assets,
                capturedAt: lastCaptureAt ?? now(),
                retakeCount: retakeCount
            )
        )
    }

    /// Forgets any library write, because the pair it covered no longer exists.
    private func invalidateCommit() {
        writtenAssets = nil
        lastCaptureAt = nil
        isCommitting = false
    }

    // MARK: - Recovery

    /// Retries after a recoverable failure.
    ///
    /// **Never discards the photographs.** An earlier version cleared `captured`
    /// on every retry, which quietly destroyed both halves after a library write
    /// failed — the exact case its own test called "nothing was lost, the
    /// photographs are still in memory". The test passed anyway because it only
    /// asserted that the phase was not `.permissionDenied`, which is a
    /// statement about permissions and not about the pair.
    ///
    /// The rule is one line and needs no case analysis: **re-run whichever step
    /// failed.** A commit failure re-runs the commit, which is safe to repeat
    /// because the library write is memoised. Anything else re-arms the shutter
    /// on the camera that failed, keeping whatever was already shot.
    func retry() async {
        guard isFailed else { return }

        if case .failed(_, let retryable) = phase, !retryable {
            // Not retryable: a permission the user must change in Settings.
            // Re-running would produce the same answer, so say so plainly
            // rather than looping (AGENTS.md §6).
            phase = .permissionDenied
            return
        }

        phase = .working

        if isCommitting, let pair = capturedPair {
            await performCommit(pair)
            return
        }

        do {
            try await service.switchCamera(to: livePosition)
            phase = .shooting
        } catch {
            phase = Self.phase(for: error)
        }
    }

    /// Rebuilds the session after `mediaServicesWereReset`.
    ///
    /// Exposed for the debug menu: that failure raises no error and fires no
    /// callback, so the recovery path cannot be trusted until it has been
    /// invoked deliberately (TRD §5.5).
    func simulateMediaServicesReset() async {
        do {
            try await service.rebuildSession()
            previewLayer = service.previewLayer
            phase = captured.isEmpty ? .shooting : .review
        } catch {
            phase = Self.phase(for: error)
        }
    }

    // MARK: - Derived

    private func enterReview() {
        phase = .review
        // The photograph taken last is the one they were looking at, so it is
        // the large one until they say otherwise.
        prominentPosition = livePosition
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var canCapture: Bool { phase == .shooting }

    /// Both halves, or `nil` when either is still outstanding.
    ///
    /// A moment is only a moment when both photographs exist, so this is the
    /// gate on every path that treats the pair as a finished thing rather than
    /// as work in progress.
    var capturedPair: CapturedPair? {
        guard let back = captured[.back], let front = captured[.front] else { return nil }
        return CapturedPair(back: back, front: front)
    }

    /// The camera the user is composing with, in words.
    var livePositionDescription: String {
        livePosition == .front ? "Front camera" : "Back camera"
    }

    /// The photograph already taken, shown in the small square while the other
    /// camera is live. `nil` before the first press.
    var insetPhoto: CapturedPhoto? {
        guard let other = CameraPosition.allCases.first(where: { $0 != livePosition })
        else { return nil }
        return captured[other]
    }

    /// The photograph drawn large in review.
    var prominentPhoto: CapturedPhoto? {
        guard let prominentPosition else { return nil }
        return captured[prominentPosition]
    }

    /// The photograph drawn in the small square during review.
    var insetReviewPhoto: CapturedPhoto? {
        guard let prominentPosition,
              let other = CameraPosition.allCases.first(where: { $0 != prominentPosition })
        else { return nil }
        return captured[other]
    }

    /// Progress copy, which names the step rather than apologising for it.
    var progressDescription: String {
        switch phase {
        case .starting: return "Opening the camera"
        case .working: return captured.isEmpty ? "Capturing…" : "Switching camera…"
        default: return ""
        }
    }

    /// Whether the shutter is shown at all.
    ///
    /// Absent rather than disabled when the camera cannot be used, for the same
    /// reason the shutter was absent on the Today screen until Phase 4: a
    /// control that looks live and does nothing is a dead end.
    var showsShutter: Bool {
        switch phase {
        case .shooting, .review: return true
        case .idle, .starting, .working, .saved, .failed, .permissionDenied:
            return false
        }
    }

    // MARK: - Errors

    private static func phase(for error: Error) -> Phase {
        if let captureError = error as? CaptureError {
            return .failed(
                message: captureError.errorDescription ?? "Something went wrong.",
                isRetryable: captureError.isRetryable
            )
        }
        if let libraryError = error as? LibraryError {
            return .failed(
                message: libraryError.errorDescription ?? "Something went wrong.",
                // A library write failure is worth retrying: the photographs
                // are still in memory and nothing was lost.
                isRetryable: true
            )
        }
        if let storeError = error as? StoreError {
            return .failed(
                message: storeError.errorDescription ?? "Something went wrong.",
                // Reached only once the photographs are already in Photos, so
                // the message says so and the retry cannot lose them.
                isRetryable: storeError.isRetryable
            )
        }
        return .failed(message: error.localizedDescription, isRetryable: true)
    }
}
