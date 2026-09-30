import CoreGraphics
import Foundation
import ImageIO
import Photos
import Testing
import UniformTypeIdentifiers

@testable import Memoree

/// Phase 3 exit criterion — a real write to the user's actual photo library.
///
/// **Opt-in, and device-only.** Two separate gates, both necessary:
///
/// - `MEMOREE_LIVE_PHOTO_TESTS=1` must be set in the environment. Without it
///   every test here returns immediately.
/// - A physical device is required. The simulator's photo library is a
///   throwaway sandbox, so it proves the code path and the identifier
///   round-trip but is not the same as writing to a real roll.
///
/// The env-var gate is not optional politeness. `PHPhotoLibrary
/// .requestAuthorization(for: .addOnly)` **blocks indefinitely** when TCC holds
/// no decision and no one can dismiss the dialog — which is exactly the state a
/// test host is in. An ungated live test therefore hangs the whole suite rather
/// than failing. Gating makes the hang impossible and makes the requirement
/// explicit.
///
/// Run it with:
///
///     MEMOREE_LIVE_PHOTO_TESTS=1 xcodebuild test \
///       -project Memoree.xcodeproj -scheme Memoree \
///       -destination 'platform=iOS,name=<your device>'
///
/// These tests write two visible fixtures and do not delete them. Memoree has
/// add-only authorisation, and its rule that it never removes anything from the
/// user's library (ADR-008) applies to its own test code too.
@Suite("Phase 3 — device-only live Photos write", .serialized)
@MainActor
struct LivePhotoLibraryTests {

    private static let fixtureName = "Memoree Phase 3 Fixture"

    /// Set `MEMOREE_LIVE_PHOTO_TESTS=1` to enable. See the note above for why.
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MEMOREE_LIVE_PHOTO_TESTS"] == "1"
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

    /// Grants add-only access for the test run.
    ///
    /// Only called once the env gate has passed. Deliberately **not** a request:
    /// if TCC holds no decision, `requestAuthorization` suspends until a human
    /// dismisses the dialog, which in a test host means never.
    private func authorize() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return status == .authorized || status == .limited
    }

    @Test("Two fixture assets are written and both identifiers resolve")
    func writesTwoRealAssets() async throws {
        guard isEnabled, await authorize() else {
            // Not a failure: either the env gate is off, or the device has not
            // granted add-only access to the host app.
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
        guard isEnabled, await authorize() else { return }

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
        guard isEnabled, await authorize() else { return }

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
        guard isEnabled, await authorize() else { return }

        let library = PhotoKitLibrary()
        let first = try await library.ensureAlbum(named: Self.fixtureName)
        let second = try await library.ensureAlbum(named: Self.fixtureName)
        #expect(first == second)
    }
}
