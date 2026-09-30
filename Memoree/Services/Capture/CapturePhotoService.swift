import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore

/// Captures the front-and-back pair that makes a moment.
///
/// A protocol so that UI work and tests never need a real camera (AGENTS.md §3).
/// The simulator has no capture hardware at all, so this boundary is the only
/// thing that makes the camera flow testable off-device.
///
/// Deliberately does **not** import SwiftUI. The service publishes state; the
/// view observes it (AGENTS.md §3).
///
/// The preview surface crosses the layer boundary as a bare `CALayer` rather
/// than an `AVCaptureVideoPreviewLayer` — see ADR-018 for why, and for the
/// alternative that would have required an exception to the import rule.
///
/// Class-bound and `Sendable` for two reasons:
///
/// - `previewLayer` is a stored reference held across the session's lifetime,
///   so the service must be able to hand out the same surface for its whole
///   life rather than a copy per read.
/// - The service is created in the `@MainActor` composition root and used from
///   the camera's own queues, so it crosses isolation domains. Every
///   implementation is thread-safe by construction: `SequentialCaptureService`
///   confines all mutable state to the session controller's serial queue, and
///   `InMemoryCaptureService` guards its state with a lock. Making that a
///   protocol requirement means a future implementation cannot quietly opt out.
protocol CapturePhotoService: AnyObject, Sendable {

    /// The live preview surface.
    ///
    /// Typed as `CALayer` so `Features/` can install it without importing
    /// AVFoundation. The concrete type is always `AVCaptureVideoPreviewLayer`,
    /// configured by the service — `videoGravity` and mirroring are capture
    /// concerns, not layout ones (ADR-018).
    var previewLayer: CALayer { get }

    /// Current camera authorisation. A denied state is supported, not an error:
    /// the user can still use the archive and settings without a camera.
    func authorizationStatus() -> CameraAuthorizationStatus

    /// Requests camera access. Never blocks on a dialog the test host cannot
    /// dismiss.
    func requestAuthorization() async -> CameraAuthorizationStatus

    /// Starts the session and the preview.
    ///
    /// - Throws: `CaptureError` when no usable input exists. Callers must show
    ///   a recoverable state rather than a blank screen (AGENTS.md §6).
    func startSession() async throws

    /// Stops the session and tears down the preview. Idempotent.
    func stopSession() async

    /// Captures one photograph from the given position.
    ///
    /// Does **not** perform the input swap. `SequentialCaptureService` owns the
    /// ordering, because the swap and the frame-wait are one indivisible step —
    /// splitting them across two protocols invites exactly the race this design
    /// exists to prevent.
    func capturePhoto(at position: CameraPosition) async throws -> CapturedPhoto

    /// Applies 3:4 format selection to the input at `position`.
    ///
    /// Separate from `startSession` because the format must be re-applied after
    /// every input swap: `sessionPreset` is unreliable across one, and the front
    /// and rear devices support different format lists (TRD §5.3).
    func configureFormat(for position: CameraPosition) async throws

    /// Rebuilds the session from scratch.
    ///
    /// Exists for `mediaServicesWereReset`, which raises no error, fires no
    /// delegate callback, and simply freezes the preview. Recovery means
    /// destroying the session and constructing a new one — there is nothing to
    /// retry (TRD §5.5). Also reachable from the debug menu so the one silent
    /// failure mode in the camera stack can actually be tested.
    func rebuildSession() async throws
}

// MARK: - Value types

/// Which physical camera a photograph came from.
enum CameraPosition: String, Sendable, Equatable, CaseIterable {
    case back
    case front

    /// The camera a moment opens with. BeReal records BTS on the primary
    /// camera, and rear is the default primary (ADR-013).
    static let `default`: CameraPosition = .back

    var opposite: CameraPosition { self == .back ? .front : .back }
}

/// One captured photograph, still as the bytes the camera produced.
///
/// Deliberately not a `UIImage`. Decoding here would discard the EXIF the
/// camera already wrote, and `fileDataRepresentation()` output is what
/// `PhotoLibraryService` needs (AGENTS.md §8).
struct CapturedPhoto: Sendable, Equatable {

