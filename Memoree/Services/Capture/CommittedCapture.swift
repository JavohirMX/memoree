import Foundation

/// The Behind-the-Scenes clip a moment was committed with, if any.
///
/// ## Why a value and not a URL
///
/// A `URL` would be a path into a temporary directory the system purges whenever
/// it likes, and a reader would have no way to know that. Carrying the bytes
/// instead — capped, see `data` — means the value means the same thing at the
/// moment it is created as it does a minute later.
///
/// ## Why the clip is in here at all rather than written before
///
/// `ADR-022`'s ordering is *Photos first, record second, never repeat a step that
/// succeeded.* Writing the clip to the library as part of `saveMomentPair` would
/// put a second write in front of the moment, and a failure in it would either
/// strand an asset or cost the photographs. So the clip travels with the pair and
/// is written afterwards, on its own, where a failure is a failure to keep a
/// bonus rather than a failure to keep the moment.
struct CommittedBTS: Sendable, Equatable {

    /// The trimmed clip's bytes.
    let data: Data

    /// The `PHAsset.localIdentifier` it was written under, once it has been.
    var assetIdentifier: String?

    /// Whether the clip carries an audio track.
    ///
    /// **Carried rather than inferred**, because the microphone's authorisation
    /// can change between the recording and the trim and a silent clip is a
    /// supported outcome (ADR-013), not a failure to report.
    let hasAudio: Bool

    init(data: Data, hasAudio: Bool, assetIdentifier: String? = nil) {
        self.data = data
        self.hasAudio = hasAudio
        self.assetIdentifier = assetIdentifier
    }
}

/// A pair the user has accepted, and everything a recorded moment needs from it.
///
/// The boundary value between the camera screen and the archive. The camera
/// owns the capture and the library write; the archive owns the row. Neither
/// should have to know about the other, so the result travels as one immutable
/// value rather than as a live reference to either.
///
/// Lives in `Services/Capture` rather than `Models` because it references
/// `CapturedPhoto`, which is itself a service-layer type. Putting it in `Models`
/// would mean moving `CapturedPhoto` down a layer it does not belong in, or
/// carving an exception to "Models imports nothing internal".
struct CommittedCapture: Sendable, Equatable {

    /// Rear-camera photograph, as the bytes the camera produced.
    let back: CapturedPhoto

    /// Front-camera photograph, already mirrored by the capture connection.
    let front: CapturedPhoto

    /// The `PHAsset.localIdentifier`s the pair was written under.
    let assets: SavedAssetPair

    /// When the moment was **complete** — the second shutter press.
    ///
    /// Not the moment Post was tapped, and not the first photograph. The pair
    /// is two photographs taken up to half a minute apart while the user
    /// composes the selfie, and it stops being a moment at the second one.
    /// Using the commit time instead would make lateness depend on how long
    /// someone stared at the review screen, which is a fact about the review
    /// screen rather than about the moment.
    let capturedAt: Date

    /// How many halves were reshot to get here.
    let retakeCount: Int

    /// The Behind-the-Scenes clip, when BTS was on and one was produced.
    ///
    /// **`nil` is the ordinary case and is never an error.** BTS off, a recording
    /// shorter than `BTSTrim.minimumRecordedDuration`, and a microphone refusal are
    /// three different reasons for the same absence, and none of them is a failure
    /// the user did anything about. `ADR-013` says the clip is a bonus; the
    /// photographs are the moment.
    let bts: CommittedBTS?

    init(
        back: CapturedPhoto,
        front: CapturedPhoto,
        assets: SavedAssetPair,
        capturedAt: Date,
        retakeCount: Int,
        bts: CommittedBTS? = nil
    ) {
        self.back = back
        self.front = front
        self.assets = assets
        self.capturedAt = capturedAt
        self.retakeCount = retakeCount
        self.bts = bts
    }
}

/// Persists an accepted pair as a moment.
///
/// `@MainActor` because the implementation writes through `MomentStore`, which
/// is `@MainActor` and owns the app's only `ModelContext`.
///
/// **Injected rather than called directly, and that is the whole point.** The
/// camera screen must not reach into `Persistence` to build an archive row, and
/// the archive must not reach into a camera screen to ask what was captured. A
/// closure built at the composition root satisfies both: `Services` may not
/// import `Persistence` (AGENTS.md §3), so a service that needed the store could
/// not honestly exist, and a `Services`-level protocol for it would be an
/// abstraction with exactly one production implementation and no seam that
/// improved anything.
///
/// The `async throws` is not decoration. The Photos write happens before this
/// is called and can succeed while this fails, so the recovery path — retry
/// without writing to the library twice — has to be expressible.
typealias MomentRecorder = @MainActor (CommittedCapture) async throws -> Void
