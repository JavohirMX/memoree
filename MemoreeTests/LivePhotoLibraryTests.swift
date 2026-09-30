import CoreGraphics
import Foundation
import ImageIO
import Photos
import Testing
import UniformTypeIdentifiers

@testable import Memoree

/// Phase 3 exit criterion — a real write to the user's actual photo library.
///
/// **Runs when the host can actually do it, and reports loudly when it cannot.**
///
/// ## Why these are skipped by default
///
/// The iOS simulator's Photos library service does not work. Verified directly,
/// with raw PhotoKit and no Memoree code in the path:
///
/// - `PHPhotoLibrary.authorizationStatus(for: .addOnly)` returns `.authorized`
///   once `simctl privacy grant photos-add` has been applied — note the service
///   is `photos-add`, not `photos`; `.addOnly` and `.readWrite` read different
///   TCC entries.
/// - `performChanges` then completes with `success = true` and `error = nil`,
///   and `placeholderForCreatedAsset` returns a well-formed identifier.
/// - No asset is ever created. Polling for ten seconds shows zero assets and
///   zero `PHPhotoLibraryChangeObserver` callbacks, and the simulator's
///   `Library/Photos/Photos.sqlite` does not exist. `photolibraryd` is not
///   running in the runtime.
///
/// So the API contract is satisfied and the operation is silently discarded.
/// Any test asserting on this in the simulator would pass or fail depending on
/// timing alone, which is worse than not running.
///
/// These tests therefore require a physical device. On hardware, grant the
/// Photos prompt once when it appears, then:
///
/// ```sh
/// export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
/// xcodebuild test -project Memoree.xcodeproj -scheme Memoree \
///   -destination 'platform=iOS,name=<your device>' \
///   -only-testing:MemoreeTests/LivePhotoLibraryTests
/// ```
///
/// ## Why a skip must not look like a pass
///
/// Swift Testing reports a test that returns early as **passed**. That is how
/// these four tests came to "pass" in one millisecond while asserting nothing —
/// a green run that verified nothing is the worst possible outcome, so each skip
/// prints an unmistakable line and the count is stated here rather than implied.
///
/// ## Fixtures are never deleted
///
/// These tests write visible photos into the camera roll and leave them there.
/// Memoree holds add-only authorisation, and its rule that it never removes
/// anything from the user's library (ADR-008) applies to its own test code too.
@Suite("Phase 3 — live Photos write", .serialized)
@MainActor
struct LivePhotoLibraryTests {

    private static let fixtureName = "Memoree Phase 3 Fixture"

    /// How many live tests actually executed, as opposed to skipped.
    ///
    /// Read by `LivePhotoRunGuardTests` so a skipped suite cannot pass unnoticed.

    /// Executed-test count for this run.
    ///
    /// `nonisolated` because `LivePhotoRunGuardTests` is not `@MainActor` and
    /// must read it. Plain rather than `nonisolated(unsafe)`: `RunCounter` is
    /// `Sendable` and has its own lock, so the compiler can prove this one is
    /// safe — and an unnecessary escape hatch is one more thing to keep an eye on.
    nonisolated private static let runCounter = RunCounter()

    /// Executed-test count for this run.
    nonisolated static var runCount: Int { runCounter.value }

