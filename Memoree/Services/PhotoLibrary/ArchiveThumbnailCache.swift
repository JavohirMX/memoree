import Foundation
import Photos
import UIKit

/// A thumbnail cache keyed by `PHAsset.localIdentifier`.
///
/// Lives in `Services`, not `Features`, and that placement is the layering rule
/// rather than a preference: it speaks `PHCachingImageManager` and
/// `PHImageRequestOptions`, and `Features/` may not import PhotoKit (AGENTS.md §3).
/// `PhotoKitLibrary` is the only thing that constructs one.
///
/// **This exists because the naive version had no cache at all.**
/// `PhotoKitLibrary.image(for:targetSize:)` constructed a fresh
/// `PHCachingImageManager` on every single call, which is invisible behind the
/// one composite on the Today screen and catastrophic behind a grid: scrolling
/// 500 cells re-requests 500 images, and `PHCachingImageManager` only caches
/// against the instance that made the request, so a per-call manager caches
/// nothing at all. The manager belongs to the service, and it is the manager
/// that holds the cache.
///
/// Two tiers, deliberately:
///
/// - **`NSCache` of decoded `UIImage`s.** A `UIImage` at cell size is tens of
///   kilobytes, so a few hundred of them is a couple of megabytes. It is
///   `NSCache` rather than a dictionary because the system is entitled to evict
///   under pressure, and a grid that grows without bound on a device that is
///   already tight on memory is a crash rather than a slow scroll.
/// - **`startCachingImages` for the rows on screen.** The decoded-image cache
///   only helps the *second* time a cell is drawn. Photos' own cache is what
///   makes the *first* draw cheap, and it only warms if it is told which assets
///   are about to be needed. `prefetch` is therefore not an optimisation —
///   without it a fast scroll shows empty cells that fill in late, which reads
///   as a broken screen rather than a slow one.
///
/// **Not thread-confined.** `NSCache` is thread-safe, and PhotoKit requests must
/// be able to start from the main actor and complete on PhotoKit's own queue.
/// The only mutable state is the cache itself, so `@unchecked Sendable` is the
/// honest annotation and it is confined to this one file.
final class ArchiveThumbnailCache: @unchecked Sendable {

    /// All mutable state is the two fields below, both of which are themselves
    /// thread-safe: `NSCache` by contract, and the request map only ever
    /// written from `prefetch` on the main actor and read from `stopPrefetching`
    /// on the main actor. No other type in the app needs `@unchecked Sendable`
    /// for this, and confining it here is what keeps that true.
    private let cache = NSCache<NSString, UIImage>()

    /// Which assets are currently being warmed, so `stopPrefetching` can stop
    /// exactly those and no others.
    private var prefetched: [PHAsset] = []

    /// Rough memory ceiling for the decoded tier.
    ///
    /// A guess, and an honest one: cell-sized 3:4 images run 20–60 KB, so this
    /// holds several hundred — comfortably more than a screen of cells plus a
    /// screen of prefetch. iOS does not expose a way to ask what a decode
    /// actually cost, so a number that is too low is better than one that is
    /// too high.
    private let costLimitBytes = 24 * 1024 * 1024

    init() {
        cache.countLimit = 600
        cache.totalCostLimit = costLimitBytes
    }

    // MARK: - Decoded images

    /// A cached image for this exact key, if there is one.
    func cached(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        // Cost by pixel area rather than by the encoded byte count: what
        // `PHImageManager` hands back is already decoded, and what costs memory
        // is the pixel buffer.
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        cache.setObject(image, forKey: key as NSString, cost: pixels)
    }

    /// Drops everything.
    ///
    /// Called when the archive is dismissed. A grid's worth of decoded images is
    /// a few megabytes that the camera will want next, and the camera is the
    /// screen that cannot afford to be slow.
    func removeAll() {
        cache.removeAllObjects()
    }

    // MARK: - Photos-tier warming

    /// Warms PhotoKit's own cache for a set of identifiers.
    ///
    /// Best-effort by construction: a request that cannot be started is not an
    /// error, because the cell will simply request the image itself when it
    /// draws. That is the difference between this being an optimisation and a
    /// dependency.
    @MainActor
    func prefetch(
        identifiers: [String],
        targetSize: CGSize,
        manager: PHCachingImageManager,
        options: PHImageRequestOptions
    ) {
        let assets = identifiers.compactMap { identifier in
            PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        }
        guard !assets.isEmpty else { return }

        manager.startCachingImages(
            for: assets,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
        prefetched = assets
    }

    /// Stops warming exactly what `prefetch` started.
    ///
    /// Matching by asset rather than clearing everything is deliberate: the
    /// detail view asks for a large image through the same manager, and
    /// `stopCachingImages` for *all* cached assets would evict that too, so
    /// paging into a moment and back would re-download what it just had.
    @MainActor
    func stopPrefetching(
        targetSize: CGSize,
        manager: PHCachingImageManager,
        options: PHImageRequestOptions
    ) {
        guard !prefetched.isEmpty else { return }
        manager.stopCachingImages(
            for: prefetched,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        )
        prefetched = []
    }
}
