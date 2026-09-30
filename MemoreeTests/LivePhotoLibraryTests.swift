import CoreGraphics
import Foundation
import ImageIO
import Photos
import Testing
import UniformTypeIdentifiers

@testable import Memoree

/// Phase 3 exit criterion — a real write to the user's actual photo library.
///
/// **Runs whenever add-only access has been granted, and skips otherwise.** There
/// is deliberately no environment-variable gate.
///
/// The first version of this file gated on `MEMOREE_LIVE_PHOTO_TESTS=1`, to
/// avoid `PHPhotoLibrary.requestAuthorization(for: .addOnly)` blocking forever
/// when TCC holds no decision and nobody can dismiss the dialog. That hazard was
/// real, but the fix was to stop *requesting* authorisation: reading
/// `authorizationStatus` is non-blocking and always returns. With the blocking
/// call gone, a gate only obscures things — and it turns out `xcodebuild` does
/// not propagate shell environment variables into the test process at all, so
/// the documented way to enable the suite silently did nothing and the tests
/// passed in a millisecond having verified nothing.
///
/// Grant access, then run:
///
///     xcrun simctl privacy booted grant photos com.javohirmx.memoree   # simulator
///     xcodebuild test -project Memoree.xcodeproj -scheme Memoree \
///       -destination 'platform=iOS,name=<your device>'
///
/// On a physical device, tap through the permission prompt once.
///
/// A skipped test reports as passed in Swift Testing, so check the run's
/// assertion count, not just its exit status.
///
/// These tests write visible fixtures and never delete them. Memoree has
/// add-only authorisation, and its rule that it never removes anything from the
/// user's library (ADR-008) applies to its own test code too.
@Suite("Phase 3 — live Photos write", .serialized)
@MainActor
struct LivePhotoLibraryTests {

    private static let fixtureName = "Memoree Phase 3 Fixture"

    /// Whether add-only access has already been granted.
    ///
    /// Reads status only. Never calls `requestAuthorization`, which would
    /// suspend until a human dismissed the dialog — impossible in a test host.
    private var hasAddOnlyAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return status == .authorized || status == .limited
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
        guard hasAddOnlyAccess else {
            // Skipped, not failed: add-only access has not been granted.
            return
        }

        let library = PhotoKitLibrary()
        let back = try makeJPEG(red: 0.9, green: 0.4, blue: 0.1)
        let front = try makeJPEG(red: 0.1, green: 0.4, blue: 0.9)
        let location = PhotoLocation(latitude: 48.8584, longitude: 2.2945)   // Paris

        let pair = try await library.saveMomentPair(
            backData: back, frontData: front, location: location)

        #expect(pair.back != pair.front)

        // Both identifiers must resolve to real assets immediately after the
        // write. This is the check that would catch a wrong
        // `placeholderForCreatedAsset` capture.
        #expect(await library.assetExists(pair.back))
        #expect(await library.assetExists(pair.front))

        // And the bytes must come back with the coordinates intact.
        let readBack = try await library.data(for: pair.back)
        let recovered = try #require(PhotoMetadataInjector.readLocation(from: readBack))
        #expect(abs(recovered.latitude - 48.8584) < 0.0001)
        #expect(abs(recovered.longitude - 2.2945) < 0.0001)

        // The original bytes must not have been recompressed into something
        // unreadable.
        #expect(readBack.count > 0)
    }

    @Test("Written assets appear in a thumbnail request")
    func thumbnailResolves() async throws {
        guard hasAddOnlyAccess else { return }

        let library = PhotoKitLibrary()
        let back = try makeJPEG(red: 0.2, green: 0.8, blue: 0.3)

        let pair = try await library.saveMomentPair(
            backData: back, frontData: back, location: nil)

        // A cell-sized target. This is the exact path the archive grid uses, so
        // it also proves the continuation resumes rather than hanging.
        let thumbnail = await library.image(
            for: pair.back, targetSize: CGSize(width: 120, height: 160))

        #expect(thumbnail != nil, "thumbnail request did not produce an image")
        if let thumbnail {
            #expect(thumbnail.size.width > 0 && thumbnail.size.height > 0)
        }
    }

    @Test("The optional album is created and receives both assets")
    func albumReceivesAssets() async throws {
        guard hasAddOnlyAccess else { return }

        let library = PhotoKitLibrary()
        let image = try makeJPEG(red: 0.5, green: 0.5, blue: 0.8)

        let pair = try await library.saveMomentPair(
            backData: image, frontData: image, location: nil)

        let albumID = try await library.addAssets(
            [pair.back, pair.front], toAlbumNamed: "Memoree")
        #expect(albumID != nil)

        // Fetching by the returned identifier must find a real collection.
        let albums = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [try #require(albumID)], options: nil)
        #expect(albums.count == 1)

        // `PHAssetCollection` does not expose its assets directly; fetch them
        // with a fetch request scoped to the collection.
        let collection = try #require(albums.firstObject)
        let members = PHAsset.fetchAssets(in: collection, options: nil)
        let identifiers = (0..<members.count).compactMap {
            members.object(at: $0).localIdentifier
        }
        #expect(identifiers.contains(pair.back))
        #expect(identifiers.contains(pair.front))
    }

    @Test("Asking for the album twice does not create a duplicate")
    func albumIsNotDuplicated() async throws {
        guard hasAddOnlyAccess else { return }

        let library = PhotoKitLibrary()
        let first = try await library.ensureAlbum(named: Self.fixtureName)
        let second = try await library.ensureAlbum(named: Self.fixtureName)
        #expect(first == second)
    }
}
