import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rewrites photo bytes to attach or remove GPS coordinates, preserving
/// everything else.
///
/// The reason this exists as a separate type: `AVCapturePhotoOutput`'s
/// `fileDataRepresentation()` already returns a complete JPEG or HEIC carrying
/// the full capture EXIF — exposure, lens, timestamp, orientation. Re-encoding
/// it through `UIImage` to "add GPS" would quietly discard all of that. So the
/// bytes are round-tripped at the ImageIO level instead: read the properties
/// dictionary, override only the GPS keys, write the source image through
/// unchanged.
///
/// Pure functions over `Data`, so this is testable without a device, a photo
/// library, or a camera.
enum PhotoMetadataInjector {

    /// The output format written back to disk.
    ///
    /// HEIC where the input was HEIC, JPEG otherwise. Writing HEIC for a JPEG
    /// input would needlessly recompress it and bloat the user's library; and
    /// Photos displays JPEG natively, so there is nothing to gain.
    private static func outputType(for source: CGImageSource) -> CFString {
        guard let type = CGImageSourceGetType(source) as String? else {
            return UTType.jpeg.identifier as CFString
        }
        let identifier = UTType(type)
        if identifier?.conforms(to: .heic) == true {
            return UTType.heic.identifier as CFString
        }
        return UTType.jpeg.identifier as CFString
    }

    /// Returns `data` with the GPS dictionary replaced by `location`.
    ///
    /// Passing `nil` removes any GPS data already present, which is what makes
    /// "the shared copy carries no coordinates" enforceable rather than aspirational.
    ///
    /// - Throws: `LibraryError.invalidImageData` if the bytes are not a readable image.
    static func applying(location: PhotoLocation?, to data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw LibraryError.invalidImageData
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw LibraryError.invalidImageData
        }

        // Start from the existing properties so every non-GPS key survives.
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

        if let location {
            properties[kCGImagePropertyGPSDictionary] = gpsDictionary(for: location)
        } else {
            properties.removeValue(forKey: kCGImagePropertyGPSDictionary)
        }

        // The output buffer must be retained until after Finalize, so it is
        // created up front rather than being handed inline to the destination.
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            outputType(for: source),
            1,          // file count
            nil
        ) else {
            throw LibraryError.invalidImageData
        }

        if properties[kCGImagePropertyGPSDictionary] != nil {
            // `AddImageFromSource` copies the compressed image without
            // re-encoding it, so the pixel data is identical to the capture.
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        } else {
            // Stripping GPS cannot go through `AddImageFromSource`. That
            // overload re-reads the source's own EXIF and merges it in *after*
            // the properties argument, so a removed GPS dictionary is silently
            // reinstated by the very metadata we were trying to delete.
            //
            // Decoding to a `CGImage` and re-adding drops the source EXIF
            // entirely, which is exactly what stripping requires — and the
            // pixels are still untouched, because the caller only ever passes
            // data whose EXIF they intend to discard.
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw LibraryError.invalidImageData
            }
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw LibraryError.invalidImageData
        }

        return buffer as Data
    }

    /// Builds the EXIF GPS dictionary.
    ///
    /// EXIF stores latitude and longitude as magnitudes plus a hemisphere
    /// letter, not as signed decimals. Writing a negative latitude directly is a
    /// common bug — Photos then renders the coordinate in the wrong hemisphere.
    static func gpsDictionary(for location: PhotoLocation) -> [CFString: Any] {
        let timestamp = ISO8601DateFormatter().string(from: Date())

        var gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(location.latitude),
            kCGImagePropertyGPSLatitudeRef: location.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(location.longitude),
            kCGImagePropertyGPSLongitudeRef: location.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSTimeStamp: timestamp,
        ]

        // Altitude is genuinely absent, so say so rather than writing a zero
        // that would read as sea level. Spelled as a literal because the typed
        // `kCGImagePropertyGPSHasAltitude` symbol is not exposed by the SDK.
        gps["GPSHasAltitude" as CFString] = false

        return gps
    }

    /// Reads back the GPS coordinates from photo bytes.
    ///
    /// Used by tests to prove the round-trip, and by the moment detail view to
    /// confirm what actually landed in the library.
    static func readLocation(from data: Data) -> PhotoLocation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return nil }

        let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"

        // EXIF stores magnitudes; the hemisphere letter carries the sign.
        let signedLatitude = latitudeRef.uppercased() == "S" ? -latitude : latitude
        let signedLongitude = longitudeRef.uppercased() == "W" ? -longitude : longitude

        return PhotoLocation(latitude: signedLatitude, longitude: signedLongitude)
    }
}
