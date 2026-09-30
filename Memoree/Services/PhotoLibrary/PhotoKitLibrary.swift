import CoreGraphics
import Foundation
import Photos
import UIKit

/// A lock-guarded box for identifiers produced inside a PhotoKit change block.
///
/// `performChanges` runs its block concurrently with the calling code, so
/// mutating a captured `var` from inside it is a data race that Swift 6 rejects
/// outright. Placeholders must be created in the block and read in the
/// completion handler, which run in sequence, so a locked reference box is the
/// correct bridge.
private final class PlaceholderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var backValue: String?
    private var frontValue: String?

    var back: String? {
        lock.lock(); defer { lock.unlock() }
        return backValue
    }

    var front: String? {
        lock.lock(); defer { lock.unlock() }
        return frontValue
    }

    func set(back: String?, front: String?) {
        lock.lock(); defer { lock.unlock() }
        backValue = back
        frontValue = front
    }
}

/// The production `PhotoLibraryService`, backed by PhotoKit.
///
/// Add-only, always. This type never calls
/// `PHPhotoLibrary.requestAuthorization(for: .readWrite)` and never enumerates
/// the library except to resolve identifiers it already owns (AGENTS.md §8).
///
/// Reads only touch assets identified by a saved moment, so Memoree cannot
/// browse the user's photographs even if it wanted to.
struct PhotoKitLibrary: PhotoLibraryService {

    private let albumName: String

    init(albumName: String = "Memoree") {
        self.albumName = albumName
    }

    // MARK: - Authorisation

