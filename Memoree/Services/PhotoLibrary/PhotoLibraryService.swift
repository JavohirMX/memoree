import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Writes a captured pair to the user's Photos library and reads assets back out.
///
/// A protocol so tests never need a real library (AGENTS.md §3). Two halves:
/// the capture path, which only ever *adds*, and the read path the archive needs
/// for thumbnails.
protocol PhotoLibraryService: Sendable {

    // MARK: Authorisation

    /// Current authorisation status.
    func authorizationStatus() -> PhotoAuthorizationStatus

    /// Requests add-only authorisation.
    ///
    /// Never requests `.readWrite`. Memoree writes photographs and does not read
    /// the user's library beyond the identifiers it already owns (AGENTS.md §8).
    func requestAuthorization() async -> PhotoAuthorizationStatus

    // MARK: Writing

    /// Creates the two assets for a moment inside a single change block.
    ///
    /// Atomic by construction: either both photographs land or neither does. A
    /// half-saved moment is a broken invariant.
    ///
    /// - Parameters:
    ///   - backData: Rear-camera bytes straight from `fileDataRepresentation()`,
    ///     which already carry capture EXIF.
    ///   - frontData: Front-camera bytes, mirrored by the capture connection.
    ///   - location: Optional coordinates to inject. Never reverse-geocoded.
    func saveMomentPair(
        backData: Data,
        frontData: Data,
        location: PhotoLocation?
    ) async throws -> SavedAssetPair

    /// Writes an optional Behind-The-Scenes video alongside a moment.
    func saveBTS(_ data: Data) async throws -> String

    /// Writes an exported video file to the user's Photos library.
    func saveVideo(at fileURL: URL) async throws -> String

    /// Generates a timelapse flipbook video from the provided moments and saves it to Photos.
    ///
    /// - Parameters:
    ///   - moments: Moments in chronological order to include in the timelapse.
    ///   - framesPerSecond: Frame rate (default: 2 fps = 0.5s per day).
    /// - Returns: Local identifier of the created video asset.
    func exportFlipbookVideo(
        for moments: [MomentFacts],
        framesPerSecond: Int32
    ) async throws -> String

    // MARK: Reading

    /// A downsampled image for an archive cell.
    ///
    /// Returns `nil` when the asset no longer exists — the user may have deleted
    /// it from Photos deliberately, which is not an error (ADR-008).
    ///
    /// `UIImage` rather than `CGImage` because that is what PhotoKit's
    /// `requestImage` hands back, and converting would be a pointless hop.
    func image(for identifier: String, targetSize: CGSize) async -> UIImage?

    /// Whether an asset still exists. Drives tombstoning of orphaned moments.
    func assetExists(_ identifier: String) async -> Bool

    #if DEBUG
    /// Every image identifier in the library, oldest first.
    ///
    /// **Debug-only, and it exists because the layout audit needs real pixels.**
    /// `-MemoreeSeedMoments` deliberately writes no identifiers so a debug launch
    /// cannot put photographs into a user's camera roll (ADR-008); the
    /// consequence is that every seeded cell renders as "no photographs on
    /// record", which exercises none of the geometry that a real photograph
    /// reveals. This reads identifiers that are *already* in the library — on a
    /// simulator, `simctl addmedia` put them there — and attaches them to seeded
    /// rows.
    ///
    /// **Not on the protocol in release.** A production build has no use for an
    /// enumeration of the user's whole library, and add-only authorisation is
    /// precisely the permission that makes such a method alarming to read.
    func allImageAssetIdentifiers() -> [String]
    #endif

    /// Warms Photos' own cache for identifiers about to be displayed.
    ///
    /// Separate from `image(for:targetSize:)` because the two do different jobs
    /// and only one of them can be awaited. The decoded-image cache behind
    /// `image` makes the *second* draw of a cell free; this makes the *first*
    /// one cheap, which is the one a scrolling grid actually pays for. A grid
    /// without it shows empty cells that fill in late, which reads as a broken
    /// screen rather than a slow one.
    ///
    /// Best-effort. A prefetch that cannot be started is not an error — the cell
    /// requests the image itself when it draws.
    func prefetchThumbnails(_ identifiers: [String], targetSize: CGSize) async

    /// Stops warming.
    ///
    /// Takes a `targetSize` because Photos caches per size, so warming can only
    /// be stopped for the size it was started at. Cancelling the wrong size
    /// silently does nothing, which is why the size travels with the call.
    func cancelThumbnailPrefetch(targetSize: CGSize) async

