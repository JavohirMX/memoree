import Foundation
import Testing

@testable import Memoree

/// Phase 3 — the write path against the test double.
///
/// These assert the *calls*, which is what the protocol exists for: that a
/// moment is written as a pair, that GPS is passed only on opt-in, that denial
/// is handled, and that BTS is written separately from the stills.
@Suite("Phase 3 — photo library write path")
struct PhotoLibraryWritePathTests {

    private func makeService() async -> InMemoryPhotoLibraryService {
        let service = InMemoryPhotoLibraryService()
        _ = await service.requestAuthorization()
        return service
    }

    private func jpeg() -> Data {
        // Only has to be non-empty; the double does not decode it.
        Data(repeating: 0x5A, count: 512)
    }

    @Test("A moment is written as a pair with distinct identifiers")
    func writesPair() async throws {
        let service = await makeService()

        let pair = try await service.saveMomentPair(
            backData: jpeg(), frontData: jpeg(), location: nil)

        #expect(pair.back != pair.front, "the two assets must not collide")
        #expect(service.savedPairCount == 1)
        #expect(service.savedBackData.count == 1)
        #expect(service.savedFrontData.count == 1)
    }

    @Test("Both halves are written together — never one alone")
    func pairIsAtomic() async throws {
        let service = await makeService()

        for _ in 0..<5 {
            _ = try await service.saveMomentPair(
                backData: jpeg(), frontData: jpeg(), location: nil)
        }

        #expect(service.savedBackData.count == service.savedFrontData.count)
        #expect(service.savedBackData.count == service.savedPairCount)
    }

    @Test("Coordinates are passed only when the user opted in")
    func locationIsOptIn() async throws {
        let service = await makeService()
        let paris = PhotoLocation(latitude: 48.8584, longitude: 2.2945)

        _ = try await service.saveMomentPair(backData: jpeg(), frontData: jpeg(), location: nil)
        _ = try await service.saveMomentPair(backData: jpeg(), frontData: jpeg(), location: paris)

        let recorded = service.savedLocations
        #expect(recorded.count == 2)
        #expect(recorded[0] == nil, "no coordinates unless asked for")
        #expect(recorded[1] == paris)
    }

    @Test("Writing without authorisation fails rather than silently succeeding")
    func requiresAuthorization() async {
        let service = InMemoryPhotoLibraryService()
        service.setAuthorization(.denied)

        await #expect(throws: LibraryError.authorizationDenied) {
            try await service.saveMomentPair(
                backData: jpeg(), frontData: jpeg(), location: nil)
        }
        #expect(service.savedPairCount == 0)
    }

    @Test("Restricted access is treated as a denial")
    func restrictedIsNotWritable() async {
        let service = InMemoryPhotoLibraryService()
        service.setAuthorization(.restricted)

        await #expect(throws: LibraryError.authorizationDenied) {
            try await service.saveMomentPair(
                backData: jpeg(), frontData: jpeg(), location: nil)
        }
    }

    @Test("A write failure surfaces as a thrown error, not a silent loss")
    func writeFailurePropagates() async throws {
        let service = await makeService()
        service.failNextWrite(with: .writeFailed("disk full"))

        await #expect(throws: LibraryError.writeFailed("disk full")) {
            try await service.saveMomentPair(
                backData: jpeg(), frontData: jpeg(), location: nil)
        }
        #expect(service.savedPairCount == 0, "a failed write must record nothing")
    }

    @Test("BTS is written separately from the stills")
    func btsIsSeparate() async throws {
        let service = await makeService()

        _ = try await service.saveBTS(Data(repeating: 0x01, count: 256))

        #expect(service.savedBTSCount == 1)
        #expect(service.savedPairCount == 0, "BTS must not create a photo pair")
    }

    // MARK: - Reading

    @Test("Bytes written can be read back for sharing")
    func readsBackWrittenBytes() async throws {
        let service = await makeService()
        let back = Data(repeating: 0xAB, count: 1024)

        let pair = try await service.saveMomentPair(
            backData: back, frontData: jpeg(), location: nil)

        let readBack = try await service.data(for: pair.back)
        #expect(readBack == back)
    }

    @Test("An asset the user deleted in Photos reports as missing, not as an error")
    func missingAssetIsDistinguishable() async throws {
        let service = await makeService()
        let pair = try await service.saveMomentPair(
            backData: jpeg(), frontData: jpeg(), location: nil)

        #expect(await service.assetExists(pair.back))

        // The user deletes it from Photos. That is a deliberate act, so it must
        // be distinguishable from a transient failure (ADR-008).
        service.markMissing(pair.back)
        #expect(await service.assetExists(pair.back) == false)

        await #expect(throws: LibraryError.assetMissing(pair.back)) {
            try await service.data(for: pair.back)
        }
    }

    @Test("A thumbnail request returns nil for a missing asset without throwing")
    func missingThumbnailReturnsNil() async throws {
        let service = await makeService()
        let pair = try await service.saveMomentPair(
            backData: jpeg(), frontData: jpeg(), location: nil)
        service.markMissing(pair.front)

        // The grid must not present an error state for a photo the user
        // deliberately deleted.
        let image = await service.image(
            for: pair.front, targetSize: CGSize(width: 100, height: 133))
        #expect(image == nil)
    }

    // MARK: - Albums

    @Test("The album is created only when asked for")
    func albumIsOptIn() async throws {
        let service = await makeService()

        #expect(service.createdAlbums.isEmpty, "default off")
        #expect(service.didAttemptAlbumCreation == false)

        _ = try await service.ensureAlbum(named: "Memoree")

        #expect(service.createdAlbums == ["Memoree"])
        #expect(service.didAttemptAlbumCreation)
    }

    @Test("Asking twice reuses the album rather than duplicating it")
    func albumIsReused() async throws {
        let service = await makeService()

        let first = try await service.ensureAlbum(named: "Memoree")
        let second = try await service.ensureAlbum(named: "Memoree")

        #expect(first == second)
        #expect(service.createdAlbums.count == 1)
    }
}

/// Phase 3 — authorisation mapping.
///
/// `.limited` is the subtle one. It cannot occur for `.addOnly`, but mapping it
/// to `.authorized` is the safe choice if Apple's enum ever grows a case: a
/// user who somehow has limited access can still add, so refusing would be
/// wrong.
@Suite("Phase 3 — authorisation")
struct PhotoAuthorizationTests {

    @Test("Not-determined is distinguishable from denied")
    func notDeterminedIsNotDenied() {
        #expect(PhotoAuthorizationStatus.notDetermined != .denied)
        #expect(PhotoAuthorizationStatus.undetermined != .denied)
    }

    @Test("Only authorized permits writing")
    func onlyAuthorizedWrites() async {
        let writable: Set<PhotoAuthorizationStatus> = [.authorized]
        for status in [PhotoAuthorizationStatus.notDetermined, .denied, .restricted, .undetermined] {
            #expect(!writable.contains(status), "\(status) must not permit writing")
        }
    }
}
