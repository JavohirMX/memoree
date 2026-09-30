import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Memoree

/// Phase 3 — GPS injection and stripping.
///
/// The property that matters most is the last one in section 3: stripping GPS
/// must actually remove it. An earlier implementation passed `nil` in the
/// properties dictionary and removed the key, but `CGImageDestinationAddImageFromSource`
/// re-reads the source's own EXIF *after* the properties argument and merged the
/// coordinates straight back in. Every "coordinates removed" check passed at the
/// call site and the photo still carried a location.
@Suite("Phase 3 — PhotoMetadataInjector")
struct PhotoMetadataInjectorTests {

    // MARK: - Fixtures

    /// A real JPEG carrying known EXIF, so the round-trip has a genuine input
    /// rather than a byte string that happens to parse.
    private func makeJPEG(withEXIF: Bool = true, size: Int = 64) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())

        let buffer = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(buffer, UTType.jpeg.identifier as CFString, 1, nil)
        )

        var properties: [CFString: Any] = [:]
        if withEXIF {
            properties = [
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "Memoree",
                    kCGImagePropertyTIFFModel: "TestRig",
                ],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2026:09:30 14:00:00",
                    kCGImagePropertyExifLensModel: "back wide",
                ],
            ]
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    private func makeHEIC(size: Int = 64) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try #require(context.makeImage())

        let buffer = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(buffer, UTType.heic.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return buffer as Data
    }

    private func type(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    private func stringValue(_ data: Data, _ keys: [CFString]) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        for key in keys.dropLast() {
            guard let inner = properties[key] as? [CFString: Any] else { return nil }
            properties = inner
        }
        return properties[keys[keys.count - 1]] as? String
    }

    // MARK: - Round trip

    @Test("Coordinates survive the round-trip exactly")
    func roundTripPreservesCoordinates() throws {
        let paris = PhotoLocation(latitude: 48.8584, longitude: 2.2945)
        let output = try PhotoMetadataInjector.applying(location: paris, to: try makeJPEG())

        let read = try #require(PhotoMetadataInjector.readLocation(from: output))
        #expect(abs(read.latitude - 48.8584) < 0.0001)
        #expect(abs(read.longitude - 2.2945) < 0.0001)
    }

    @Test("Southern and western hemispheres keep the correct sign")
    func hemispheresKeepSign() throws {
        // EXIF stores magnitudes plus a hemisphere letter. Writing a negative
        // latitude directly is the classic bug: Photos renders the position in
        // the opposite hemisphere.
        let sydney = try #require(
            PhotoMetadataInjector.readLocation(from:
                try PhotoMetadataInjector.applying(
                    location: PhotoLocation(latitude: -33.8688, longitude: 151.2093),
                    to: try makeJPEG()
                )
            )
        )
        #expect(sydney.latitude < 0, "Sydney is south of the equator")
        #expect(sydney.longitude > 0, "Sydney is east of Greenwich")

        let denver = try #require(
            PhotoMetadataInjector.readLocation(from:
                try PhotoMetadataInjector.applying(
                    location: PhotoLocation(latitude: 39.7392, longitude: -104.9903),
                    to: try makeJPEG()
                )
            )
        )
        #expect(denver.latitude > 0)
        #expect(denver.longitude < 0)
    }

    @Test("Zero coordinates are treated as north/east, not lost")
    func zeroCoordinates() throws {
        // `>= 0` rather than `> 0`, so the equator and prime meridian round-trip
        // instead of flipping hemisphere.
        let origin = try #require(
            PhotoMetadataInjector.readLocation(from:
                try PhotoMetadataInjector.applying(
                    location: PhotoLocation(latitude: 0, longitude: 0),
                    to: try makeJPEG()
                )
            )
        )
        #expect(origin.latitude == 0)
        #expect(origin.longitude == 0)
    }

    @Test("Re-applying replaces rather than accumulating")
    func reapplyReplaces() throws {
        let first = try PhotoMetadataInjector.applying(
            location: PhotoLocation(latitude: 48.8584, longitude: 2.2945), to: try makeJPEG())
        let second = try PhotoMetadataInjector.applying(
            location: PhotoLocation(latitude: -33.8688, longitude: 151.2093), to: first)

        let read = try #require(PhotoMetadataInjector.readLocation(from: second))
        #expect(abs(read.latitude + 33.8688) < 0.0001)
    }

    // MARK: - Preservation

    @Test("Existing capture EXIF is preserved")
    func preservesExistingEXIF() throws {
        let output = try PhotoMetadataInjector.applying(
            location: PhotoLocation(latitude: 48.8584, longitude: 2.2945),
            to: try makeJPEG()
        )
        #expect(stringValue(output, [kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake]) == "Memoree")
        #expect(stringValue(output, [kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal])
                 == "2026:09:30 14:00:00")
        #expect(stringValue(output, [kCGImagePropertyExifDictionary, kCGImagePropertyExifLensModel])
                 == "back wide")
    }

    @Test("An image with no pre-existing EXIF still gains coordinates")
    func bareImageGainsCoordinates() throws {
        let output = try PhotoMetadataInjector.applying(
            location: PhotoLocation(latitude: 10, longitude: 20),
            to: try makeJPEG(withEXIF: false)
        )
        #expect(PhotoMetadataInjector.readLocation(from: output)?.latitude == 10)
    }

    @Test("Container format is preserved — HEIC stays HEIC, JPEG stays JPEG")
    func preservesContainerFormat() throws {
        let jpegOut = try PhotoMetadataInjector.applying(
            location: PhotoLocation(latitude: 1, longitude: 2), to: try makeJPEG())
        #expect(type(of: jpegOut)?.contains("jpeg") == true)

        // Writing HEIC for a JPEG input would recompress and bloat the user's
        // library for no benefit.
        let heicOut = try PhotoMetadataInjector.applying(
            location: PhotoLocation(latitude: 1, longitude: 2), to: try makeHEIC())
        #expect(type(of: heicOut)?.contains("heic") == true)
        #expect(PhotoMetadataInjector.readLocation(from: heicOut)?.latitude == 1)
    }

    // MARK: - Stripping

    @Test("Nil location removes coordinates that were present")
    func strippingRemovesCoordinates() throws {
        // The regression this guards: `AddImageFromSource` merges the source's
        // own EXIF *after* the properties argument, so merely deleting the key
        // leaves the coordinates in place.
        let withGPS = try PhotoMetadataInjector.applying(
            location: PhotoLocation(latitude: 48.8584, longitude: 2.2945), to: try makeJPEG())
        #expect(PhotoMetadataInjector.readLocation(from: withGPS) != nil, "precondition")

        let stripped = try PhotoMetadataInjector.applying(location: nil, to: withGPS)
        #expect(PhotoMetadataInjector.readLocation(from: stripped) == nil,
                "coordinates must not survive a strip request")
    }

    @Test("Stripping leaves the rest of the metadata intact")
    func strippingPreservesOtherMetadata() throws {
        let withGPS = try PhotoMetadataInjector.applying(
            location: PhotoLocation(latitude: 48.8584, longitude: 2.2945), to: try makeJPEG())
        let stripped = try PhotoMetadataInjector.applying(location: nil, to: withGPS)
        #expect(stringValue(stripped, [kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake]) == "Memoree")
    }

    // MARK: - Failure modes

    @Test("Unreadable data throws rather than crashing")
    func rejectsGarbage() {
        #expect(throws: LibraryError.invalidImageData) {
            try PhotoMetadataInjector.applying(
                location: PhotoLocation(latitude: 1, longitude: 2),
                to: Data([0x00, 0x01, 0x02, 0x03])
            )
        }
    }

    @Test("Empty data throws")
    func rejectsEmptyData() {
        #expect(throws: LibraryError.invalidImageData) {
            try PhotoMetadataInjector.applying(location: nil, to: Data())
        }
    }

    @Test("Reading location from a bare image returns nil rather than a default")
    func readFromBareImage() throws {
        #expect(PhotoMetadataInjector.readLocation(from: try makeJPEG(withEXIF: false)) == nil)
    }

    @Test("Every library error has user-facing copy")
    func errorsHaveCopy() {
        let errors: [LibraryError] = [
            .authorizationDenied, .invalidImageData, .assetMissing("x"),
            .albumUnavailable, .writeFailed("disk"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false, "\(error) has no description")
        }
    }
}
