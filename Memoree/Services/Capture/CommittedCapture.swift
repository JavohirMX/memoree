import Foundation

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

    init(
        back: CapturedPhoto,
        front: CapturedPhoto,
        assets: SavedAssetPair,
        capturedAt: Date,
        retakeCount: Int
    ) {
        self.back = back
        self.front = front
        self.assets = assets
        self.capturedAt = capturedAt
        self.retakeCount = retakeCount
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
