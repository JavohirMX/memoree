import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore

/// Captures the front-and-back pair that makes a moment, **one photo at a time**.
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

    /// Starts the session on `position`, and the preview with it.
    ///
    /// Which camera opens is **random per moment** (ADR-021): the user does not
    /// know in advance which one they are composing with, which is the same
    /// intent as the random delivery time.
    ///
    /// - Throws: `CaptureError` when no usable input exists. Callers must show
    ///   a recoverable state rather than a blank screen (AGENTS.md §6).
    func startSession(on position: CameraPosition) async throws

    /// Stops the session and tears down the preview. Idempotent.
    func stopSession() async

    /// Captures one photograph from the camera currently live.
    ///
    /// No position parameter. By the time this is called the session is already
    /// on the camera the user is composing with, and accepting a position
    /// separately would allow a caller to ask for a camera that is not
    /// attached.
    func captureCurrentPhoto() async throws -> CapturedPhoto

    /// Switches the live camera and waits for the new one to deliver a frame.
    ///
    /// **Not optional, and the reason it is on the protocol.** The caller is the
    /// user's second shutter press, so this runs mid-sequence; capturing before
    /// the new sensor has delivered anything yields a black or green
    /// photograph — silently, and permanently (TRD §5.2, step 7).
    ///
    /// The wait is a real delivered frame, not a sleep. In the sequential
    /// design this is the step most likely to flake, and the docs call that out
    /// in four separate places.
    func switchCamera(to position: CameraPosition) async throws

    /// Applies 3:4 format selection to the input at `position`.
    ///
    /// Separate from `startSession` because the format must be re-applied after
    /// every input swap: `sessionPreset` is unreliable across one, and the front
    /// and rear devices support different format lists (TRD §5.3).
    func configureFormat(for position: CameraPosition) async throws

    /// The rotation currently applied to both connections, or `nil` if no
    /// session is running.
    ///
    /// Exists so the live capture tests can assert what was applied rather than
    /// inferring it from a photograph.
    ///
    /// **Rotation needs no reporting from the view.** `AVCaptureDevice`'s
    /// rotation coordinator watches the device's *physical* orientation — the
    /// thing gravity knows about — and corrects for the rotation lock that makes
    /// `UIDevice.orientation` report `.portrait` forever. The earlier design
    /// asked the UI layer to report a held orientation, which could not survive
    /// that case, and every sideways photograph saved as a portrait one.
    func currentRotation() async -> CaptureOrientation?

    /// Moves focus and exposure to a point the user tapped.
    ///
    /// - Parameter point: **Normalised 0…1 in the preview's own coordinates**,
    ///   not a layer or device point. The service owns the preview layer and is the
    ///   only thing that knows how a view coordinate maps onto a sensor
    ///   coordinate — a `Features/` caller cannot do that conversion without
    ///   importing AVFoundation, which `AGENTS.md` §3 forbids.
    ///
    /// Best-effort and never throws: a device that does not support a focus point
    /// simply keeps its autofocus, and failing a tap with an error is worse than
    /// ignoring it. The user pressed somewhere sensible; there is nothing to tell
    /// them.
    func focus(atNormalizedPoint point: CGPoint) async

    /// Applies a zoom, and remembers it across the camera swap.
    ///
    /// **The user chooses the button; AVFoundation supplies the number.** Rotation
    /// is the other way round and deliberately has no such method — that
    /// inversion is what made the orientation feature wrong three times.
    ///
    /// Idempotent, and a no-op before the session exists: the choice is recorded
    /// and applied when the camera opens, so both halves of a moment are taken at
    /// the same framing.
    func applyZoom(_ zoom: CameraZoom) async throws

    /// Sets the torch mode on the active device, if supported.
    func setTorchMode(_ mode: TorchMode) async throws

    /// The torch mode currently in force.
    func currentTorchMode() async -> TorchMode

    /// Rebuilds the session from scratch.
    ///
    /// Exists for `mediaServicesWereReset`, which raises no error, fires no
    /// delegate callback, and simply freezes the preview. Recovery means
    /// destroying the session and constructing a new one — there is nothing to
    /// retry (TRD §5.5). Also reachable from the debug menu so the one silent
    /// failure mode in the camera stack can actually be tested.
    func rebuildSession() async throws

    /// Asks for a Behind-the-Scenes output on sessions started **after** this call.
    ///
    /// ## Why this is on the photo protocol at all
    ///
    /// The movie output belongs to the same `AVCaptureSession` as the photo output,
    /// a session cannot have two movie outputs, and attaching one to a *running*
    /// session means another `beginConfiguration` cycle on the subsystem this
    /// project has measured as fragile. So the request has to happen before
    /// `startSession` — which puts it on the type that owns the session.
    ///
    /// **Non-throwing and not a parameter**, for the same reason `wantsMovieOutput`
    /// is a flag rather than a threaded `Bool`: the session is configured in six
    /// places, and threading a flag through all of them is how this file once
    /// shipped a camera that worked exactly once per launch.
    func enableMovieOutput() async
}

// MARK: - Value types

/// Which physical camera a photograph came from.
enum CameraPosition: String, Sendable, Equatable, CaseIterable {
    case back
    case front

