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
/// `CapturedPair` are Memoree's own types, and the preview arrives as a
/// `CALayer` (ADR-018).
@MainActor
@Observable
final class CameraViewModel {

    /// What the camera screen is doing.
    enum Phase: Equatable {
        /// Session not started, or permission not yet resolved.
        case idle
        /// Session starting.
        case starting
        /// Live preview, ready to capture.
        case ready
        /// A capture is in flight. The shutter is disabled.
        case capturing
        /// A pair was captured and is awaiting a decision.
        case reviewing
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

    /// The pair awaiting review, or `nil` before the first shutter.
    private(set) var capturedPair: CapturedPair?

    /// How many times the shutter has been pressed.
    ///
    /// BeReal shows friends this number. With no feed it is a private statistic
    /// rather than a social signal — a high count means a busy or awkward
    /// moment, which is arguably more interesting (ADR-011).
    private(set) var retakeCount = 0

    /// The live preview surface, installed by `CameraPreview` (ADR-018).
    private(set) var previewLayer: CALayer?

    /// Which camera is primary. Tapping the inset swaps them.
    private(set) var primaryPosition: CameraPosition = .default

    // MARK: - Dependencies

    private let service: CapturePhotoService
    private let photoLibrary: PhotoLibraryService
    private var sessionTask: Task<Void, Never>?

    // MARK: - Init

    init(service: CapturePhotoService, photoLibrary: PhotoLibraryService) {
        self.service = service
        self.photoLibrary = photoLibrary
        self.previewLayer = service.previewLayer
    }

    // MARK: - Lifecycle

    /// Starts the session and shows the preview.
    func start() async {
        guard sessionTask == nil else { return }
        sessionTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    func stop() async {
        sessionTask?.cancel()
        sessionTask = nil
        await service.stopSession()
        phase = .idle
    }

    private func runSession() async {
        phase = .starting

        // Request if undetermined, then re-read. Requesting unconditionally
        // would re-prompt a user who already answered, which the system
        // handles by silently returning the old decision — correct, but it
        // skips the branch that distinguishes "not yet asked" from "said no".
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
            try await service.startSession()
            previewLayer = service.previewLayer
            phase = .ready
        } catch {
            phase = Self.phase(for: error)
        }
    }

    // MARK: - Capture

    /// Fires the shutter. Captures a fresh pair and holds it for review.
    func capture() async {
        guard phase == .ready else { return }
        phase = .capturing

        do {
            let pair = try await capturePair()
            capturedPair = pair
            phase = .reviewing
        } catch {
            phase = Self.phase(for: error)
        }
    }

    /// Runs the sequential capture.
    ///
    /// Calls the pair method when the service provides one — the production
    /// `SequentialCaptureService` does — and falls back to composing the pair
    /// from two single captures otherwise. The fallback exists so a test double
    /// only has to implement the protocol, not this type's internals.
    private func capturePair() async throws -> CapturedPair {
        if let sequential = service as? SequentialCaptureService {
            return try await sequential.capturePair()
        }
        return try await composePair()
    }

    private func composePair() async throws -> CapturedPair {
        let back = try await service.capturePhoto(at: .back)
        let front = try await service.capturePhoto(at: .front)
        return CapturedPair(back: back, front: front)
    }

    /// Writes the reviewed pair to Photos.
    ///
    /// Stops at the library: recording the moment itself — `MomentStore.record`
    /// and the streak recompute — is Phase 5's orchestration, not capture's.
    /// Ending here means the shutter leads somewhere real rather than to a dead
    /// end (AGENTS.md §6), and it proves the Phase 3 write path on hardware.
    func commit() async {
        guard let pair = capturedPair, phase == .reviewing else { return }
        phase = .capturing

        do {
            // No location passed. The write path and EXIF injector support it,
            // but there is no `CLLocationManager` in the app; that decision is
            // deferred to Phase 10 rather than faked here.
            _ = try await photoLibrary.saveMomentPair(
                backData: pair.back.data,
                frontData: pair.front.data,
                location: nil
            )
            phase = .saved
        } catch {
            phase = Self.phase(for: error)
        }
    }

    /// Discards the reviewed pair and re-arms the shutter.
    ///
    /// Unlimited retakes, and the count is kept (ADR-011). The discarded pair
    /// is simply dropped: nothing was written anywhere, so there is nothing to
    /// clean up.
    func retake() async {
        guard phase == .reviewing || isFailed else { return }
        retakeCount += 1
        capturedPair = nil
        phase = .ready
    }

    // MARK: - Recovery

    /// Retries after a recoverable failure.
    func retry() async {
        guard isFailed else { return }
        capturedPair = nil
        if case .failed(_, let retryable) = phase, !retryable {
            // Not retryable: a permission the user must change in Settings.
            // Re-running would produce the same answer, so say so plainly
            // rather than looping (AGENTS.md §6).
            phase = .permissionDenied
            return
        }
        phase = .ready
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
            phase = .ready
        } catch {
            phase = Self.phase(for: error)
        }
    }

    // MARK: - Derived

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var canCapture: Bool { phase == .ready }

    /// Whether the shutter should be shown at all.
    ///
    /// Absent rather than disabled when the camera cannot be used, for the same
    /// reason the shutter was absent on the Today screen until Phase 4: a
    /// control that looks live and does nothing is a dead end.
    var showsShutter: Bool {
        switch phase {
        case .ready, .reviewing: return true
        case .idle, .starting, .capturing, .saved, .failed, .permissionDenied:
            return false
        }
    }

    /// Swaps which camera is primary.
    ///
    /// BeReal's composite puts the rear full-bleed with the front inset, and
    /// lets you tap the inset to swap (TRD §5.6). The pair itself is unaffected
    /// — it is always rear-then-front — so this only changes the preview.
    func togglePrimaryCamera() {
        primaryPosition = primaryPosition.opposite
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
                // A library write failure is worth retrying: the photos are
                // still in memory and nothing was lost.
                isRetryable: true
            )
        }
        return .failed(message: error.localizedDescription, isRetryable: true)
    }
}
