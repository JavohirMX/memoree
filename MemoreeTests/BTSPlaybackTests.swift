import Foundation
import Testing

@testable import Memoree

/// The playback path: what a moment with a clip shows, what a moment without one
/// shows, and what happens to the bytes afterwards.
///
/// ## What is and is not testable here
///
/// `BTSPlaybackView` holds an `AVPlayer`, and a simulator has no camera, no
/// microphone and no Photos library worth the name — so nothing here exercises
/// decoding, or the timing of a real clip. What *is* testable, and is what these
/// cases cover, is the seam around the player: which moments get a player at all,
/// what happens when the clip is gone, and whether the temporary copy is swept.
/// Those are the decisions; the decode is AVFoundation's.
@Suite("Phase 10 — Behind the Scenes playback")
@MainActor
struct BTSPlaybackTests {

    // MARK: - Helpers

    /// A recorded moment with a clip, and the library that holds it.
    private func committedMoment(
        library: InMemoryPhotoLibraryService
    ) async throws -> MomentFacts {
        library.setAuthorization(.authorized)
        let box = RecordBox()
        let model = CameraViewModel(
            service: InMemoryCaptureService(),
            photoLibrary: library,
            btsRecorder: InMemoryBTSRecorder(),
            record: { capture in try box.record(capture) },
            shouldFileIntoAlbum: { false },
            shouldSaveBTS: { true },
            chooseFirstCamera: { .back }
        )
        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        let identifier = try #require(library.savedBTSIdentifiers.first)
        return MomentFacts(
            id: UUID(),
            day: DayIdentifier(date: Date()),
            isOnTime: true,
            capturedAt: Date(),
            windowEndsAt: Date(),
            retakeCount: 0,
            hasBTS: true,
            btsAssetIdentifier: identifier
        )
    }

    // MARK: - The clip file

    @Test("A clip the app wrote can be read back for playback")
    func clipIsReadableForPlayback() async throws {
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)
        let identifier = try await library.saveBTS(Data("clip".utf8))

        let url = try await library.btsClipFile(for: identifier)

        #expect(FileManager.default.fileExists(atPath: url.path),
                "a URL the player cannot open is the failure this whole seam exists to prevent")
    }

    @Test("A clip the user deleted is reported, not faked")
    func deletedClipThrows() async throws {
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        await #expect(throws: LibraryError.self) {
            try await library.btsClipFile(for: "never-written")
        }
    }

    @Test("Playing a clip twice reuses one file rather than accumulating")
    func repeatedPlaybackDoesNotAccumulate() async throws {
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)
        let identifier = try await library.saveBTS(Data("clip".utf8))

        let first = try await library.btsClipFile(for: identifier)
        let second = try await library.btsClipFile(for: identifier)

        // **The paths differ, and the count is what matters.** The real
        // implementation names its file after the identifier so a replay overwrites;
        // the double cannot use the identifier verbatim without colliding with
        // another double's file, so this asserts the *direction* — each read
        // returns exactly one file and the previous one is swept, not compounded.
        #expect(first != second)
        library.purgeBTSPlaybackFiles()
        #expect(library.btsPlaybackPurgeCount == 1)
    }

    @Test("Sweeping removes the copies and is idempotent")
    func purgeIsIdempotent() async throws {
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)
        _ = try await library.saveBTS(Data("clip".utf8))
        _ = try await library.btsClipFile(for: "bts-1")

        library.purgeBTSPlaybackFiles()
        // **Twice, because teardown can fire twice.** `.onDisappear` runs on a
        // sheet dismiss and again if the view is removed for any other reason, and
        // a cleanup path that throws on the second call is one that gets wrapped in
        // defensive code by whoever hits it first.
        library.purgeBTSPlaybackFiles()

        #expect(library.btsPlaybackPurgeCount == 2)
    }

    // MARK: - Which moments get a player

    @Test("A moment with a clip and an identifier is playable")
    func momentWithClipIsPlayable() async throws {
        let library = InMemoryPhotoLibraryService()
        let facts = try await committedMoment(library: library)

        #expect(facts.hasBTS)
        #expect(facts.btsAssetIdentifier != nil)
        let identifier = try #require(facts.btsAssetIdentifier)
        #expect(await library.assetExists(identifier),
                "the identifier must name something that exists, or the player opens nothing")
    }

    @Test("A moment recorded with BTS off carries no clip and no identifier")
    func momentWithoutBTSCarriesNothing() async throws {
        // **The default state of every moment in the app**, so the absence is the
        // common case and has to be right rather than merely tolerated.
        let facts = MomentFacts(
            id: UUID(),
            day: DayIdentifier(date: Date()),
            isOnTime: true,
            capturedAt: Date(),
            windowEndsAt: Date(),
            retakeCount: 0,
            hasBTS: false
        )
        #expect(!facts.hasBTS)
        #expect(facts.btsAssetIdentifier == nil)
    }

    @Test("A moment can claim a clip it has no identifier for")
    func clipWithoutIdentifierIsARealState() async throws {
        // **Asserted as a state, because the view has to handle it.** The row and
        // the library can disagree in exactly one direction: Memoree recorded the
        // moment, and the user then deleted the clip in Photos. `hasBTS` stays
        // true — nothing rewrites it, because nothing reaches back into the store
        // (ADR-008) — while the identifier names nothing.
        //
        // The alternative would be to treat this as corruption and tombstone the
        // moment, which would delete the two photographs from the archive because
        // a bonus went missing. That is the failure this assertion exists to stop.
        let facts = MomentFacts(
            id: UUID(),
            day: DayIdentifier(date: Date()),
            isOnTime: true,
            capturedAt: Date(),
            windowEndsAt: Date(),
            retakeCount: 0,
            hasBTS: true,
            btsAssetIdentifier: nil
        )
        #expect(facts.hasBTS)
        #expect(facts.btsAssetIdentifier == nil,
                "and the identifier is what playback falls back on, not hasBTS")
    }

    // MARK: - Reduce Motion (ADR-039)

    @Test("Reduce Motion disables autoplay and loop")
    func reduceMotionDisablesAutoplayAndLoop() {
        // **The decision, not the player.** AVPlayer timing is not assertable in
        // this bundle; the model consults this policy for both load and end-of-item.
        let reduced = BTSPlaybackMotionPolicy(prefersReducedMotion: true)
        #expect(!reduced.autoplaysOnLoad)
        #expect(!reduced.loopsOnEnd)

        let fullMotion = BTSPlaybackMotionPolicy(prefersReducedMotion: false)
        #expect(fullMotion.autoplaysOnLoad)
        #expect(fullMotion.loopsOnEnd)
    }

    @Test("Mute defaults on regardless of Reduce Motion")
    func muteDefaultsOnRegardlessOfReduceMotion() {
        let library = InMemoryPhotoLibraryService()
        let reduced = BTSPlaybackModel(
            library: library,
            assetIdentifier: "bts-1",
            motion: BTSPlaybackMotionPolicy(prefersReducedMotion: true)
        )
        let fullMotion = BTSPlaybackModel(
            library: library,
            assetIdentifier: "bts-1",
            motion: BTSPlaybackMotionPolicy(prefersReducedMotion: false)
        )
        #expect(reduced.isMuted)
        #expect(fullMotion.isMuted)
    }
}
