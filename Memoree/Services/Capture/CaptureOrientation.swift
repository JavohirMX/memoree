import Foundation

/// How the device is being held, in the app's own words.
///
/// A domain enum rather than `UIDeviceOrientation` so `Services/` never has to
/// name a UIKit type to describe something it genuinely owns — the same reason
/// `CameraPosition` exists instead of `AVCaptureDevice.Position`
/// (`AGENTS.md` §3, §4).
///
/// **Two cases mean "do not change anything".** `.faceUp` and `.faceDown` are
/// how a phone lies on a table, and a photograph taken while it is face-down is
/// a photograph of a table. Keeping the last good rotation is what every camera
/// app does and it is the only answer that does not require throwing away the
/// shot.
enum DeviceOrientation: String, Sendable, Equatable, CaseIterable {

    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
    case faceUp
    case faceDown
    case unknown
}

/// The rotation to apply to the preview and to the photo, in degrees clockwise.
///
/// ## Why this exists as a pure type
///
/// The bug this fixes is that **nothing set an orientation at all** — neither
/// the preview connection nor the photo connection, on either API. Everything
/// sat at the AVFoundation default, which assumes a device held in landscape.
///
/// That cannot be verified in the simulator, because there is no camera. So the
/// part that can be decided without hardware is decided here, as arithmetic on a
/// table, and the part that cannot — whether the sensor actually agrees — is a
/// live test that reads the EXIF tag back out of a captured photograph
/// (`LiveCaptureTests`). A mapping that is wrong here shows up as a sideways
/// photograph in a test on a phone, rather than as a sideways photograph for
/// every user.
///
/// ## The table, and why it is not symmetric between front and rear
///
/// A camera sensor has a fixed mounting in the phone. The rear sensors report
/// buffers that are already upright when the phone is held **landscape**, so
/// portrait needs a quarter turn. The front sensor is mounted mirrored relative
/// to the rear, so it starts 180° away — which is also why the app mirrors the
/// front (`CaptureSessionController.configureMirroring`), and why the two
/// concerns cannot be set independently and forgotten about.
///
/// **The front row is the one to distrust.** It is written from the mounting
/// relationship rather than measured, and the live test is what checks it. If a
/// selfie comes out upside down, this table is the first thing to look at and
/// the second thing is the mirroring.
struct CaptureOrientation: Sendable, Equatable {

    /// Clockwise degrees for `AVCaptureVideoPreviewLayer`.
    let previewAngle: CGFloat

    /// Clockwise degrees for `AVCapturePhotoOutput`.
    ///
    /// Separate from `previewAngle` because AVFoundation applies the photo's
    /// rotation as an **EXIF tag** rather than by rotating pixels, so the two
    /// are not the same number on every device — and a value that makes the
    /// preview look right while tagging the saved file wrong is the failure this
    /// pair of fields exists to make impossible to express.
    let captureAngle: CGFloat

    init(previewAngle: CGFloat, captureAngle: CGFloat) {
        self.previewAngle = previewAngle
        self.captureAngle = captureAngle
    }

    /// Only 0, 90, 180 and 270 are accepted by `isVideoRotationAngleSupported(_:)`.
    ///
    /// Anything else throws an `NSInvalidArgumentException` at the connection,
    /// which is a crash rather than an error, so the invariant is enforced by the
    /// type's own construction rather than by a comment at each call site.
    static func isSupported(_ angle: CGFloat) -> Bool {
        angle == 0 || angle == 90 || angle == 180 || angle == 270
    }

    /// The rotation for `orientation` on the camera at `position`.
    ///
    /// - Returns: `nil` when the device is flat or its orientation is unknown, so
    ///   the caller **keeps whatever it already applied** rather than snapping
    ///   to a default that would be wrong on a table.
    static func rotation(
        for orientation: DeviceOrientation,
        position: CameraPosition
    ) -> CaptureOrientation? {
        let quarterTurns: Int
        switch orientation {
        case .portrait: quarterTurns = 1
        case .portraitUpsideDown: quarterTurns = 3
        // `.landscapeLeft` is the device rotated so its **left** edge is up.
        // The rear sensor is upright in the opposite landscape, so this is the
        // zero-rotation case rather than a half turn.
        case .landscapeLeft: quarterTurns = 0
        case .landscapeRight: quarterTurns = 2
        case .faceUp, .faceDown, .unknown: return nil
        }

        // **Quarter turns as `Int`, converted to degrees once at the end.** The obvious
        // version does the arithmetic in `CGFloat` and wraps with `% 360` — and
        // `%` is unavailable on `CGFloat`, so it does not compile. Working in
        // turns is also just correct: every value in this table is an exact
        // multiple of 90, and integer turns cannot drift or round.
        let turns = position == .front ? (quarterTurns + 2) % 4 : quarterTurns
        let degrees = CGFloat(turns * 90)
        guard isSupported(degrees) else { return nil }

        return CaptureOrientation(previewAngle: degrees, captureAngle: degrees)
    }

    /// The rotation that leaves the image the right way up when the phone lies
    /// flat, used as the starting point before any orientation is reported.
    ///
    /// **A portrait default rather than landscape's zero**, because the app is
    /// portrait-first (ADR-019) and a first frame that appears sideways is the
    /// thing a user notices before anything else. Applied at session start so
    /// the very first frame is already right.
    static let startup = CaptureOrientation(previewAngle: 90, captureAngle: 90)
}
