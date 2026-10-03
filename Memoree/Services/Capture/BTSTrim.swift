import Foundation

/// The arithmetic of keeping the last few seconds of a continuous recording.
///
/// ## Why this is not in `CMTime`
///
/// `AVAssetExportSession` asks for a `CMTimeRange`, and computing one directly
/// is the obvious thing to do. Every rule that can actually go wrong here is
/// arithmetic on seconds, though, and a plan over `TimeInterval` is testable on a
/// simulator with no asset, no export session and no camera — the same split
/// `CaptureFormatSelector` makes between its pure arithmetic and the one-line
/// wrapper that maps a real device's format list onto it.
///
/// `Double` rather than `CMTime` for the same reason, with one caveat worth
/// stating: CoreMedia counts in 600ths of a second, so a plan computed here is
/// quantised when it is converted at the boundary. **Quantising later is the
/// point.** Converting first means a rounding error can arrive at the export
/// session as an inverted or empty range, which it rejects — and a rejected
/// range produces no clip and no error the caller can act on, which is the exact
/// failure the plan's own nil return exists to make impossible.
///
/// ## The shape of the answer
///
/// Keep the **tail** of the recording, never the head. ADR-013: BTS is the few
/// seconds *before* the shutter, so a recording opened on the camera screen and
/// trimmed at commit must yield the moment itself, not the moment the user
/// arrived at the camera.
enum BTSTrim {

    /// A range to keep: an offset into the recording, and how long to run for.
    ///
    /// `duration` rather than `end`, because the two invariants that matter are
    /// "never negative" and "never past the end of the recording", and both are
    /// stated more directly about a duration. `end` is derived.
    struct Window: Equatable, Hashable, Sendable {

        /// Seconds from the start of the recording.
        let start: TimeInterval

        /// How many seconds to keep. Never negative, never longer than the
        /// recording.
        let duration: TimeInterval

        /// Where the kept clip ends within the recording.
        var end: TimeInterval { start + duration }

        init(start: TimeInterval, duration: TimeInterval) {
            self.start = start
            self.duration = duration
        }
    }

    /// A recording shorter than this is a keypress, not a clip.
    ///
    /// **Why a floor at all.** The zero-length guard in the plan clamps the trim
    /// range at zero, which prevents an inverted range and nothing else. It
    /// cannot prevent a *very short* one: a user who opens the camera and fires
    /// twice inside half a second produces a recording around 0.4s, and 0.4s of
    /// video is a real, exportable, unplayable-looking asset. Writing that into
    /// somebody's camera roll — and then, once playback exists, offering a play
    /// button that shows a frozen frame — is worse than recording nothing, so
    /// below this floor there is no clip and the moment is photographs only.
    ///
    /// Half a second is short enough never to cost a real capture: the fastest
    /// capture this app can produce is the two shutter presses of a moment, and
    /// the recorder runs for the whole time the camera screen is open, not for
    /// the gap between them.
    static let minimumRecordedDuration: TimeInterval = 0.5

    /// ADR-013's default. Five seconds, matching what BeReal retains.
    static let defaultClipDuration: TimeInterval = 5

    /// Ceiling on what the user may ask for.
    ///
    /// Not a hardware limit — a phone will happily record a minute — but a
    /// product one. The moment is two photographs and five seconds of context;
    /// a clip long enough to be the interesting part of the day is a video app
    /// wearing this app's name.
    static let maximumClipDuration: TimeInterval = 15

    /// The last `clipDuration` seconds of a recording `recordedDuration` long.
    ///
    /// - Returns: the window to keep, or `nil` when there is nothing worth
    ///   keeping. **The nil is the zero-length guard.** An inverted range is not
    ///   a range, and every caller would then have to handle a clip that is
    ///   somehow both present and empty.
    static func window(recordedDuration: TimeInterval, clipDuration: TimeInterval) -> Window? {
        guard recordedDuration >= minimumRecordedDuration else { return nil }

        // `max(0, …)` on the requested duration as well as on the result: this
        // reads a persisted `Double`, and a corrupt or hand-edited store carries
        // a negative one. Clamping here is the difference between "no clip" and
        // "an export session handed a negative range".
        let requested = max(0, clipDuration)
        let kept = min(recordedDuration, requested)
        guard kept > 0 else { return nil }

        // `recordedDuration - kept`, not `recordedDuration - requested`. When the
        // recording is shorter than the request the two differ, and this form
        // keeps the arithmetic exact in floating point rather than subtracting a
        // large number from a larger one and hoping.
        return Window(start: recordedDuration - kept, duration: kept)
    }

    /// A user's requested clip duration, clamped into something meaningful.
    ///
    /// Applied on every read of the persisted setting rather than once at the
    /// write, for the reason `TimeWindow.validated` exists: these values come
    /// from a store, and a corrupt one should degrade rather than crash.
    ///
    /// The floor is `minimumRecordedDuration` and not zero, because asking for a
    /// clip shorter than the floor can never produce one — clamping to the floor
    /// means the setting and the recorder agree about what is possible instead
    /// of the recorder silently refusing.
    static func validatedClipDuration(_ requested: TimeInterval) -> TimeInterval {
        // **`isNaN`, not `isFinite`.** Every comparison against `NaN` is false,
        // so Swift's `min`/`max` pass it straight through and a `NaN` reaches the
        // export session un-clamped — which is the one input the clamp exists to
        // catch. Testing `isFinite` instead handles `NaN` at the cost of two
        // wrong answers: an infinite setting became the *default* rather than
        // the end of the range it names. `+∞` means "as long as allowed", which
        // is the ceiling, and `-∞` falls to the floor by the same arithmetic
        // that handles every other value.
        guard !requested.isNaN else { return defaultClipDuration }
        return min(max(requested, minimumRecordedDuration), maximumClipDuration)
    }
}
