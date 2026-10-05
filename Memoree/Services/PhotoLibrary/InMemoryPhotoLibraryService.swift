import CoreGraphics
import Foundation
import UIKit

/// An in-memory `PhotoLibraryService` for tests and previews.
///
/// Every UI test uses this, so no test ever needs a real photo library or a
/// populated simulator album (AGENTS.md §3). It records what was asked of it,
/// which lets tests assert the *calls* — that a moment was written as a pair,
/// that GPS was passed only on opt-in — rather than merely that nothing crashed.
///
/// Thread-safe: tests run suites in parallel.
final class InMemoryPhotoLibraryService: PhotoLibraryService, @unchecked Sendable {

    private struct State {
        var authorization: PhotoAuthorizationStatus = .notDetermined
        var pairs: [SavedAssetPair] = []
        var locations: [PhotoLocation?] = []
        var backData: [Data] = []
        var frontData: [Data] = []
        var btsData: [Data] = []
        var albumMembers: [String: [String]] = [:]
        var albumCreations: [String] = []
        var albumCreationAttempted = false
        var storedBytes: [String: Data] = [:]
        var missingIdentifiers: Set<String> = []
        var failureToThrow: LibraryError?
        // The archive's cache traffic, recorded so a test can assert that
        // prefetching happened rather than only that scrolling did not crash.
        var prefetchedBatches: [[String]] = []
        var cancelledPrefetches: [CGSize] = []
        var purgeCount = 0
        var playbackPurgeCount = 0
    }

    private let lock = NSLock()
    private var state = State()
    private var counter = 0

    // MARK: - Test configuration

    /// Set to make the next write throw, for testing error paths.
    func failNextWrite(with error: LibraryError) {
        lock.withLock { state.failureToThrow = error }
    }

    /// Marks an identifier as absent, simulating a user deleting from Photos.
    func markMissing(_ identifiers: String...) {
        lock.withLock { state.missingIdentifiers.formUnion(identifiers) }
    }

    func setAuthorization(_ status: PhotoAuthorizationStatus) {
        lock.withLock { state.authorization = status }
    }

    // MARK: - Inspection

    var savedPairCount: Int { lock.withLock { state.pairs.count } }
    var savedLocations: [PhotoLocation?] { lock.withLock { state.locations } }
    var savedBackData: [Data] { lock.withLock { state.backData } }
    var savedFrontData: [Data] { lock.withLock { state.frontData } }
    var savedBTSCount: Int { lock.withLock { state.btsData.count } }
    /// Identifiers the BTS writes were filed under, in order.
    ///
    /// **The identifiers, not just the count**, because a test that asserts "one
    /// clip was written" cannot then read the identifier back — and the identifier
    /// is the only thing a playback test has to work from.
    var savedBTSIdentifiers: [String] { lock.withLock { state.storedBytes.keys
        .filter { $0.hasPrefix("bts-") }
        .sorted { lhs, rhs in
            (Int(lhs.dropFirst(4)) ?? 0) < (Int(rhs.dropFirst(4)) ?? 0)
        }
    } }
    var createdAlbums: [String] { lock.withLock { state.albumCreations } }
    var didAttemptAlbumCreation: Bool { lock.withLock { state.albumCreationAttempted } }
    func albumMembers(named name: String) -> [String] { lock.withLock { state.albumMembers[name] ?? [] } }
    /// Every pair written, in order. A count is not enough to assert *which*
    /// assets were filed into an album.
    var savedPairs: [SavedAssetPair] { lock.withLock { state.pairs } }
    var latestPair: SavedAssetPair? { lock.withLock { state.pairs.last } }
    var latestLocation: PhotoLocation?? { lock.withLock { state.locations.last } }

    /// Every batch handed to `prefetchThumbnails`, oldest first.
    var prefetchedBatches: [[String]] { lock.withLock { state.prefetchedBatches } }
    var cancelledPrefetchSizes: [CGSize] { lock.withLock { state.cancelledPrefetches } }
    var imageCachePurgeCount: Int { lock.withLock { state.purgeCount } }
    /// How many times playable BTS copies were swept. See `purgeBTSPlaybackFiles`.
    var btsPlaybackPurgeCount: Int { lock.withLock { state.playbackPurgeCount } }

    // MARK: - PhotoLibraryService

    func authorizationStatus() -> PhotoAuthorizationStatus {
        lock.withLock { state.authorization }
    }

    func requestAuthorization() async -> PhotoAuthorizationStatus {
        lock.withLock { state.authorization = .authorized }
        return .authorized
    }

    func saveMomentPair(
        backData: Data,
        frontData: Data,
        location: PhotoLocation?
    ) async throws -> SavedAssetPair {
        try lock.withLock {
            if let failure = state.failureToThrow {
                state.failureToThrow = nil
                throw failure
            }
            guard state.authorization == .authorized else {
                throw LibraryError.authorizationDenied
            }

            counter += 1
            let pair = SavedAssetPair(back: "back-\(counter)", front: "front-\(counter)")

            state.pairs.append(pair)
            state.locations.append(location)
            state.backData.append(backData)
            state.frontData.append(frontData)
            state.storedBytes[pair.back] = backData
            state.storedBytes[pair.front] = frontData

            return pair
        }
    }

    func saveBTS(_ data: Data) async throws -> String {
        try lock.withLock {
            guard state.authorization == .authorized else {
                throw LibraryError.authorizationDenied
            }
            counter += 1
            let identifier = "bts-\(counter)"
            state.btsData.append(data)
            state.storedBytes[identifier] = data
            return identifier
        }
    }