    let data: Data

    /// Pixel dimensions, recorded at capture time.
    ///
    /// Carried rather than re-derived because the format selector chose them
    /// deliberately, and a mismatch here is the first sign that a 16:9 format
    /// slipped through — which is exactly the defect the tests guard against.
    let pixelWidth: Int
    let pixelHeight: Int

    let position: CameraPosition

    init(data: Data, pixelWidth: Int, pixelHeight: Int, position: CameraPosition) {
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.position = position
    }

    /// Whether these dimensions are portrait 3:4.
    var isThreeByFour: Bool {
        guard pixelHeight > 0 else { return false }
        let ratio = Double(pixelWidth) / Double(pixelHeight)
        return abs(ratio - CaptureFormatSelector.targetRatio)
            <= CaptureFormatSelector.ratioTolerance
    }
}

/// The front-and-back pair that constitutes a moment.
struct CapturedPair: Sendable, Equatable {

    let back: CapturedPhoto
    let front: CapturedPhoto

    init(back: CapturedPhoto, front: CapturedPhoto) {
        self.back = back
        self.front = front
    }
}

/// Mirrors `AVAuthorizationStatus` without leaking AVFoundation into call sites
/// that only need to branch on the outcome.
enum CameraAuthorizationStatus: Sendable, Equatable {
    /// Not yet asked.
    case notDetermined
    /// Granted.
    case authorized
    /// The user said no. The archive and settings remain fully usable.
    case denied
    /// Blocked by device policy or parental controls.
    case restricted
}

// MARK: - Errors

/// Everything that can go wrong during capture.
///
/// One enum per domain, `LocalizedError` for user-facing copy (AGENTS.md §6).
/// Every case has a recoverable UI state — there are no dead ends.
enum CaptureError: Error, LocalizedError, Equatable {

    /// The user declined camera access.
    case permissionDenied

    /// The OS refused access regardless of the user's answer.
    case restricted

    /// No camera exists at the requested position, or none could be opened.
    case noInputAvailable(CameraPosition)

    /// Another app holds the camera. Recovers when that app backgrounds.
    case inUseByAnotherApp

    /// The session was interrupted and has not yet resumed.
    case interrupted

    /// Thermal state is critical. Capture is blocked until it cools.
    case thermalStateCritical

    /// The front input was added but never delivered a frame within the
    /// deadline.
    ///
    /// Separated from a generic timeout because this is the failure the
    /// sequential design is most likely to produce, and it deserves a
    /// distinguishable message and a retry that behaves differently.
    case noDeliveredFrame(CameraPosition)

    /// The photo delegate returned without data.
    case photoDataUnavailable(CameraPosition)

    /// A configuration attempt failed. Carries the reason for the log.
    case configurationFailed(String)

    /// The session was torn down mid-capture.
    case sessionReset

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Memoree needs camera access to capture your moment."
        case .restricted:
            "Camera access is blocked on this device."
        case .noInputAvailable:
            "No camera is available."
        case .inUseByAnotherApp:
            "Another app is using the camera."
        case .interrupted:
            "The camera was interrupted."
        case .thermalStateCritical:
            "Your device is too warm to capture. Try again shortly."
        case .noDeliveredFrame:
            "The camera did not start. Try again."
        case .photoDataUnavailable:
            "The photo could not be read."
        case .configurationFailed(let reason):
            "The camera could not be configured: \(reason)"
        case .sessionReset:
            "The camera was reset."
        }
    }

    /// Whether retrying the same capture could plausibly succeed.
    ///
    /// Drives whether the UI offers a retry button or an explanation. A denied
    /// permission is not retryable — the user must change it in Settings — and
    /// offering "try again" there is a dead end (AGENTS.md §6).
    var isRetryable: Bool {
        switch self {
        case .interrupted, .inUseByAnotherApp, .thermalStateCritical,
             .noDeliveredFrame, .photoDataUnavailable, .sessionReset,
             .configurationFailed:
            return true
        case .permissionDenied, .restricted, .noInputAvailable:
            return false
        }
    }
}
