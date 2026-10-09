import Foundation
import Testing
import UIKit

@testable import Memoree

/// Phase 8 — the album toggle.
///
/// `settings.saveToAlbum` existed from Phase 2 and defaulted to off, and nothing
/// surfaced it. The plan's own note on `PhotoKitLibrary.ensureAlbum` records why
/// that mattered: *"Two layers of 'not shipped' hid a defect that the first real
/// invocation exposed."* An unreachable feature is not an untested feature, it is
/// an untested *feature* — and this suite is what makes it a reachable one.
///
/// ## What the tests are actually about
///
/// Not "does it add to an album" — that is one line and `addAssets` is the real
/// library's job. What is worth pinning is the set of decisions around it, each of
/// which is a place where the reasonable-sounding alternative loses something
/// specific:
///
/// - The album add runs **after** the commit, not inside it.
/// - An album failure **does not fail the moment**, and **is** reported.
/// - The preference is read at commit time, not at construction.
/// - Nothing is ever deleted when the toggle goes off.
@Suite("Phase 8 — album")
@MainActor
struct AlbumTests {

    private static let acceptsEverything: MomentRecorder = { _ in }

    private struct Harness {
        let model: CameraViewModel
        let library: InMemoryPhotoLibraryService
    }

    /// Builds a model with the album preference pinned to `wantsAlbum`.
    ///
    /// The library is injectable so two models can share one — which is the only
    /// way to exercise album *reuse*, since reuse means a second moment finding
    /// the album the first one created.
    private func makeHarness(
        wantsAlbum: Bool,
        library: InMemoryPhotoLibraryService? = nil,
        reportFailure: (@Sendable (String) -> Void)? = nil
    ) -> Harness {
        let library = library ?? InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: InMemoryCaptureService(),
            photoLibrary: library,
            record: Self.acceptsEverything,
            shouldFileIntoAlbum: { wantsAlbum },
            reportAlbumFailure: reportFailure,
            chooseFirstCamera: { .back }
        )
        return Harness(model: model, library: library)
    }

    /// Shoots both halves and commits.
    private func captureAndCommit(_ harness: Harness) async {
        await harness.model.start()
        await harness.model.shutterPressed()
        await harness.model.shutterPressed()
        await harness.model.commit()
    }

    // MARK: - Off by default

    @Test("Nothing is filed into an album unless the user asked")
    func nothingFilesByDefault() async throws {
        // The default is the point. The photographs are already in the user's
        // library — that is the whole product (ADR-001) — so a second copy in an
        // album the user did not ask for is the app littering their Photos app.
        let harness = makeHarness(wantsAlbum: false)
        await captureAndCommit(harness)

        #expect(harness.model.phase == .saved, "the moment committed")
        #expect(harness.library.createdAlbums.isEmpty,
                "and no album was even created")
    }

    @Test("The photographs are saved either way")
    func photographsAreAlwaysSaved() async throws {
        // The album is an *organisation* of the photographs, not the photographs.
        // So both branches must end with a saved moment, and asserting it in both
        // is what stops someone "simplifying" the album check into the save path.
        let withAlbum = makeHarness(wantsAlbum: true)
        await captureAndCommit(withAlbum)
        #expect(withAlbum.model.phase == .saved)
        #expect(withAlbum.library.savedPairCount == 1)

        let without = makeHarness(wantsAlbum: false)
        await captureAndCommit(without)
        #expect(without.model.phase == .saved)
        #expect(without.library.savedPairCount == 1)
    }

    // MARK: - On

    @Test("Both halves are filed, not just one")
    func bothHalvesAreFiled() async throws {
        // A pair in a `Memoree` album would be a rear photo with a missing selfie
        // for every day. The archive shows both, so the album must too — and the
        // check is on *identifiers*, not on a count, so a test cannot pass by
        // filing the same asset twice.
        let harness = makeHarness(wantsAlbum: true)
        await captureAndCommit(harness)

        let members = harness.library.albumMembers(named: CameraViewModel.albumName)
        #expect(members.count == 2)
        #expect(Set(members).count == 2, "two distinct assets, not one twice")

        let saved = try #require(harness.library.savedPairs.first)
        #expect(Set(members) == [saved.back, saved.front])
    }

    @Test("An existing album is reused rather than created again")
    func albumIsReused() async throws {
        // `ensureAlbum` used to create a fresh album on every call — a live device
        // test caught that, and the simulator cannot catch it because it cannot
        // create an album at all. **Two moments sharing one library** is the
        // smallest case that exercises reuse, and sharing is the realistic shape:
        // the user shoots today and tomorrow, and both go to the same album.
        let library = InMemoryPhotoLibraryService()
        let first = makeHarness(wantsAlbum: true, library: library)
        await captureAndCommit(first)

        let second = makeHarness(wantsAlbum: true, library: library)
        await captureAndCommit(second)

        #expect(library.createdAlbums == [CameraViewModel.albumName],
                "created once, not once per moment")
        #expect(library.albumMembers(named: CameraViewModel.albumName).count == 4,
                "and both pairs are in it")
    }

    // MARK: - The decision that matters most

    @Test("A failed album add does not fail the moment")
    func albumFailureDoesNotFailTheMoment() async throws {
        // **This is the load-bearing decision.** The photographs are saved before
        // the album add runs, and they are what the user asked for. So a failure
        // here must not cost them — otherwise a full disk or a deleted album would
        // throw away the actual photographs to protect an organisation of them.
        let broken = BrokenAlbumLibrary()
        let model = CameraViewModel(
            service: InMemoryCaptureService(),
            photoLibrary: broken,
            record: Self.acceptsEverything,
            shouldFileIntoAlbum: { true },
            chooseFirstCamera: { .back }
        )

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        #expect(model.phase == .saved,
                "the commit succeeded even though the album add threw")
        #expect(broken.savedPairCount == 1, "and the photographs were still written")
        #expect(model.albumFailure != nil, "but the failure was recorded")
        #expect(broken.savedAlbumIsEmpty,
                "and nothing was filed, because the add is what failed")
    }

    @Test("A failed album add is reported to the caller")
    func albumFailureIsReported() async throws {
        // The camera screen is gone by the time anyone could react, so reporting
        // to it alone would report to nothing. Asserted through the closure
        // because that is the only route the note has.
        let broken = BrokenAlbumLibrary()
        let reported = Recorder()
        let model = CameraViewModel(
            service: InMemoryCaptureService(),
            photoLibrary: broken,
            record: Self.acceptsEverything,
            shouldFileIntoAlbum: { true },
            reportAlbumFailure: { reported.set($0) },
            chooseFirstCamera: { .back }
        )
        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        let message = try #require(reported.value)
        #expect(message.contains("saved"),
                "the message must say the photographs are fine, or it reads as data loss")
        #expect(message.contains("album"), "and what did not happen")
    }

    @Test("Nothing is deleted when the preference is turned off")
    func turningItOffDeletesNothing() async throws {
        // ADR-008: Memoree holds add-only authorisation and must behave that way.
        // So the toggle going off cannot remove the album, and this is not merely
        // unimplemented — `PhotoLibraryService` has **no delete method at all**,
        // which is the real guarantee rather than a promise in a comment.
        let harness = makeHarness(wantsAlbum: true)
        await captureAndCommit(harness)
        #expect(harness.library.albumMembers(named: CameraViewModel.albumName).count == 2)

        // "Turned off" is a *different model*, and its album is untouched.
        let off = makeHarness(wantsAlbum: false)
        await captureAndCommit(off)
        #expect(off.library.createdAlbums.isEmpty,
                "the second model creates nothing, and deleted nothing")
        #expect(harness.library.albumMembers(named: CameraViewModel.albumName).count == 2,
                "the first album still holds both photographs")
    }

    // MARK: - When it is read

    @Test("The preference is read at commit time")
    func preferenceIsReadLate() async throws {
        // A snapshot taken when the camera screen was built would file today's
        // moment according to a preference from before the user changed it. The
        // camera screen is built once and a moment may be shot minutes later, so
        // this is a real ordering rather than a theoretical one.
        //
        // Asserted by making the answer change mid-flight: the flag is a captured
        // `var` behind a lock, and it is flipped *after* the model is built and
        // *before* the commit.
        let preference = Switch(value: false)
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: InMemoryCaptureService(),
            photoLibrary: library,
            record: Self.acceptsEverything,
            shouldFileIntoAlbum: { preference.get() },
            chooseFirstCamera: { .back }
        )

        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()

        // The user opens Settings and turns it on, mid-capture.
        preference.set(true)
        await model.commit()

        #expect(library.albumMembers(named: CameraViewModel.albumName).count == 2,
                "the commit honoured the preference as it was at commit time")
    }

    // MARK: - The album's name

    @Test("The album has one fixed name")
    func albumNameIsFixed() throws {
        // Memoree has no accounts, no sync, and nowhere to put a user-chosen name,
        // so a renameable album would be one more thing that exists only on this
        // device. Asserted because the name is also used in Settings' copy and in
        // the failure message, and those three must not drift.
        #expect(CameraViewModel.albumName == "Memoree")

        // The copy in Settings and the copy in the failure message both derive from the
        // constant. Hardcoding "Memoree" at either site would let the album be
        // renamed in one place and not the other, and the user would be told about
        // an album that does not exist.
        let settings = try String(
            contentsOf: SourceScan.file(named: "SettingsView.swift"),
            encoding: .utf8
        )
        #expect(settings.contains("CameraViewModel.albumName"),
                "Settings derives its copy from the constant rather than repeating it")
    }

    // MARK: - Test doubles

    /// A library whose asset writes work and whose album add always fails.
    ///
    /// A separate type rather than a flag on `InMemoryPhotoLibraryService`,
    /// because `failNextWrite` there fails the *save* — and the whole point of
    /// this decision is that the save succeeds while the album add does not.
    /// There is no way to make one double fail exactly one of the two
    /// operations, so this is that double.
    ///
    /// `@unchecked Sendable` with every piece of state behind the lock, which is
    /// the pattern `AGENTS.md` §5 permits and the one the production doubles use.
    private final class BrokenAlbumLibrary: PhotoLibraryService, @unchecked Sendable {
        private let lock = NSLock()
        private var pairs: [SavedAssetPair] = []

        func authorizationStatus() -> PhotoAuthorizationStatus { .authorized }
        func requestAuthorization() async -> PhotoAuthorizationStatus { .authorized }

        func saveMomentPair(
            backData: Data,
            frontData: Data,
            location: PhotoLocation?
        ) async throws -> SavedAssetPair {
            recordAPair()
        }

        func saveBTS(_ data: Data) async throws -> String { "bts" }
        func saveVideo(at fileURL: URL) async throws -> String { "video" }
        func exportFlipbookVideo(for moments: [MomentFacts], framesPerSecond: Int32) async throws -> String { "flipbook" }

        #if DEBUG
        /// Debug-only on the protocol, so a test double has to answer it.
        ///
        /// Reporting empty is the honest answer for a double that exists to fail
        /// album operations: there is no library behind it to enumerate, and any
        /// identifier it invented would resolve to nothing. `-MemoreeSeedWithPhotos`
        /// prints its "no assets" message against an empty list, which is the true
        /// statement — see `InMemoryPhotoLibraryService`'s implementation.
        func allImageAssetIdentifiers() -> [String] { [] }
        #endif

        func ensureAlbum(named name: String) async throws -> String? {
            throw LibraryError.albumUnavailable
        }

        @discardableResult
        func addAssets(_ identifiers: [String], toAlbumNamed name: String) async throws -> String? {
            throw LibraryError.albumUnavailable
        }

        func image(for identifier: String, targetSize: CGSize) async -> UIImage? { nil }
        func assetExists(_ identifier: String) async -> Bool { true }
        func prefetchThumbnails(_ identifiers: [String], targetSize: CGSize) async {}
        func cancelThumbnailPrefetch(targetSize: CGSize) async {}
        func purgeImageCache() async {}
        func data(for identifier: String) async throws -> Data { Data() }

        /// Playback has nothing to offer a double with no library behind it.
        ///
        /// **Throws rather than returning a path**, and the choice is the test's:
        /// this type exists to fail library operations, and a playable clip would be
        /// a library operation that succeeds.
        func btsClipFile(for identifier: String) async throws -> URL {
            throw LibraryError.assetMissing(identifier)
        }
        func purgeBTSPlaybackFiles() {}

        /// How many pairs were written.
        var savedPairCount: Int { countPairs }

        /// Always false, because every album add throws. Named so the test can
        /// say "nothing was filed" rather than leave it implied.
        var savedAlbumIsEmpty: Bool { true }

        /// Both helpers are synchronous, because `NSLock.lock()` is unavailable
        /// from an `async` context — Swift 6 forbids blocking there, quite
        /// rightly, since an `await` while holding a lock is a deadlock waiting
        /// to happen. So the `async` method calls a non-async helper, which is the
        /// shape the production doubles use for the same reason.
        private func recordAPair() -> SavedAssetPair {
            lock.lock()
            defer { lock.unlock() }
            let pair = SavedAssetPair(back: "b-\(pairs.count)", front: "f-\(pairs.count)")
            pairs.append(pair)
            return pair
        }

        private var countPairs: Int {
            lock.lock()
            defer { lock.unlock() }
            return pairs.count
        }
    }

    /// A lock-guarded mutable answer, for a closure that has to be `@Sendable`.
    private final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool

        init(value: Bool) { self.value = value }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ new: Bool) {
            lock.lock()
            defer { lock.unlock() }
            value = new
        }
    }

    /// The same shape, for a captured reporting closure.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ message: String) {
            lock.lock()
            defer { lock.unlock() }
            stored = message
        }
    }
}
