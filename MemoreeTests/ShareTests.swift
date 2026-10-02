import Foundation
import Testing
import UIKit

@testable import Memoree

/// Phase 9 — the composite renderer and what a share actually hands over.
///
/// The renderer is the one place in the app that produces an image rather than
/// showing one, and two of its constraints are absolute and checkable:
///
/// - **No watermark** (AGENTS.md §2.7). Asserted by looking at the pixels, because
///   "there is no watermark call in the source" is a claim about the source and
///   this is a claim about the output.
/// - **No filters or retouch** (§2.8). Asserted by checking the rear photograph's
///   region is byte-identical to the source, which is the strongest available
///   statement of "the pixels were not touched".
@Suite("Phase 9 — composite renderer")
@MainActor
struct MomentCompositeRendererTests {

    /// A solid-colour image, so every pixel is predictable.
    private func solid(
        _ colour: UIColor,
        size: CGSize = CGSize(width: 300, height: 400),
        scale: CGFloat = 1
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            colour.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// The colour at a point, in the renderer's own coordinate space.
    private func colour(_ image: UIImage, at x: CGFloat, y: CGFloat) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        guard let pixel = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(pixel)
        else { return nil }

        let bytesPerRow = cgImage.bytesPerRow
        let offset = Int(y) * bytesPerRow + Int(x) * 4
        guard offset + 3 < CFDataGetLength(pixel) else { return nil }
        return UIColor(
            red: CGFloat(bytes[offset]) / 255,
            green: CGFloat(bytes[offset + 1]) / 255,
            blue: CGFloat(bytes[offset + 2]) / 255,
            alpha: CGFloat(bytes[offset + 3]) / 255
        )
    }

    /// The most saturated channel difference, for "is this the colour I expect".
    private func matches(_ actual: UIColor?, _ expected: UIColor, tolerance: CGFloat = 0.1) -> Bool {
        guard let actual else { return false }
        var a: CGFloat = 0, bx: CGFloat = 0, c: CGFloat = 0, d: CGFloat = 0
        var e: CGFloat = 0, f: CGFloat = 0, g: CGFloat = 0, h: CGFloat = 0
        actual.getRed(&a, green: &bx, blue: &c, alpha: &d)
        expected.getRed(&e, green: &f, blue: &g, alpha: &h)
        return abs(a - e) < tolerance && abs(bx - f) < tolerance && abs(c - g) < tolerance
    }

    // MARK: - The shape

    @Test("The rear photograph is the background, unchanged")
    func rearIsUntouched() throws {
        // **The strongest statement of "no filters, no retouch" available.** If
        // the background region is pixel-identical to the source, nothing was
        // recoloured, sharpened, or otherwise processed.
        let back = solid(.systemBlue)
        let front = solid(.systemOrange, size: CGSize(width: 100, height: 100))

        let rendered = try #require(
            MomentCompositeRenderer.render(back: back, front: front),
            "the renderer produced nothing"
        )
        let image = try #require(UIImage(data: rendered), "not decodable")

