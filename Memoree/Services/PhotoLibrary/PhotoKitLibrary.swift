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

    /// One manager for the lifetime of the service, and a decoded-image cache
    /// beside it.
    ///
    /// `image(for:targetSize:)` used to construct a `PHCachingImageManager`
    /// inside the function body. That is invisible behind a single composite and
    /// ruinous behind a grid, because **the cache lives on the manager** — a
    /// manager created per request caches nothing, so every scroll of every cell
    /// went to Photos. See `ArchiveThumbnailCache` for the two tiers.
    private let imageManager = PHCachingImageManager()
    private let thumbnails = ArchiveThumbnailCache()

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
        let status = authorizationStatus()
        if status == .notDetermined {
            let requested = await requestAuthorization()
            guard requested == .authorized else {
                throw LibraryError.authorizationDenied
            }
        } else if status == .denied || status == .restricted {
            throw LibraryError.authorizationDenied
        }

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
        let status = authorizationStatus()
        if status == .notDetermined {
            let requested = await requestAuthorization()
            guard requested == .authorized else {
                throw LibraryError.authorizationDenied
            }
        } else if status == .denied || status == .restricted {
            throw LibraryError.authorizationDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
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
        // Search by **kind**, not by identifiers.
        //
        // This asked `fetchAssetCollections(withLocalIdentifiers: [])` — a
        // fetch for *zero* specific identifiers, which returns an empty result
        // and therefore never finds anything. Every call fell through to the
        // creation path, so the function created a fresh album every time it was
        // asked for one that already existed. A live device test caught it on
        // the first hardware run of Phase 3; the simulator could not, because it
        // cannot create an album at all.
        //
        // The bug was invisible in the app for a second reason: `saveToAlbum`
        // defaults to **off** and `albumCreationAttempted` guards the rest, so
        // no production path reaches this until the user turns it on in Settings
        // (Phase 10). The one caller that would have hit it was not reachable
        // yet. Two layers of "not shipped" hid a defect that the first real
        // invocation exposed.
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil
        )

        // `PHFetchResult` is neither `Sequence` nor `Collection`, so the
        // enumerator block is the supported way to scan it for a title.
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

    /// The cache key for an image at a size.
    ///
    /// Size is part of the key and not a detail: Photos will hand back a
    /// different decode for a thumbnail and for a full-screen image, so a
    /// key that omitted the size would return a 96pt thumbnail where a
    /// 1080pt image was asked for — a bug that renders as a blurry archive
    /// detail and reads as a Photos problem rather than a cache one.
    nonisolated static func cacheKey(_ identifier: String, targetSize: CGSize) -> String {
        let width = Int(targetSize.width.rounded())
        let height = Int(targetSize.height.rounded())
        return "\(identifier)@\(width)x\(height)"
    }

    func image(for identifier: String, targetSize: CGSize) async -> UIImage? {
        let key = Self.cacheKey(identifier, targetSize: targetSize)
        if let cached = thumbnails.cached(key) { return cached }

        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject else { return nil }

        let manager = imageManager
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

        let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
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

        if let image { thumbnails.store(image, for: key) }
        return image
    }

    // MARK: - Prefetching

    func prefetchThumbnails(_ identifiers: [String], targetSize: CGSize) async {
        await thumbnails.prefetch(
            identifiers: identifiers,
            targetSize: targetSize,
            manager: imageManager,
            options: Self.prefetchOptions
        )
    }

    func cancelThumbnailPrefetch(targetSize: CGSize) async {
        await thumbnails.stopPrefetching(
            targetSize: targetSize,
            manager: imageManager,
            options: Self.prefetchOptions
        )
    }

    func purgeImageCache() async {
        thumbnails.removeAll()
    }

    /// Options for warming, kept separate from the request options on purpose.
    ///
    /// `isSynchronous = false` is what makes this a *prefetch*: warming happens
    /// off the main thread and the call returns immediately. And
    /// `deliveryMode` is irrelevant here because `startCachingImages` does not
    /// deliver, which is the whole difference between the two APIs.
    private static var prefetchOptions: PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        return options
    }

    func assetExists(_ identifier: String) async -> Bool {
        // `count > 0` rather than `!isEmpty`: `PHFetchResult` is neither a
        // `Sequence` nor a `Collection`, so it has no `isEmpty`. `empty_count`
        // wants the other spelling; the compiler has the final say.
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count > 0
    }

    #if DEBUG
    func allImageAssetIdentifiers() -> [String] {
        // **Debug-only.** Enumerating the library is exactly what add-only
        // authorisation exists to make unnecessary, so this is compiled out of
        // release — see the protocol's declaration for why the layout audit needs
        // it and why it must not ship.
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)

        var identifiers: [String] = []
        result.enumerateObjects { asset, _, _ in identifiers.append(asset.localIdentifier) }
        return identifiers
    }
    #endif

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

    // MARK: - Behind the Scenes playback

    /// Where playable copies of BTS clips live.
    ///
    /// **Its own directory, not the recorder's.** The recorder writes the clips it
    /// is about to hand to Photos and deletes them itself; this holds copies made
    /// for a player, which have a different lifetime and a different owner. Two
    /// directories means one can be swept without touching the other — a shared one
    /// would make `purgeBTSPlaybackFiles` a race against an in-progress commit.
    private static let playbackDirectory: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memoree-bts-playback", isDirectory: true)
    }()

    /// A deterministic name, so replaying the same moment overwrites its own file
    /// rather than accumulating one per play.
    ///
    /// **Not a hash.** The identifier is already filesystem-safe — it is a
    /// `PHAsset.localIdentifier`, a UUID-shaped string — and a hash would only add
    /// a collision question nobody needs answered.
    private func playbackPath(for identifier: String) -> URL {
        Self.playbackDirectory.appendingPathComponent("playback-\(identifier).mov")
    }

    func btsClipFile(for identifier: String) async throws -> URL {
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier], options: nil
        ).firstObject else {
            // The user deleted the clip in Photos. Supported, not an error — see
            // ADR-008 and `MomentFacts.btsAssetIdentifier`.
            throw LibraryError.assetMissing(identifier)
        }

        guard let resource = PHAssetResource.assetResources(for: asset).first else {
            throw LibraryError.assetMissing(identifier)
        }

        let destination = playbackPath(for: identifier)
        try FileManager.default.createDirectory(
            at: Self.playbackDirectory, withIntermediateDirectories: true
        )

        return try await withCheckedThrowingContinuation { continuation in
            // **`options: nil` rather than `PHAssetResourceRequestOptions()` with
            // `networkAccessAllowed = false`.** Unlike `PHImageRequestOptions`, this
            // one has no `isNetworkAccessAllowed` — a resource write is a file copy
            // out of what is already on this device, and an asset whose only copy is
            // in iCloud is simply not on the device, which `assetMissing` reports.
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: nil,
                completionHandler: { error in
                    if let error {
                        // **A half-written file is worse than none.** A player given
                        // a truncated clip shows a frozen frame, which is the exact
                        // failure this whole seam exists to avoid.
                        try? FileManager.default.removeItem(at: destination)
                        continuation.resume(throwing: LibraryError.writeFailed(
                            error.localizedDescription
                        ))
                    } else {
                        continuation.resume(returning: destination)
                    }
                }
            )
        }
    }

    func purgeBTSPlaybackFiles() {
        try? FileManager.default.removeItem(at: Self.playbackDirectory)
    }
}
