import Foundation
import ImageIO
import Testing

@testable import Memoree

/// The app icon, asserted rather than assumed present.
///
/// ## Why this exists at all
///
/// The `AppIcon.appiconset` directory was in the repository from the first day,
/// with a `Contents.json` that named **no file**, and `project.yml` pointed
/// `ASSETCATALOG_COMPILER_APPICON_NAME` at it. Every build succeeded. Every test
/// suite passed. The app would have been rejected by the App Store on its first
/// upload, for the only reason an app is ever rejected before anyone looks at it.
///
/// So: a `Contents.json` that names an image is worth a test, because the
/// alternative is finding out from Apple.
///
/// ## What is checked, and what is not
///
/// That a 1024 PNG exists, at 1024×1024, opaque, and is the file the manifest
/// points at. What the icon *looks like* is a design decision and belongs to a
/// person — this suite checks that the decision reached disk, not that it was the
/// right one. The drawing lives in `Scripts/make-appicon.swift`, which is the
/// reviewable form of that decision.
@Suite("App icon", .enabled(if: sourceIsReadableOnThisHost))
struct AppIconTests {

    private static var catalogRoot: URL {
        SourceScan.appRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Assets.xcassets", isDirectory: true)
    }

    private static var appIconSet: URL {
        catalogRoot.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
    }

    /// The manifest, decoded with `JSONSerialization` rather than `Codable`.
    ///
    /// **Because the manifest is not ours.** It is written by Xcode and its shape
    /// changes between toolchains; a `Codable` struct over it would be a second
    /// thing to keep current and would fail on a toolchain update for no reason.
    /// What is needed here is one field.
    private static func manifest() throws -> [[String: Any]] {
        let url = appIconSet.appendingPathComponent("Contents.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let images = (object as? [String: Any])?["images"]
        return try #require(images as? [[String: Any]], "AppIcon Contents.json has no images array")
    }

    @Test("The app icon set names an image file")
    func theIconSetNamesAFile() throws {
        let images = try Self.manifest()

        let named = images.filter { $0["filename"] is String }
        #expect(
            !named.isEmpty,
            """
            AppIcon.appiconset names no file. Every build passes and the App Store \
            rejects the upload. Generate it with: swift Scripts/make-appicon.swift
            """
        )
    }

    @Test("The named icon file is actually there")
    func theNamedFileExists() throws {
        for image in try Self.manifest() {
            guard let name = image["filename"] as? String else { continue }
            let url = Self.appIconSet.appendingPathComponent(name)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "AppIcon.appiconset names \(name) and the file is not there"
            )
        }
    }

    @Test("The icon is one opaque 1024 PNG, because that is all iOS asks for")
    func theIconIsOneOpaque1024PNG() throws {
        let images = try Self.manifest()
        let universal = images.filter { ($0["idiom"] as? String) == "universal" }

        #expect(universal.count == 1,
                "the modern icon format is one universal 1024 image; this is \(universal.count)")

        let size = try #require(universal.first?["size"] as? String)
        #expect(size == "1024x1024", "unexpected icon size \(size)")

        guard let name = universal.first?["filename"] as? String else { return }
        let url = Self.appIconSet.appendingPathComponent(name)

        // **Read as bytes rather than as an image.** The question here is
        // "is there a 1024-square PNG", and `CGImageSource` answers all of it —
        // including the alpha channel, which an app icon must not have.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            Issue.record("\(name) is not a readable image")
            return
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Issue.record("\(name) decoded to no image")
            return
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] else {
            Issue.record("\(name) has no image properties")
            return
        }

        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        // **Defence in depth, and `actool` is the layer above this.** A 900px PNG
        // in a set that declares 1024 makes the *build* fail — "the app icon set
        // named AppIcon did not have any applicable content" — so by the time a
        // test could see a wrong size, the build already stopped. Asserted anyway
        // because it costs nothing and because the failure it replaces is a
        // confusing one: the message names the set, not the pixel count.
        #expect(width == 1024 && height == 1024,
                "\(name) is \(width ?? -1)×\(height ?? -1), not 1024×1024")

        // **The decoded image's `alphaInfo`, not the PNG's `hasAlpha` flag.**
        //
        // App Store Connect rejects an icon with an alpha channel, and it checks
        // the *channel* — a `.noneSkipLast` PNG is visually opaque and still
        // carries the bit. `sips` adds one while resizing, which is exactly how a
        // resized icon stops being shippable, so the check has to be about the
        // pixels rather than about what the file claims about itself.
        let opaqueLayouts: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        #expect(opaqueLayouts.contains(image.alphaInfo),
                "\(name) has alphaInfo \(image.alphaInfo.rawValue); it must be opaque")
    }

    @Test("The accent colour is white, not a system default")
    func theAccentColourIsWhite() throws {
        // **This one was already right, and the test says so.** The concern was
        // real enough to check: `project.yml` names
        // `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor`, and a
        // missing or un-set accent colour falls back to iOS blue — which would put
        // system-blue switches and selection handles into a design system with no
        // brand hue at all (`AGENTS.md` §11).
        let url = Self.catalogRoot
            .appendingPathComponent("AccentColor.colorset", isDirectory: true)
            .appendingPathComponent("Contents.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let colours = try #require(
            (object as? [String: Any])?["colors"] as? [[String: Any]],
            "AccentColor.colorset has no colors array"
        )
        // **Through `color.components`, which is where they actually are.** The
        // first version read them off `color` directly and reported every channel
        // as "unset" — for a colourset whose values are correct, and had been since
        // the catalogue was written.
        let color = try #require(
            colours.first?["color"] as? [String: Any],
            "AccentColor.colorset has no color"
        )
        let components = try #require(
            color["components"] as? [String: Any],
            "AccentColor.colorset color has no components"
        )

        for channel in ["red", "green", "blue"] {
            let value = try #require(components[channel] as? String, "\(channel) is unset")
            #expect(value == "1.000", "AccentColor.\(channel) is \(value); it must be white")
        }
        let alpha = try #require(components["alpha"] as? String, "alpha is unset")
        #expect(alpha == "1.000", "AccentColor.alpha is \(alpha); it must be opaque")
    }

    @Test("The canvas is black in the asset catalog too, not only in code")
    func theLaunchBackgroundIsBlack() throws {
        // **`AGENTS.md` §11 says the canvas is `#000000` exactly, and the launch
        // image is the one moment the user sees before any SwiftUI runs.** A white
        // flash at launch on a dark-only app is the most common complaint an app
        // like this gets, and it is set in a file no design-system test reads.
        let url = Self.catalogRoot
            .appendingPathComponent("LaunchBackground.colorset", isDirectory: true)
            .appendingPathComponent("Contents.json")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        let colours = try #require(
            (object as? [String: Any])?["colors"] as? [[String: Any]],
            "LaunchBackground.colorset has no colors array"
        )
        // **Through `color.components`** — see the note in the accent test, which
        // is where this was got wrong first.
        let color = try #require(
            colours.first?["color"] as? [String: Any],
            "LaunchBackground.colorset has no color"
        )
        let components = try #require(
            color["components"] as? [String: Any],
            "LaunchBackground.colorset color has no components"
        )

        for channel in ["red", "green", "blue"] {
            let value = try #require(components[channel] as? String, "\(channel) is unset")
            let normalised = value.hasPrefix("0x")
                ? value
                : String(format: "0x%02X", Int(value) ?? -1)
            #expect(normalised == "0x00", "LaunchBackground.\(channel) is \(value); it must be black")
        }
    }
}
