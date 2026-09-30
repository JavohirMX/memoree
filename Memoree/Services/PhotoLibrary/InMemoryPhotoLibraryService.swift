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
    var createdAlbums: [String] { lock.withLock { state.albumCreations } }
    var didAttemptAlbumCreation: Bool { lock.withLock { state.albumCreationAttempted } }
    func albumMembers(named name: String) -> [String] { lock.withLock { state.albumMembers[name] ?? [] } }
    var latestPair: SavedAssetPair? { lock.withLock { state.pairs.last } }
    var latestLocation: PhotoLocation?? { lock.withLock { state.locations.last } }

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

    func image(for identifier: String, targetSize: CGSize) async -> UIImage? {
        // No real pixels: tests assert that the call was made, not what it
        // returned. Returning nil is honest rather than fabricating an image.
        _ = targetSize
        return lock.withLock { state.missingIdentifiers.contains(identifier) ? nil : nil }
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

    func data(for identifier: String) async throws -> Data {
        try lock.withLock {
            guard !state.missingIdentifiers.contains(identifier),
                  let data = state.storedBytes[identifier]
            else { throw LibraryError.assetMissing(identifier) }
            return data
        }
    }

    func ensureAlbum(named name: String) async throws -> String? {
        lock.withLock {
            state.albumCreationAttempted = true
            if !state.albumCreations.contains(name) {
                state.albumCreations.append(name)
                state.albumMembers[name] = []
            }
            return "album-\(name)"
        }
    }

    /// Test-only: record album membership without a real PhotoKit collection.
    func record(assets identifiers: [String], intoAlbumNamed name: String) {
        lock.withLock { state.albumMembers[name, default: []].append(contentsOf: identifiers) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