    /// Writes a real, empty file at a real path.
    ///
    /// **A file, and not a fabricated URL, because the consumer opens it.** A
    /// double returning a path that does not exist makes `AVPlayer` fail in a way
    /// the view model would then have to distinguish from "you deleted the clip" —
    /// which is the same lesson `InMemoryBTSRecorder.trim` learned the hard way,
    /// in the other direction.
    ///
    /// The bytes are deliberately not the clip's own. Nothing in the view model
    /// reads them; only a player does, and a player is never under test.
    func btsClipFile(for identifier: String) async throws -> URL {
        try lock.withLock {
            guard let bytes = state.storedBytes[identifier] else {
                throw LibraryError.assetMissing(identifier)
            }
            counter += 1
            let url = Self.playbackDirectory
                .appendingPathComponent("playback-\(counter).mov")
            try FileManager.default.createDirectory(
                at: Self.playbackDirectory, withIntermediateDirectories: true
            )
            try Data("playback-\(bytes.count)".utf8).write(to: url)
            return url
        }
    }

    private static let playbackDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("memoree-bts-playback-tests", isDirectory: true)

    /// Deletes what `btsClipFile` wrote, so a suite run leaves nothing behind.
    static func clearPlaybackTestFiles() {
        try? FileManager.default.removeItem(at: playbackDirectory)
    }

    func purgeBTSPlaybackFiles() {
        lock.withLock { state.playbackPurgeCount += 1 }
        Self.clearPlaybackTestFiles()
    }

    /// Decodes what it was given, so the read path returns real pixels.
    ///
    /// This used to return `nil` unconditionally with a comment saying tests
    /// assert the *call* rather than the result. That was true while nothing
    /// consumed the result — but the Today screen's composite is the first thing
    /// that does, and a double that always answers `nil` would have made every
    /// one of its states unreachable in a test. A double that cannot exercise
    /// the code it stands in for is a double that hides bugs.
    ///
    /// Returns `nil` for anything not written through `saveMomentPair`, and for
    /// identifiers the user is modelled as having deleted — which is how the
    /// "missing from Photos" path gets tested at all.
    func image(for identifier: String, targetSize: CGSize) async -> UIImage? {
        lock.withLock {
            guard !state.missingIdentifiers.contains(identifier),
                  let data = state.storedBytes[identifier],
                  let image = UIImage(data: data)
            else { return nil }
            return image
        }
    }

    func assetExists(_ identifier: String) async -> Bool {
        lock.withLock {
            !state.missingIdentifiers.contains(identifier) && (
                state.storedBytes[identifier] != nil
                    || identifier.hasPrefix("back-")
                    || identifier.hasPrefix("front-")
                    || identifier.hasPrefix("bts-")
            )
        }
    }

    #if DEBUG
    /// Reports nothing, because a double has no library to enumerate.
    ///
    /// The layout audit attaches *real* assets to seeded rows, so there is no
    /// honest stand-in here: any identifier this invented would resolve to
    /// `image(for:)` returning a mock rectangle, which is the empty-cell case the
    /// audit exists to avoid. Returning empty makes `-MemoreeSeedWithPhotos` print
    /// its "no assets" message, which is the true statement about a double.
    func allImageAssetIdentifiers() -> [String] { [] }
    #endif

    // The prefetch half of the read path. Recorded rather than simulated:
    // there is nothing to warm, and what a test wants to know is *whether* the
    // grid asked, and for which identifiers.
    func prefetchThumbnails(_ identifiers: [String], targetSize: CGSize) async {
        lock.withLock { state.prefetchedBatches.append(identifiers) }
    }

    func cancelThumbnailPrefetch(targetSize: CGSize) async {
        lock.withLock { state.cancelledPrefetches.append(targetSize) }
    }

    func purgeImageCache() async {
        lock.withLock { state.purgeCount += 1 }
    }

    func data(for identifier: String) async throws -> Data {
        try lock.withLock {
            guard !state.missingIdentifiers.contains(identifier),
                  let data = state.storedBytes[identifier]
            else { throw LibraryError.assetMissing(identifier) }
            return data
        }
    }

    func ensureAlbum(named name: String) async throws -> String? {
        lock.withLock { ensureAlbumSynchronously(named: name) }
    }

    /// Test-only: record album membership without a real PhotoKit collection.
    func record(assets identifiers: [String], intoAlbumNamed name: String) {
        lock.withLock { state.albumMembers[name, default: []].append(contentsOf: identifiers) }
    }

    @discardableResult
    func addAssets(_ identifiers: [String], toAlbumNamed name: String) async throws -> String? {
        guard !identifiers.isEmpty else { return nil }

        return try lock.withLock {
            // Mirrors the real library's one check that matters: every identifier
            // has to resolve to an asset that exists. Adding a phantom would
            // silently produce an album with a hole in it.
            let known = Set(state.pairs.flatMap { [$0.back, $0.front] }).union(state.storedBytes.keys)
            let missing = identifiers.filter { !known.contains($0) }
            guard missing.isEmpty else {
                throw LibraryError.assetMissing("one or more assets did not resolve")
            }

            let identifier = ensureAlbumSynchronously(named: name)
            state.albumMembers[name, default: []].append(contentsOf: identifiers)
            return identifier
        }
    }

    /// `ensureAlbum` without re-entering the lock.
    ///
    /// `NSLock` is not recursive, so the public `ensureAlbum(named:)` cannot be
    /// called from inside `addAssets`'s `withLock`. Duplicating four lines beats
    /// restructuring the whole type around a recursive lock, and the duplication
    /// is the *identical* logic so the two cannot disagree about what "ensure"
    /// means.
    private func ensureAlbumSynchronously(named name: String) -> String {
        state.albumCreationAttempted = true
        if !state.albumCreations.contains(name) {
            state.albumCreations.append(name)
            state.albumMembers[name] = []
        }
        return "album-\(name)"
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
