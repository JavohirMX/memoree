import AVFoundation
import Foundation
import QuartzCore

/// Sequential capture: one camera at a time, driven by the user.
///
/// Sequential rather than `AVCaptureMultiCamSession` — see ADR-003. The
/// front-back photograph is the signature of the format, and a single session
/// that reconfigures between inputs reproduces it closely enough while working
/// on every supported iPhone and remaining debuggable in a fraction of the time.
///
/// The cost is real and accepted: the two frames are not simultaneous, and the
/// gap is visible.
///
/// ## There is deliberately no `capturePair()`
///
/// An earlier version exposed one method that captured rear, swapped, captured
/// front, and restored — a single shutter press producing both photographs
/// automatically. That is not how the mechanic works. The user shoots the
/// first camera themselves, then presses again for the second, and **that second
/// press is what switches the camera** (ADR-021). Collapsing the sequence into
/// one call hid the only interesting part of it: the swap is a user-visible
/// event with a live preview on the other side of it, and it happens while
/// they are looking at the screen.
///
/// A method that captured both halves without asking would also have made the
/// "reshoot just this one" case inexpressible.
final class SequentialCaptureService: CapturePhotoService, @unchecked Sendable {

    // `@unchecked Sendable` because `CapturePhotoService: Sendable` is
    // satisfied here by confinement, not by immutability: the only stored
    // property is a `let` reference to a controller whose mutable state is
    // confined to its own serial queue (AGENTS.md §5).
    private let controller: CaptureSessionController

    init(controller: CaptureSessionController = CaptureSessionController()) {
        self.controller = controller
    }

    // MARK: - CapturePhotoService

    var previewLayer: CALayer { controller.previewLayer }

    func authorizationStatus() -> CameraAuthorizationStatus {
        controller.authorizationStatus()
    }

    func requestAuthorization() async -> CameraAuthorizationStatus {
        await controller.requestAuthorization()
    }

    func startSession(on position: CameraPosition) async throws {
        try await controller.startSession(on: position)
    }

    func stopSession() async {
        await controller.stopSession()
    }

    func captureCurrentPhoto() async throws -> CapturedPhoto {
        do {
            return try await controller.captureCurrentPhoto()
        } catch {
            // **The same recovery `switchCamera` has always had, and the capture
            // path did not.** That asymmetry was the defect, not the daemon.
            //
            // When the capture daemon dies it does not raise an error and fire a
            // delegate — it stops answering. The photo callback never arrives,
            // `photoDataUnavailable` comes back, and because the session is gone
            // every subsequent attempt fails identically for the life of the
            // process. The UI showed a **Try again** button the whole time, and
            // it could not work. A retry that cannot succeed is the dead end
            // `AGENTS.md` §6 forbids.
            //
            // So: rebuild, then rethrow the original error. The existing retry
            // button then does the only thing it says it does — retries the
            // capture — and it runs against a live session. No new state, no new
            // copy, and the user is told nothing about a rebuild they did not
            // cause and cannot act on.
            //
            // **One rebuild per attempt, and never a loop.** `rebuildSession()`
            // constructs a new `AVCaptureSession`, which is a synchronous XPC
            // round-trip to the very daemon that may be unwell; unbounded
            // rebuild-on-failure would manufacture the death it exists to fix.
            // A single rebuild per call is bounded by construction, because this
            // method does not retry — it reports and returns.
            //
            // Narrower than `switchCamera`'s rebuild on purpose. A failed *swap*
            // leaves the session mid-swap, which is definitionally unusable. A
            // failed *capture* might be one dropped callback on a healthy
            // session, and rebuilding for that throws away a working camera to
            // fix nothing. `indicatesDeadCaptureSubsystem` is the discriminator.
            //
            // `any Error`, so narrow before asking it a `CaptureError` question —
            // and rethrow the *original* either way, so a narrowing that
            // somehow misses reports what actually went wrong rather than a
            // second, less accurate error.
            guard let captureError = error as? CaptureError,
                  captureError.indicatesDeadCaptureSubsystem else { throw error }
            try? await controller.rebuildSession()
            throw error
        }
    }

    func switchCamera(to position: CameraPosition) async throws {
        do {
            try await controller.swapInput(to: position)
        } catch {
            // A failed swap leaves the session mid-swap, and a session
            // mid-swap is not reliably reusable. The first device runs showed
            // one failure followed by `noInputAvailable` on every remaining
            // attempt. Rebuilding costs a fraction of a second and is the
            // documented recovery for a session in a bad state (TRD §5.5).
            //
            // Best-effort and swallowed: the original error is the one worth
            // reporting, and a failure to rebuild must not replace it with a
            // second, less accurate one.
            try? await controller.rebuildSession()
            throw error
        }
    }

    func configureFormat(for position: CameraPosition) async throws {
        try await controller.configureFormat(for: position)
    }

    func currentRotation() async -> CaptureOrientation? {
        await controller.currentOrientation()
    }

    func focus(atNormalizedPoint point: CGPoint) async {
        await controller.focus(atNormalizedPoint: point)
    }

    func applyZoom(_ zoom: CameraZoom) async throws {
        try await controller.applyZoom(zoom)
    }

    func currentZoom() async -> CameraZoom {
        await controller.currentCameraZoom()
    }

    // MARK: - Diagnostics

    /// The last few frame waits, for a device diagnostic to read.
    ///
    /// **Not on `CapturePhotoService`, and that is deliberate.** The protocol is
    /// what production code and every test double conform to, and a diagnostic
    /// method on it would mean every double carrying an implementation of
    /// something production never calls. This is on the concrete service, where
    /// only a device diagnostic reaches it — the same reasoning that keeps
    /// `ArchiveThumbnailCache` out of the protocol.
    func frameWaitDiagnostics() async -> [CaptureSessionController.FrameWaitOutcome] {
        await controller.frameWaitDiagnostics()
    }

    func resetFrameWaitDiagnostics() async {
        await controller.resetFrameWaitDiagnostics()
    }

    /// How many times the session has been rebuilt.
    ///
    /// **Diagnostics, on the concrete service, for the same reason as
    /// `frameWaitDiagnostics` above** — and this one earns its place more
    /// strongly, because the capture path now rebuilds on a dead subsystem where
    /// it previously did not. A device gate that wants to know whether the
    /// twenty-moment run went green because the camera recovered or because the
    /// daemon stopped dying has to be able to count the recoveries.
    func sessionRebuildCount() async -> Int {
        await controller.sessionRebuildCount()
    }

    func rebuildSession() async throws {
        try await controller.rebuildSession()
    }

    /// A straight delegation, and deliberately not `throws`.
    ///
    /// The controller's version configures *future* sessions, so there is nothing
    /// here that can fail — and a throwing variant would invite a caller to wrap it
    /// in a `try` for a failure that does not exist, which is the kind of noise
    /// `LiveBTSRecorder`'s `startRecording` already had to be cleaned up for.
    func enableMovieOutput() async {
        await controller.enableMovieOutput()
    }
}
