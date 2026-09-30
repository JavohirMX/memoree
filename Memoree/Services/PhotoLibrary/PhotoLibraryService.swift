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

    /// Original bytes for sharing out of the app.
    func data(for identifier: String) async throws -> Data

    // MARK: Albums

    /// Ensures the optional `Memoree` album exists and returns its identifier.
    func ensureAlbum(named name: String) async throws -> String?
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
struct SavedAssetPair: Sendable, Equatable {
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