    func authorizationStatus() -> PhotoAuthorizationStatus {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    func requestAuthorization() async -> PhotoAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return Self.map(status)
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoAuthorizationStatus {
        switch status {
        case .authorized:     return .authorized
        case .denied:         return .denied
        case .restricted:     return .restricted
        case .notDetermined:  return .notDetermined
        case .limited:       return .authorized   // add-only cannot be limited
        @unknown default:    return .notDetermined
        }
    }

    // MARK: - Writing

    /// Creates both assets inside a single `performChanges` block.
    ///
    /// GPS is injected before the write so the bytes handed to Photos already
    /// carry the coordinates, rather than relying on a second mutation that
    /// could fail after the fact and leave a photo without its metadata.
    func saveMomentPair(
        backData: Data,
        frontData: Data,
        location: PhotoLocation?
    ) async throws -> SavedAssetPair {
        let back = try PhotoMetadataInjector.applying(location: location, to: backData)
        let front = try PhotoMetadataInjector.applying(location: location, to: frontData)

        return try await withCheckedThrowingContinuation { continuation in
            // A reference box rather than captured `var`s: the PhotoKit change
            // block runs concurrently, and Swift 6 correctly rejects mutating
            // captured variables from it.
            let created = PlaceholderBox()

            PHPhotoLibrary.shared().performChanges({
                // Two independent creation requests inside ONE change block, so
                // the pair is atomic. A half-saved moment is a broken invariant
                // (ADR-004).
                let backRequest = PHAssetCreationRequest.forAsset()
                backRequest.addResource(with: .photo, data: back, options: nil)

                let frontRequest = PHAssetCreationRequest.forAsset()
                frontRequest.addResource(with: .photo, data: front, options: nil)

                // Placeholders are valid inside the block and their identifiers
                // remain valid afterwards — the intended mechanism for learning
                // the identifiers of assets just created.
                created.set(
                    back: backRequest.placeholderForCreatedAsset?.localIdentifier,
                    front: frontRequest.placeholderForCreatedAsset?.localIdentifier
                )
            }, completionHandler: { success, error in
                guard success,
                      let backID = created.back,
                      let frontID = created.front
                else {
                    continuation.resume(throwing: LibraryError.writeFailed(
                        error?.localizedDescription ?? "unknown"
                    ))
                    return
                }
                continuation.resume(returning: SavedAssetPair(back: backID, front: frontID))
            })
        }
    }

    func saveBTS(_ data: Data) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let created = PlaceholderBox()

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, data: data, options: nil)
                created.set(
                    back: request.placeholderForCreatedAsset?.localIdentifier,
                    front: nil
                )
            }, completionHandler: { success, error in
                guard success, let identifier = created.back else {
                    continuation.resume(throwing: LibraryError.writeFailed(
                        error?.localizedDescription ?? "unknown"
                    ))
                    return
                }
                continuation.resume(returning: identifier)
            })
        }
    }

    /// Adds already-created assets to the `Memoree` album.
    ///
    /// Separate from creation because the album is optional and default-off, and
    /// because adding to a collection must reference assets that already exist.
    @discardableResult
    func addAssets(_ identifiers: [String], toAlbumNamed name: String) async throws -> String? {
        guard !identifiers.isEmpty else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count == identifiers.count else {
            throw LibraryError.assetMissing("one or more assets did not resolve")
        }

        let albumID = try await ensureAlbum(named: name)
        guard let albumID,
              let album = PHAssetCollection.fetchAssetCollections(
                  withLocalIdentifiers: [albumID], options: nil).firstObject
        else { throw LibraryError.albumUnavailable }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
                request.addAssets(assets)
            }, completionHandler: { success, error in
                success
                    ? continuation.resume()
                    : continuation.resume(throwing: LibraryError.writeFailed(
                        error?.localizedDescription ?? "unknown"))
            })
        }
        return albumID
    }

    // MARK: - Albums

    func ensureAlbum(named name: String) async throws -> String? {
        // `PHFetchResult` is neither `Sequence` nor `Collection`, so the
        // enumerator block is the supported way to scan it for a title.
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [], options: nil
        )
        let found = PlaceholderBox()
        collections.enumerateObjects { collection, _, stop in
            if collection.localizedTitle == name {
                found.set(back: collection.localIdentifier, front: nil)
                stop.pointee = true
            }
        }
        if let identifier = found.back { return identifier }

        let created = PlaceholderBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                    withTitle: name)
                created.set(
                    back: request.placeholderForCreatedAssetCollection.localIdentifier,
                    front: nil
                )
            }, completionHandler: { success, _ in
                success
                    ? continuation.resume()
                    : continuation.resume(throwing: LibraryError.albumUnavailable)
            })
        }
        return created.back
    }

    // MARK: - Reading

    func image(for identifier: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject else { return nil }

        let manager = PHCachingImageManager()
        let options = PHImageRequestOptions()
        // `highQualityFormat` rather than `opportunistic`, deliberately.
        //
        // Opportunistic delivers twice — a fast degraded image, then the real
        // one. Bridging that into a single-value `async` call needs a counter or
        // a "resume once" guard, and either risks leaving the continuation
        // suspended if Photos only ever calls back once (an asset still in
        // iCloud, with network access disabled). A dangling continuation is
        // worse than a slightly slower thumbnail, and these are small cell
        // images where the difference is imperceptible.
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                // Exactly one callback in high-quality mode.
                continuation.resume(returning: image)
            }
        }
    }

    func assetExists(_ identifier: String) async -> Bool {
        // `count > 0` rather than `!isEmpty`: `PHFetchResult` is neither a
        // `Sequence` nor a `Collection`, so it has no `isEmpty`. `empty_count`
        // wants the other spelling; the compiler has the final say.
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count > 0
    }

    /// Original bytes for sharing.
    ///
    /// Deliberately not a `CGImage`: `requestImageDataAndOrientation` hands back
    /// the original encoded bytes, which is what sharing needs. Decoding to a
    /// `CGImage` would silently recompress the file.
    func data(for identifier: String) async throws -> Data {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject else {
            throw LibraryError.assetMissing(identifier)
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.version = .current
        options.deliveryMode = .highQualityFormat

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: LibraryError.assetMissing(identifier))
                }
            }
        }
    }
}
