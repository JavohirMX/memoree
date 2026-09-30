import AVFoundation
import Foundation

/// Captures the front-and-back pair that makes a moment.
///
/// Sequential, not `AVCaptureMultiCamSession` — see ADR-003. The front-back
/// photograph is the signature of the format, and a single session that
/// reconfigures between inputs reproduces it closely enough while working on
/// every supported iPhone and remaining debuggable in a fraction of the time.
///
/// The cost is real and accepted: the two frames are not simultaneous, and the
/// gap is visible. Target gap is 0.3–1.0s.
///
/// ## Why the ordering lives here and not in the controller
///
/// The swap and the frame-wait are one indivisible step. Splitting them across
/// two layers invites a caller to swap without waiting, which produces a black
/// or green front photo with no error anywhere. This type owns the whole
/// sequence so that ordering cannot be got wrong by a caller.
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

    func startSession() async throws {
        try await controller.startSession()
    }

    func stopSession() async {
        await controller.stopSession()
    }

    func configureFormat(for position: CameraPosition) async throws {
        try await controller.configureFormat(for: position)
    }

    func rebuildSession() async throws {
        try await controller.rebuildSession()
    }

    func capturePhoto(at position: CameraPosition) async throws -> CapturedPhoto {
        try await controller.capturePhoto(at: position)
    }

    // MARK: - The pair

    /// Captures rear, then front, then restores rear.
    ///
    /// The full sequence from docs/TRD.md §5.2:
    ///
    /// ```
    ///  1. capturePhoto(rear)
    ///  2. await rear data
    ///  3-5. beginConfiguration / removeInput / addInput(front)
    ///  6. await no runtime error
    ///  7. await first delivered frame from the front input   ← not optional
    ///  8. capturePhoto(front)
    ///  9. await front data
    /// 10. beginConfiguration / restore rear input
    /// ```
    ///
    /// Step 7 is the one that gets skipped and should not. Capturing before the
    /// front sensor has delivered anything yields a black or green image, and
    /// the failure is silent — the photo is written and looks broken forever.
    ///
    /// The rear restore is best-effort: if it fails, the pair is still valid and
    /// the session recovers on the next `startSession`. Failing the whole
    /// capture over a cosmetic preview state would throw away two good
    /// photographs.
    ///
    /// - Returns: The pair, or throws the first failure encountered. A partial
    ///   pair is never returned — a half-captured moment is a broken invariant.
    func capturePair() async throws -> CapturedPair {
        try Task.checkCancellation()

        do {
            // Steps 1-2. The rear camera is the default input, so no swap is
            // needed.
            let back = try await controller.capturePhoto(at: .back)

            // Steps 3-7. Swap and wait for a real delivered frame.
            try await controller.swapInput(to: .front)

            // Steps 8-9.
            let front = try await controller.capturePhoto(at: .front)

            // Step 10. Restore, best-effort.
            try? await controller.swapInput(to: .back)

            return CapturedPair(back: back, front: front)
        } catch {
            // A failed pair leaves the session mid-swap, and a session
            // mid-swap is not reliably reusable: the first device run showed
            // one `noDeliveredFrame` on the front camera followed by
            // `noInputAvailable` on the back camera for every remaining
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
}