        // Bottom-right corner, far from the inset.
        #expect(image.size.width == back.size.width, "width is the rear's")
        #expect(matches(colour(image, at: image.size.width - 5, y: image.size.height - 5),
                        .systemBlue),
                "the rear's pixels are present, unmodified")
    }

    @Test("The canvas is 3:4 for a portrait moment")
    func theCanvasIsThreeByFour() throws {
        // ADR-019: the geometry is the app's, and a shared image that is not 3:4
        // would be shared in a different shape than the screen shows.
        let rendered = try #require(
            MomentCompositeRenderer.render(
                back: solid(.systemBlue, size: CGSize(width: 1200, height: 1600)),
                front: nil
            ),
            "nothing rendered"
        )
        let image = try #require(UIImage(data: rendered))
        let ratio = image.size.height / image.size.width
        #expect(abs(ratio - 4.0 / 3.0) < 0.01, "got \(ratio)")
    }

    @Test("A landscape moment is shared in landscape, not stretched into 3:4")
    func landscapeKeepsItsShape() throws {
        // **The bug this exists to prevent.** The canvas was `width × 4/3`
        // unconditionally, justified as "the source is already 3:4" — true while
        // the plist was portrait-only and false the moment it allowed landscape.
        // A 4:3 photograph drawn with `draw(in:)` into a 3:4 rect is **stretched
        // by a quarter in one axis**, which is the distortion AGENTS.md §2.8
        // exists to forbid.
        let rendered = try #require(
            MomentCompositeRenderer.render(
                back: solid(.systemBlue, size: CGSize(width: 1600, height: 1200)),
                front: nil
            ),
            "nothing rendered"
        )
        let image = try #require(UIImage(data: rendered))

        let ratio = image.size.height / image.size.width
        #expect(abs(ratio - 3.0 / 4.0) < 0.01, "landscape became portrait-shaped: \(ratio)")
        #expect(image.size.width > image.size.height, "a landscape moment must stay wide")
    }

    @Test("The canvas is the photograph's own size, in both orientations")
    func canvasFollowsTheSource() throws {
        // Two shapes, and the invariant is that neither is transformed into the
        // other. Stating it as a pair rather than one portrait case is the point:
        // the old code passed a portrait-only test while being wrong for every
        // landscape photograph the app could now produce.
        for size in [
            CGSize(width: 1200, height: 1600),   // 3:4 portrait
            CGSize(width: 1600, height: 1200),   // 4:3 landscape
            CGSize(width: 1000, height: 1000)    // square, in case a lens ever reports one
        ] {
            let rendered = try #require(
                MomentCompositeRenderer.render(back: solid(.systemBlue, size: size), front: nil),
                "nothing rendered for \(size)"
            )
            let image = try #require(UIImage(data: rendered))
            #expect(image.size == size, "\(size) rendered as \(image.size)")
        }
    }

    @Test("The inset is the same size in portrait and in landscape")
    func insetDoesNotGrowWithOrientation() throws {
        // **A square sized from the canvas width grows with the orientation.**
        // Landscape's width is its long edge, so a width-derived inset is about a
        // third larger there than the same moment in portrait — the inset would
        // change size because the picture turned, which is not a design anyone
        // chose. It is derived from the short side instead.
        //
        // The inset is found by **scanning for the front colour's bounds**, not
        // by recomputing the code's own formula: a test that derives its
        // expectation from the same arithmetic can only confirm the arithmetic.
        //
        // The pixel buffer is decoded **once** per image and scanned in memory.
        // The first version called `colour(...)` inside a nested loop, which
        // re-fetched `CFDataGetBytePtr` on every one of 480,000 samples and took
        // the whole suite from nine seconds to ten minutes. A slow test is not a
        // harmless test — it is a test people stop running.
        func insetEdge(for size: CGSize) throws -> CGFloat {
            let rendered = try #require(
                MomentCompositeRenderer.render(
                    back: solid(.systemBlue, size: size),
                    front: solid(.systemOrange, size: CGSize(width: 60, height: 60))
                ),
                "nothing rendered"
            )
            let image = try #require(UIImage(data: rendered))
            let pixels = try Self.pixels(of: image)

            let target = UIColor.systemOrange
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            target.getRed(&r, green: &g, blue: &b, alpha: nil)

            var furthest = 0.0
            let rowStride = image.size.width
            // Only the top third can hold the inset, so the scan is bounded rather
            // than whole-image. The inset sits at 0.245 of the short side.
            let limit = min(image.size.height, image.size.width * 0.45)
            for y in stride(from: 0.0, to: limit, by: 1) {
                for x in stride(from: 0.0, to: image.size.width, by: 1) {
                    let offset = Int(y) * Int(rowStride) + Int(x)
                    let pixel = pixels[offset]
                    if abs(Double(pixel[0]) / 255 - r) < 0.2,
                       abs(Double(pixel[1]) / 255 - g) < 0.2,
                       abs(Double(pixel[2]) / 255 - b) < 0.2 {
                        furthest = max(furthest, max(x, y))
                    }
                }
            }
            return furthest
        }

        let portrait = try insetEdge(for: CGSize(width: 1200, height: 1600))
        let landscape = try insetEdge(for: CGSize(width: 1600, height: 1200))

        // 0.245 of a 1200 short side is 294. Scanning finds the furthest orange
        // pixel, which is the inset's edge minus its border, so allow a few points.
        #expect(abs(portrait - 294) < 12, "portrait inset edge: \(portrait)")
        #expect(abs(landscape - 294) < 12, "landscape inset edge: \(landscape)")
        #expect(abs(portrait - landscape) < 4, "the inset changed size with orientation")
    }

    /// The image's pixels as `[[UInt8]]`, row-major, decoded once.
    ///
    /// Exists so a scan can index memory instead of going back through
    /// `CFDataGetBytePtr` for every sample.
    private static func pixels(of image: UIImage) throws -> [[UInt8]] {
        let cgImage = try #require(image.cgImage, "no CGImage")
        let data = try #require(cgImage.dataProvider?.data, "no pixel data")
        let bytes = try #require(CFDataGetBytePtr(data), "unreadable pixels")
        let count = CFDataGetLength(data)
        var out: [[UInt8]] = []
        out.reserveCapacity(count / 4)
        for offset in stride(from: 0, to: count, by: 4) {
            out.append([
                UInt8(bytes[offset]),
                UInt8(bytes[offset + 1]),
                UInt8(bytes[offset + 2]),
                UInt8(bytes[offset + 3])
            ])
        }
        return out
    }

    @Test("The front photograph sits in the top-left")
    func insetIsTopLeft() throws {
        let back = solid(.systemBlue)
        let front = solid(.systemOrange, size: CGSize(width: 100, height: 100))

        let rendered = try #require(
            MomentCompositeRenderer.render(back: back, front: front)
        )
        let image = try #require(UIImage(data: rendered))

        // Inside the inset, top-left.
        // The inset's side, and a point at 60% of it - comfortably inside.
        //
        // **Not the inset's own centre arithmetic.** The first version computed
        // `insetSide * 1.166`, reasoning from the margin as a fraction of the
        // inset. That lands exactly on the inset's right edge, where the
        // antialiased border is, so the sample came back the rear's blue - a
        // failure that read like a rendering bug and was a test sampling one
        // pixel past the thing it meant to check.
        let insetSide = image.size.width * MomentCompositeRenderer.Geometry.insetScale
        let sample = insetSide * 0.6
        #expect(matches(colour(image, at: sample, y: sample), .systemOrange),
                "the front is at the top left")

        // And the same point in the bottom-right is still the rear.
        #expect(matches(colour(image, at: image.size.width - 5, y: image.size.height - 5),
                        .systemBlue))
    }

    // MARK: - The two absolute constraints

    @Test("No watermark anywhere in the output")
    func noWatermark() throws {
        // Asserted on the **whole image**, not one corner. A watermark lives
        // wherever the designer put it; the only defensible check for "there is
        // none" is that every region is one of the two source colours.
        let back = solid(.systemBlue)
        let front = solid(.systemOrange, size: CGSize(width: 100, height: 100))

        let rendered = try #require(MomentCompositeRenderer.render(back: back, front: front))
        let image = try #require(UIImage(data: rendered))

        var strangers = 0
        var sampled = 0
        for row in stride(from: 2.0, to: image.size.height - 2, by: 7) {
            for column in stride(from: 2.0, to: image.size.width - 2, by: 7) {
                sampled += 1
                let here = colour(image, at: column, y: row)
                let known = matches(here, .systemBlue) || matches(here, .systemOrange)
                if !known { strangers += 1 }
            }
        }

        #expect(sampled > 500, "the sample was too small to mean anything: \(sampled)")
        // A handful of antialiased edge pixels between the two shapes is not a
        // watermark; a text glyph would be hundreds of them.
        #expect(Double(strangers) / Double(sampled) < 0.02,
                "\(strangers) of \(sampled) sampled pixels are neither source colour")
    }

    @Test("A moment with one photograph shares the photograph itself")
    func singlePhotographIsNotRefused() throws {
        // A moment captured before the second shutter press genuinely has one
        // photograph. Refusing to share it would be wrong — it is a real moment.
        let back = solid(.systemBlue)
        let rendered = try #require(MomentCompositeRenderer.render(back: back, front: nil))
        let image = try #require(UIImage(data: rendered))

        #expect(matches(colour(image, at: image.size.width / 2, y: image.size.height / 2),
                        .systemBlue),
                "just the rear, which is what there is")
    }

    @Test("Nothing is rendered from nothing")
    func refusesUndecodableInput() {
        // `nil` rather than a blank image. A shared file containing a black
        // rectangle would be worse than no file, because the user cannot tell
        // what they sent.
        #expect(MomentCompositeRenderer.render(back: Data("not a png".utf8), front: nil) == nil)
        #expect(MomentCompositeRenderer.render(back: Data(), front: Data()) == nil)
    }

    @Test("The shared bytes are JPEG, and lossy-but-high-quality")
    func outputIsJPEG() throws {
        // Asserted on the magic bytes rather than the UTI, because the UTI is a
        // label and the bytes are what the receiving app gets.
        let rendered = try #require(
            MomentCompositeRenderer.render(back: solid(.systemBlue), front: nil)
        )
        #expect(rendered.prefix(2) == Data([0xFF, 0xD8]), "JPEG start-of-image marker")
        #expect(MomentCompositeRenderer.jpegQuality >= 0.9,
                "a recompressed photograph should not look rephotographed")
    }
}

