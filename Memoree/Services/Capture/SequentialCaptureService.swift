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
        try await controller.captureCurrentPhoto()
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

    func rebuildSession() async throws {
        try await controller.rebuildSession()
    }
}
