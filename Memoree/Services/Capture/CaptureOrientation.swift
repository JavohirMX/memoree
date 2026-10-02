import CoreGraphics
import Foundation

/// The rotation to apply to the preview and to the photo, in degrees clockwise.
///
/// ## Why this is a carrier and not a table
///
/// This type used to contain a hand-written table mapping held orientation to
/// angle. **That was the wrong design and it did not work**, for two reasons
/// that only became clear when a landscape photograph came back saved as a
/// portrait one:
///
/// 1. **No table can know how a phone's sensor is mounted.** Every iPhone is
///    slightly different, and Apple's answer to "how far must I rotate this" is
///    `AVCaptureDevice.RotationCoordinator`, which reads the device's physical
///    orientation and hands back an angle relative to gravity. A table is that
///    answer hardcoded per model, which is a guess wearing a constant.
/// 2. **A table needs a trustworthy orientation to map *from*, and there isn't
///    one.** It came from `UIDevice.current.orientation`, which returns
///    `.unknown` until notifications are switched on, and — the real one —
///    **returns `.portrait` forever when the user has rotation lock on.** So the
///    table applied a quarter turn to every photograph including the ones taken
///    sideways, and every sideways photograph saved as a portrait one.
///
/// So the angles arrive from AVFoundation, and this type only carries them. What
/// stays pure and testable is the *shape* of the answer: two angles, because a
/// preview layer and a photo output are two different connections, and only 0/90/
/// 180/270 are legal on either.
struct CaptureOrientation: Sendable, Equatable {

    /// Clockwise degrees for `AVCaptureVideoPreviewLayer`.
    let previewAngle: CGFloat

    /// Clockwise degrees for `AVCapturePhotoOutput`.
    ///
    /// Separate from `previewAngle` because AVFoundation applies them differently
    /// — a transform on the preview layer's contents, an **EXIF tag** on the
    /// photograph — and because the coordinator computes them separately. A value
    /// that makes the preview look right while tagging the saved file wrong is
    /// the failure this pair of fields exists to make impossible to express.
    let captureAngle: CGFloat

    init(previewAngle: CGFloat, captureAngle: CGFloat) {
        self.previewAngle = previewAngle
        self.captureAngle = captureAngle
    }

    /// Only 0, 90, 180 and 270 are accepted by `isVideoRotationAngleSupported(_:)`.
    ///
    /// Anything else throws an `NSInvalidArgumentException` at the connection,
    /// which is a crash rather than an error, so the check is a named function
    /// rather than a comment at each call site.
    static func isSupported(_ angle: CGFloat) -> Bool {
        angle == 0 || angle == 90 || angle == 180 || angle == 270
    }

    /// The rotation in force before AVFoundation has told us anything.
    ///
    /// **Portrait, because portrait is where the app is opened and where it
    /// lives most of the time.** It is replaced within a frame of the session
    /// opening by the coordinator's first answer, and it exists so the very
    /// first preview frame is not the camera's landscape default — a first frame
    /// that appears sideways is the first thing anyone notices.
    static let startup = CaptureOrientation(previewAngle: 90, captureAngle: 90)
}