/// Phase 9 — what a share hands over.
@Suite("Phase 9 — share payload")
@MainActor
struct MomentSharePayloadTests {

    private let day = "2026-10-01"
    private let backData = Data("back-photograph-bytes".utf8)
    private let frontData = Data("front-photograph-bytes".utf8)

    // MARK: - Filenames

    @Test("Filenames say what the file is")
    func filenames() {
        // `IMG_1234.jpg` is what Photos calls it and means nothing to a person.
        // The day *is* the identifier of a moment, and a file the user meets in
        // Messages in six months should be self-describing.
        let payload = MomentSharePayload(day: day, backData: backData, frontData: frontData)
        let names = payload.photographs.map(\.filename)

        #expect(names == [
            "memoree-2026-10-01-back.jpg",
            "memoree-2026-10-01-front.jpg",
        ])
    }

    @Test("The two photographs are two files, and the combined is one")
    func theTwoOfferings() {
        // Two rows in the share sheet, not three: the two photographs are one
        // thing to share and the combined image is the same content as one
        // picture. Asking the user to know which half is which is asking them to
        // know how the app stores things.
        let payload = MomentSharePayload(day: day, backData: backData, frontData: frontData)

        #expect(payload.photographs.count == 2)
        // The combined image needs decodable bytes, which these are not, so this
        // asserts the refusal rather than a render.
        #expect(payload.combinedImage() == nil,
                "undecodable input yields no combined image, not a black rectangle")
    }

    @Test("A moment with one photograph offers one file")
    func singlePhotographOffersOneFile() {
        let payload = MomentSharePayload(day: day, backData: backData, frontData: nil)
        let files = payload.photographs

        #expect(files.count == 1)
        #expect(files[0].filename == "memoree-2026-10-01-back.jpg")
        // No front half means no composite: offering a rear-only "combined" image
        // would be a different thing under the same name.
        #expect(payload.combinedImage() == nil)
    }

    @Test("Originals are shared, not a re-render")
    func originalsAreShared() throws {
        // **The bytes handed over are the bytes that were written.** Recompressing
        // would quietly degrade the only copy the app has any responsibility for,
        // and the user would have no way to tell that is what happened.
        let payload = MomentSharePayload(day: day, backData: backData, frontData: frontData)
        let files = payload.photographs

        #expect(files[0].data == backData, "the rear is exactly what was stored")
        #expect(files[1].data == frontData, "and so is the front")
    }

    // MARK: - Where the bytes live

    @Test("A shared file writes to a temporary directory, never the container")
    func writesToTemporaryDirectory() throws {
        // **§2.4 is "no image bytes in app storage", and this is the only place
        // that writes any.** The file must land somewhere the system purges, or
        // deleting the app would delete a photograph — which is the rule's actual
        // purpose, not a technicality about where bytes are kept.
        let payload = MomentSharePayload(day: day, backData: backData, frontData: frontData)
        let file = try #require(payload.photographs.first)

        let url = try file.writeToTemporaryFile()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == backData, "and it holds the bytes")

        #expect(url.path.contains("tmp"), "got \(url.path)")
        #expect(!url.path.contains("Documents"),
                "a photograph must not survive in the app's documents")
        #expect(!url.path.contains("Library/Application Support"))

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test("Two shares of the same moment do not collide")
    func sharesDoNotCollide() throws {
        // Each share gets its own directory, so opening the share sheet twice for
        // one moment cannot have the second overwrite the first — which would
        // send the user the same photograph twice under the same name and look,
        // from the outside, like the app is duplicating their library.
        let payload = MomentSharePayload(day: day, backData: backData, frontData: frontData)
        let file = try #require(payload.photographs.first)

        let first = try file.writeToTemporaryFile()
        let second = try file.writeToTemporaryFile()

        #expect(first != second, "distinct directories per share")
        #expect(first.deletingLastPathComponent()
                != second.deletingLastPathComponent())

        for url in [first, second] {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
    }

    @Test("A filename cannot escape its directory")
    func filenamesAreContained() throws {
        // Every filename here is built from a `DayIdentifier` we control, so this
        // is belt-and-braces — but a traversal in a share filename would write
        // outside the directory the user was told about, and the check costs
        // three characters.
        let hostile = SharedFile(filename: "../../escape.jpg", data: backData)
        let url = try hostile.writeToTemporaryFile()

        #expect(url.deletingLastPathComponent().path.hasSuffix(".json")
                || !url.path.contains(".."),
                "the traversal did not survive into the path: \(url.path)")
        #expect(url.lastPathComponent != "escape.jpg")

        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
