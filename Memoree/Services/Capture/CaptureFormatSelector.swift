import AVFoundation
import Foundation

/// Chooses which sensor format the photo output records at.
///
/// Two parts, deliberately separated:
///
/// - `bestDimensions(from:)` is **pure arithmetic over `CMVideoDimensions`**.
///   It is the part that silently picks a 16:9 sensor when it is supposed to
///   pick 3:4, and it is testable on the simulator, which has no camera.
/// - `selectFormat(for:)` is a one-line wrapper that maps a real device's
///   format list into dimensions and applies the result.
///
/// ## Why `.inputPriority` rather than a preset
///
/// `sessionPreset` is unreliable across a mid-session input swap (TRD §5.3).
/// A preset is a hint the session may reinterpret when inputs change, so the
/// format actually in use after a swap is not the one that was asked for.
/// `.inputPriority` promises only that explicit per-device settings are
/// honoured, which is the property this code depends on.
enum CaptureFormatSelector {

    /// Portrait 3:4 — the geometry BeReal publishes and the camera roll is
    /// overwhelmingly full of, so saved assets sit naturally in the library.
    static let targetRatio: Double = 3.0 / 4.0

    /// How far from exactly 3:4 a format may be and still qualify.
    ///
    /// Real sensors do not land on 0.75 exactly; 1512×2016 is 0.75, but
    /// 1440×1920 is 0.75 and 1080×1440 is 0.75, while some report 0.749 or
    /// 0.751 after rounding. Two percent is loose enough to admit those and
    /// tight enough to exclude 4:3 (0.75 vs 0.75 — same thing) and 16:9
    /// (1.333, 78% away) decisively.
    static let ratioTolerance: Double = 0.02

    /// The minimum frame rate to require of a format.
    ///
    /// Thirty is enough for a still capture and meaningfully narrows the
    /// candidate list on devices whose low-resolution formats are capped lower.
    static let minimumFrameRate: Int32 = 30

    // MARK: - Pure selection

    /// The widest candidate whose aspect ratio is 3:4 within tolerance.
    ///
    /// Pure: no AVFoundation state, no device, no clock. Every rule that can
    /// pick the wrong sensor lives here so it can be tested without hardware.
    ///
    /// - Parameters:
    ///   - candidates: Formats already filtered to those that support
    ///     `minimumFrameRate`. Filtering is the caller's job because it needs
    ///     the device, and keeping it out means this function has no
    ///     `AVCaptureDevice` dependency to stub.
    /// - Returns: The widest qualifying format, or `nil` when none qualifies.
    ///   Returning `nil` rather than falling back to an arbitrary format is
    ///   deliberate: silently choosing 16:9 would produce moments that look
    ///   subtly wrong forever, and `noInputAvailable` is recoverable where a
    ///   wrong aspect ratio is not.
    static func bestDimensions(from candidates: [CMVideoDimensions]) -> CMVideoDimensions? {
        candidates
            .filter(isThreeByFour)
            .max { lhs, rhs in
                // Compare by pixel area, not width: two 3:4 formats have
                // proportional widths, so area and width agree — but stating
                // the intent as area keeps it correct if the tolerance ever
                // admits a non-proportional pair.
                area(of: lhs) < area(of: rhs)
            }
    }

    /// Whether these dimensions are portrait 3:4 within tolerance.
    ///
    /// Portrait only. A landscape 4:3 sensor rotated 90° is the same
    /// photograph, but `fileDataRepresentation()` applies the orientation
    /// itself, so accepting a landscape format here would yield a photo whose
    /// stored orientation disagrees with its pixels.
    static func isThreeByFour(_ dimensions: CMVideoDimensions) -> Bool {
        guard dimensions.height > 0, dimensions.width > 0 else { return false }
        // A landscape 3:4 is 4:3, not 3:4. Rejecting it here is what keeps
        // orientation handling in one place.
        guard dimensions.width < dimensions.height else { return false }
        let ratio = Double(dimensions.width) / Double(dimensions.height)
        return abs(ratio - targetRatio) <= ratioTolerance
    }

    static func area(of dimensions: CMVideoDimensions) -> Int {
        Int(dimensions.width) * Int(dimensions.height)
    }

    /// Whether `format` can be driven at `minimumFrameRate` or better.
    ///
    /// Read from `videoSupportedFrameRateRanges` rather than a convenience
    /// predicate. The older `isFormatSampleRateAndResolutionSupported(_:)` is
    /// gone from the iOS 27 SDK; the ranges are the underlying data it consulted,
    /// so this is equivalent and does not depend on a convenience API that has
    /// already been removed once.
    static func supportsMinimumFrameRate(
        _ format: AVCaptureDevice.Format,
        minimum: Double = Double(minimumFrameRate)
    ) -> Bool {
        format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= minimum }
    }

    // MARK: - Device-backed selection

    /// The format to record at on `device`, or `nil` when nothing qualifies.
    ///
    /// `.builtInWideAngleCamera` only — never the telephoto or ultra-wide. The
    /// pair is supposed to read as "the scene" and "you", and a 5× lens is
    /// neither (TRD §5.3).
    static func selectFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let qualifying = device.formats.filter { format in
            supportsMinimumFrameRate(format) && isThreeByFour(dimensions(of: format))
        }

        guard let best = bestDimensions(from: qualifying.map(dimensions(of:))) else {
            return nil
        }

        // Recover the original format rather than reconstructing one: a format
        // must be applied to the device that produced it.
        return qualifying.first { matches(dimensions(of: $0), best) }
    }

    static func dimensions(of format: AVCaptureDevice.Format) -> CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    }

    /// Field-wise `CMVideoDimensions` equality.
    ///
    /// The C struct is not `Equatable`, and synthesising conformance is not
    /// possible for it. Written out so the intent is readable at the call site
    /// rather than hidden behind a tuple conversion.
    static func matches(_ lhs: CMVideoDimensions, _ rhs: CMVideoDimensions) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }

    /// The front-camera wide angle, or `nil` when the device has none.
    static func wideAngleDevice(for position: CameraPosition) -> AVCaptureDevice? {
        AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: avFoundationPosition(for: position)
        )
    }

    /// The `AVCaptureDevice.Position` matching a `CameraPosition`.
    ///
    /// Spelled out rather than reusing a raw `AVCaptureDevice.Position`
    /// throughout, so the domain type stays free of AVFoundation at its
    /// boundaries (AGENTS.md §3).
    static func avFoundationPosition(for position: CameraPosition) -> AVCaptureDevice.Position {
        switch position {
        case .back: return .back
        case .front: return .front
        }
    }
}