    /// Drops every decoded image this service is holding.
    ///
    /// Called when the archive is dismissed. A grid's worth of decoded images is
    /// memory the camera will want next, and the camera is the screen that
    /// cannot afford to be slow.
    func purgeImageCache() async

    /// Original bytes for sharing out of the app.
    func data(for identifier: String) async throws -> Data

    /// Writes a Behind-the-Scenes clip to a file this app controls, for playback.
    ///
    /// ## Why a file and not an `AVAsset`
    ///
    /// `PHImageManager.requestAVAsset(forVideo:)` would hand back an `AVAsset`,
    /// which is exactly the wrong thing to put on a protocol that `Features/`
    /// consumes: it drags AVFoundation across the layer boundary, it is not
    /// `Sendable`, and its `url` for a library asset is an implementation detail
    /// that is not guaranteed to be a readable path. `PHAssetResourceManager
    /// .writeData(for:toFile:)` is the API that says what it does — give me this
    /// resource's bytes, in this file — and a `URL` is something a view model can
    /// hold, pass, and test.
    ///
    /// **A temp file, and that is not app storage.** The bytes already live in the
    /// user's Photos library; this is a copy made so a player has something to
    /// open, in the temporary directory, deleted by
    /// `purgeBTSPlaybackFiles()`. `AGENTS.md` §2.4 forbids keeping image bytes in
    /// app storage and this keeps none.
    ///
    /// - Throws: `LibraryError.assetMissing` when the user deleted the clip. That
    ///   is a supported state, not an error the user caused (ADR-008).
    func btsClipFile(for identifier: String) async throws -> URL

    /// Deletes every file `btsClipFile(for:)` has written.
    ///
    /// **Called when playback stops**, not on a timer. A clip left in the temporary
    /// directory is bytes the app wrote and nobody is reading, and the system would
    /// eventually purge them — which is how a five-second video becomes
    /// thirty megabytes of nothing over a year of moments.
    func purgeBTSPlaybackFiles()

    // MARK: Albums

    /// Ensures the optional `Memoree` album exists and returns its identifier.
    func ensureAlbum(named name: String) async throws -> String?

    /// Adds already-created assets to a named album, creating it if needed.
    ///
    /// Separate from `saveMomentPair` because it has to run *after* the assets
    /// exist: adding to a collection references assets by identifier, so the two
    /// cannot share a `performChanges` block. The consequence is that an album
    /// failure happens after the photographs are safely in the library, which is
    /// why the caller treats it as a note rather than a failure — see
    /// `CameraViewModel.fileIntoAlbumIfAsked`.
    @discardableResult
    func addAssets(_ identifiers: [String], toAlbumNamed name: String) async throws -> String?
}

/// Coordinates attached to a moment. Never resolved to a place name.
///
/// There is no `CLGeocoder` anywhere in Memoree. Storing raw coordinates keeps the
/// no-network invariant intact and is a materially better privacy posture than
/// publishing place strings alongside a position.
struct PhotoLocation: Sendable, Equatable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// The identifiers of a saved moment pair.
///
/// `Hashable` because it rides along inside `MomentFacts`, which is. It is two
/// strings and nothing else, so the conformance is free — and making the
/// snapshot `Hashable` is what lets a view diff it for redraws without
/// holding onto a non-`Sendable` managed object.
struct SavedAssetPair: Sendable, Equatable, Hashable {
    let back: String
    let front: String

    init(back: String, front: String) {
        self.back = back
        self.front = front
    }
}

/// Mirrors `PHAuthorizationStatus` without leaking PhotoKit into call sites that
/// only need to branch on the outcome.
enum PhotoAuthorizationStatus: Sendable, Equatable {
    /// Not yet asked.
    case notDetermined
    /// Granted, including limited-library access.
    case authorized
    /// The user said no. Memoree stays usable; moments simply stay in the app.
    case denied
    /// Blocked by device policy or parental controls.
    case restricted
    /// Ask again later.
    case undetermined
}

enum LibraryError: Error, LocalizedError, Equatable {
    case authorizationDenied
    case invalidImageData
    case assetMissing(String)
    case albumUnavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Memoree needs permission to add photos to your library."
        case .invalidImageData:
            "The captured photo could not be read."
        case .assetMissing:
            "That photo is no longer in your library."
        case .albumUnavailable:
            "Memoree could not create the album."
        case .writeFailed(let reason):
            "Could not save to your photo library: \(reason)"
        }
    }
}