    /// Lock-guarded so the counter is safe under parallel suite execution.
    private final class RunCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func increment() {
            lock.lock(); count += 1; lock.unlock()
        }
    }

    /// True only on a host whose Photos library actually persists writes.
    ///
    /// Checks the on-disk database rather than the authorisation status, because
    /// the simulator reports `.authorized` and then discards everything.
    private var canPersistPhotos: Bool {
        #if targetEnvironment(simulator)
        // Photos.sqlite is created by photolibraryd on first use. Its absence is
        // the reliable signal that this host cannot store a photo.
        let store = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Photos/Photos.sqlite")
        return FileManager.default.fileExists(atPath: store.path)
        #else
        return PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
            || PHPhotoLibrary.authorizationStatus(for: .addOnly) == .limited
        #endif
    }

    /// Prints an unmistakable skip notice and returns false.
    private func requirePhotoLibrary() -> Bool {
        guard canPersistPhotos else {
            print("""

            ╔══════════════════════════════════════════════════════════════╗
            ║  LIVE PHOTO TESTS SKIPPED — they asserted nothing.            ║
            ║  This host cannot persist to a Photos library.               ║
            ║  Requires a physical device; the simulator cannot do it.     ║
            ╚══════════════════════════════════════════════════════════════╝

            """)
            return false
        }
        Self.runCounter.increment()
        return true
    }

    /// A solid-colour JPEG carrying known EXIF.
    private func makeJPEG(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let size = 300
        let context = try #require(
            CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())

        let buffer = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: Self.fixtureName],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    @Test("Two fixture assets are written and both identifiers resolve")
    func writesTwoRealAssets() async throws {
        guard requirePhotoLibrary() else { return }

        let library = PhotoKitLibrary()
        let back = try makeJPEG(red: 0.9, green: 0.4, blue: 0.1)
        let front = try makeJPEG(red: 0.1, green: 0.4, blue: 0.9)
        let location = PhotoLocation(latitude: 48.8584, longitude: 2.2945)   // Paris

        let pair = try await library.saveMomentPair(
            backData: back, frontData: front, location: location)

        #expect(pair.back != pair.front)

        // The check that would catch a wrong `placeholderForCreatedAsset`
        // capture: the identifiers must resolve to real assets immediately.
        #expect(await library.assetExists(pair.back))
        #expect(await library.assetExists(pair.front))

        // Bytes come back with the coordinates intact.
        let readBack = try await library.data(for: pair.back)
        let recovered = try #require(PhotoMetadataInjector.readLocation(from: readBack))
        #expect(abs(recovered.latitude - 48.8584) < 0.0001)
        #expect(abs(recovered.longitude - 2.2945) < 0.0001)
        #expect(!readBack.isEmpty)
    }

    @Test("Written assets appear in a thumbnail request")
    func thumbnailResolves() async throws {
        guard requirePhotoLibrary() else { return }

        let library = PhotoKitLibrary()
        let back = try makeJPEG(red: 0.2, green: 0.8, blue: 0.3)

        let pair = try await library.saveMomentPair(
            backData: back, frontData: back, location: nil)

        // A cell-sized target: the exact path the archive grid uses, so this also
        // proves the continuation resumes rather than hanging.
        let thumbnail = await library.image(
            for: pair.back, targetSize: CGSize(width: 120, height: 160))

        #expect(thumbnail != nil, "thumbnail request did not produce an image")
        if let thumbnail {
            #expect(thumbnail.size.width > 0 && thumbnail.size.height > 0)
        }
    }

    @Test("The optional album is created and receives both assets")
    func albumReceivesAssets() async throws {
        guard requirePhotoLibrary() else { return }

        let library = PhotoKitLibrary()
        let image = try makeJPEG(red: 0.5, green: 0.5, blue: 0.8)

        let pair = try await library.saveMomentPair(
            backData: image, frontData: image, location: nil)

        let albumID = try await library.addAssets(
            [pair.back, pair.front], toAlbumNamed: Self.fixtureName)
        #expect(albumID != nil)

        let albums = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [try #require(albumID)], options: nil)
        #expect(albums.count == 1)

        // `PHAssetCollection` does not expose its assets; fetch them by collection.
        let collection = try #require(albums.firstObject)
        let members = PHAsset.fetchAssets(in: collection, options: nil)
        let identifiers = (0..<members.count).compactMap { members.object(at: $0).localIdentifier }
        #expect(identifiers.contains(pair.back))
        #expect(identifiers.contains(pair.front))
    }

    @Test("Asking for the album twice does not create a duplicate")
    func albumIsNotDuplicated() async throws {
        guard requirePhotoLibrary() else { return }

        let library = PhotoKitLibrary()
        let first = try await library.ensureAlbum(named: Self.fixtureName)
        let second = try await library.ensureAlbum(named: Self.fixtureName)
        #expect(first == second)
    }
}