    /// **No `default` here on purpose.** There was one, documented as "the rear
    /// is the default primary (ADR-013)", and ADR-021 superseded it: the camera
    /// a moment opens on is random per moment, because fixing the order would
    /// reintroduce exactly the predictability the rest of the design removes.
    /// It was unused when that happened, but a `static let default` on an enum
    /// is an invitation — a call site reaching for it would reinstate the old
    /// behaviour without anybody noticing, and the comment would still be
    /// quoting an ADR that no longer says it.
    ///
    /// The BTS question ADR-013 and ADR-021 both left open — "the primary
    /// camera" is now whichever the user shot first — is a Phase 7 decision.

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

    /// Whether these dimensions are 3:4, in either orientation.
    ///
    /// Orientation-agnostic for the same reason `CaptureFormatSelector` is: a
    /// sensor is natively landscape and the photo is rotated by its EXIF
    /// orientation tag. Comparing short side over long side avoids depending on
    /// which way round the hardware happened to report.
    var isThreeByFour: Bool {
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        let longSide = Double(max(pixelWidth, pixelHeight))
        let shortSide = Double(min(pixelWidth, pixelHeight))
        return abs(shortSide / longSide - CaptureFormatSelector.targetRatio)
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

    /// The camera exists but offers no 3:4 format.
    ///
    /// Separate from `noInputAvailable` because the two demand opposite
    /// responses — one means there is no camera, the other means the camera
    /// cannot honour Memoree's geometry — and conflating them hid a real defect
    /// behind a plausible-sounding message. When `selectFormat` was rejecting
    /// every landscape format, this surfaced as `noInputAvailable` on all 57
    /// formats of a perfectly healthy iPhone, which sent the diagnosis towards
    /// permissions and hardware rather than towards the ratio test (ADR-019).
    case noThreeByFourFormat(CameraPosition)

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

    /// The zoom asked for is not available on this camera.
    ///
    /// The front camera has one lens, so 0.5× does not exist there. Refused rather
    /// than clamped: silently giving the user something other than what they
    /// pressed is how a control becomes a liar.
    case zoomUnavailable(CameraZoom, CameraPosition)

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
        case .noThreeByFourFormat:
            "This camera cannot shoot in the 3:4 format Memoree uses."
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
        case .zoomUnavailable:
            "That zoom is not available on this camera."
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
    ///
    /// **A retryable error whose retry cannot possibly work is that same dead
    /// end**, which is how `photoDataUnavailable` managed to be one: the capture
    /// subsystem had died, every later attempt failed identically, and the button
    /// kept offering a retry against a corpse. `indicatesDeadCaptureSubsystem` is
    /// what the recovery keys on.
    var isRetryable: Bool {
        switch self {
        case .interrupted, .inUseByAnotherApp, .thermalStateCritical,
             .noDeliveredFrame, .photoDataUnavailable, .sessionReset,
             .configurationFailed, .zoomUnavailable:
            return true
        case .permissionDenied, .restricted, .noInputAvailable, .noThreeByFourFormat:
            return false
        }
    }

    /// Whether this failure means the **capture subsystem is gone**, rather than
    /// this one attempt having failed.
    ///
    /// ## What this is for
    ///
    /// The camera session lives in the capture daemon, and that daemon can die.
    /// When it does, the session does not raise an error and fire a delegate —
    /// it simply stops answering, so the next capture's photo callback never
    /// arrives and `photoDataUnavailable` comes back with nothing behind it.
    ///
    /// **The consequence used to be that the camera stayed dead for the life of
    /// the process.** Every later attempt failed identically, and because the
    /// error is retryable the UI offered a **Try again** button that could not
    /// succeed — the dead end `AGENTS.md` §6 forbids. The camera swap path has
    /// always rebuilt the session on failure; the capture path did not, and that
    /// asymmetry was the defect.
    ///
    /// ## Why these two and not the others
    ///
    /// - `photoDataUnavailable` — the photo delegate returned, or timed out
    ///   returning, with no bytes. With a live session this is a single dropped
    ///   callback; with a dead one it is every callback, forever.
    /// - `sessionReset` — the session was torn down underneath us, which is the
    ///   reset path's own report and means there is nothing left to talk to.
    ///
    /// **`noDeliveredFrame` is deliberately excluded**, even though it is the
    /// other signature of a dead subsystem. It is thrown by the frame wait, which
    /// lives in the *swap* path — and that path already rebuilds on every error,
    /// including this one. Rebuilding twice for one failure would allocate two
    /// sessions where one is called for, and `rebuildSession()` is not free: it
    /// constructs a new `AVCaptureSession`, a synchronous XPC round-trip to the
    /// daemon that may be the thing that is unwell.
    ///
    /// The asymmetry is deliberate in the other direction too. `interrupted`,
    /// `inUseByAnotherApp` and `thermalStateCritical` all recover on their own,
    /// and `noInputAvailable` / `configurationFailed` are not transient — so
    /// none of them should cost a session allocation.
    var indicatesDeadCaptureSubsystem: Bool {
        switch self {
        case .photoDataUnavailable, .sessionReset:
            return true
        default:
            return false
        }
    }
}

/// The torch mode for low-light capture.
enum TorchMode: String, Sendable, Equatable, CaseIterable {
    case off
    case on
}

