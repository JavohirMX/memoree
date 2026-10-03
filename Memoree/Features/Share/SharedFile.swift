import CoreTransferable
import Foundation
import UIKit
import UniformTypeIdentifiers

/// One file on its way out of the app.
///
/// ## Where the bytes live, and why that is not a violation
///
/// `AGENTS.md` §2.4: **no image bytes in app storage** — photographs go to Photos
/// and the app keeps metadata and `PHAsset.localIdentifier` only.
///
/// A `ShareLink` needs a file, so `Transferable` writes one. Three things keep
/// this compatible with the rule, and all three are load-bearing rather than
/// reassuring:
///
/// 1. **It is a temp file, not app storage.** `FileRepresentation` writes into
///    `temporaryDirectory`, which the system purges. Nothing survives the share
///    sheet, and nothing is backed up, indexed, or counted against the app's
///    container.
/// 2. **The bytes are streamed from Photos, not copied at capture.** They come
///    from `photoLibrary.data(for:)` at the moment the user taps share, so there
///    is no second copy of a photograph anywhere in the app (ADR-007).
/// 3. **The share sheet owns the copy.** The receiving app reads it from the
///    system's hand-off. Memoree has no idea where it went and no way to stop it
///    — which is the correct position for a *user-initiated* share, and the whole
///    difference between this and a server upload.
///
/// The rule exists so that deleting Memoree cannot lose a photograph. A temp file
/// that is deleted with the app holds nothing the user's library does not.
struct SharedImageFile: Transferable {

    /// What to call it in the share sheet and on disk.
    let filename: String
    let data: Data

    /// The type declared to the share sheet and to every receiving app.
    ///
    /// **Named rather than written inline** in the representation below, so a
    /// test can read the declaration instead of the source text — and so the
    /// thing the receiving app is told is a single symbol with one definition,
    /// rather than a literal that could drift from the filename convention.
    static let declaredContentType: UTType = .image

    static var transferRepresentation: some TransferRepresentation {
        // `FileRepresentation` rather than `DataRepresentation(exportedContentType:)`,
        // because the receiving app gets a *file* with a name it can keep. A
        // bare `Data` arrives as an unnamed blob and every app treats that
        // differently.
        // **The export-only `FileRepresentation`, deliberately.** There is an overload
        // that also takes an `importing:` closure, and writing one was the first
        // instinct — the point being that there is no way to get an *image* into
        // Memoree's storage (§2.4). But the export-only overload exists, and it is
        // strictly better than a closure that throws: **there is no import path
        // at all**, rather than a path that exists and is blocked. A door with a
        // lock is not the same as a wall, and only one of the two survives
        // contact with a future change.
        FileRepresentation(exportedContentType: declaredContentType) { file in
            SentTransferredFile(try file.writeToTemporaryFile())
        }
    }

    /// Writes the bytes out for the share sheet and returns its URL.
    ///
    /// `internal` rather than `private` so a test can call exactly this — see
    /// `TemporaryShareFile` for why that method is the one worth testing.
    func writeToTemporaryFile() throws -> URL {
        try TemporaryShareFile.write(filename: filename, data: data)
    }

    /// A photograph, named for the day it belongs to.
    ///
    /// `memoree-2026-10-01-back.jpg` rather than `IMG_1234.jpg`: the identifier
    /// is the day, which is what the file *is*, and a user looking at it in
    /// Messages months later can tell what it is without opening it.
    static func photograph(
        day: String,
        half: String,
        data: Data,
        extension pathExtension: String = "jpg"
    ) -> SharedImageFile {
        SharedImageFile(filename: "memoree-\(day)-\(half).\(pathExtension)", data: data)
    }

    /// The combined front-inside-back image.
    static func composite(day: String, data: Data) -> SharedImageFile {
        SharedImageFile(filename: "memoree-\(day).jpg", data: data)
    }
}

/// The whole archive as one JSON file.
///
/// ## Why this is a second type rather than a flag
///
/// `Transferable.transferRepresentation` is `static`, so `exportedContentType`
/// cannot read anything about the instance — which means one `Transferable`
/// type can only ever declare **one** content type for all of its values.
///
/// It did. `SharedImageFile`'s predecessor hardcoded `.image`, so the JSON
/// archive export left the app advertised to the share sheet and to every
/// receiving app as `public.image` while carrying a `.json` filename: a file
/// whose declared type and actual contents disagree. The share sheet shows
/// such an item as a picture; a receiving app is entitled to reject it.
///
/// The fix is not a `contentType` property, because the property would be
/// unreadable from the one place it has to be used — a flag that cannot reach
/// the declaration it exists to set is a comment. **Splitting by kind makes the
/// wrong declaration unrepresentable**, which is the project's own idiom
/// (ADR-023's payload deletion, and the FR-5 refusal built structurally rather
/// than as a disabled button).
struct SharedArchiveFile: Transferable {

    let filename: String
    let data: Data

    /// See `SharedImageFile.declaredContentType` — named for the same reason.
    static let declaredContentType: UTType = .json

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: declaredContentType) { file in
            SentTransferredFile(try file.writeToTemporaryFile())
        }
    }

    func writeToTemporaryFile() throws -> URL {
        try TemporaryShareFile.write(filename: filename, data: data)
    }

    /// The JSON export.
    static func export(day: String, data: Data) -> SharedArchiveFile {
        SharedArchiveFile(filename: MomentExporter.filename(for: Self.date(from: day)),
                          data: data)
    }

    /// Rebuilds a date from a `"2026-10-01"` day string.
    ///
    /// The filename takes a `Date` and the day is a string, and converting
    /// through a formatter here would be a second place to get a day wrong. The
    /// export already carries `exportedAt`; this only exists for the export file
    /// name and is documented as such.
    private static func date(from day: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: day) ?? Date(timeIntervalSince1970: 0)
    }
}

/// Writes a shared payload to where the share sheet can read it.
///
/// ## This is the only place image bytes touch the filesystem
///
/// §2.4 says no image bytes in app storage. This writes one, and the
/// distinctions that keep it compatible are worth stating rather than
/// assuming:
///
/// - **`temporaryDirectory`, not the container.** The system purges it. Nothing
///   is backed up, indexed, or counted against the app's storage, and the file
///   does not survive the app being deleted — which is the rule's actual
///   purpose: deleting Memoree must not lose a photograph.
/// - **A per-share subdirectory**, so two moments shared in one session cannot
///   overwrite each other's file, and so the whole thing is one removable
///   directory rather than loose files.
/// - **Not deleted afterwards.** The share sheet reads it asynchronously and
///   the app cannot know when it is finished; a file deleted too early is a
///   share that silently produced nothing. The system cleans up.
///
/// The alternative — handing the share sheet a URL inside the app's own
/// documents directory, or holding the bytes in memory and hoping — is either
/// the storage violation or the silent failure.
///
/// ## `internal` rather than `private`
///
/// So a test can call exactly this and assert the file lands in a temporary
/// directory and not the container. That is the one claim about §2.4 worth a
/// test, and a test that reached the behaviour by reimplementing it would be
/// testing itself.
enum TemporaryShareFile {

    static func write(filename: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memoree-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        // **The name is sanitised.** Every filename here is built from a
        // `DayIdentifier` we control, so this is belt-and-braces — but a path
        // traversal in a share filename would write outside the directory, and
        // the cost of checking is a few characters.
        let safeName = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "..", with: "-")
        let url = directory.appendingPathComponent(safeName)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Why a share could not be prepared.
enum ShareError: LocalizedError, Equatable {

    /// The photographs are gone from Photos, so there is nothing to share.
    ///
    /// **Distinct from "the moment has no photographs recorded"** — that is a
    /// moment the user made before the second shutter press, which shares as one
    /// photograph. This is a moment whose photographs the user deleted
    /// deliberately, and saying so is more useful than an empty share sheet
    /// (ADR-008).
    case photographsMissing

    /// The bytes could not be encoded.
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .photographsMissing:
            return """
                These photographs are no longer in your library, so there is \
                nothing to share. The moment is still in your archive.
                """
        case .renderFailed:
            return "Memoree could not prepare these photographs to share."
        }
    }
}

/// Everything a single moment can be shared as.
///
/// ## Why this bundles the choice rather than offering three buttons
///
/// A share sheet opened with three entries — "back photo", "front photo",
/// "combined" — asks the user to know how the app stores things. **The two
/// photographs are one thing to share and the combined image is the same
/// content as one picture**, so the honest presentation is two rows: *both
/// photographs* (two files) and *one combined picture* (one file).
///
/// Both rows are offered because they are different requests. Someone posting to
/// a notes app wants two files; someone sending to a person wants one image that
/// looks like the moment rather than two loose photographs.
struct MomentSharePayload {

    let day: String
    /// Original bytes, straight from Photos.
    let backData: Data
    let frontData: Data?

    /// Both photographs, as two files.
    ///
    /// **Originals, not a re-render.** `data(for:)` returns what was written at
    /// capture, carrying its EXIF. Sharing a recompressed version would quietly
    /// degrade the only copy the app has any responsibility for.
    var photographs: [SharedImageFile] {
        var files = [SharedImageFile.photograph(day: day, half: "back", data: backData)]
        if let frontData {
            files.append(SharedImageFile.photograph(day: day, half: "front", data: frontData))
        }
        return files
    }

    /// The combined image, or `nil` when there is no front half to inset.
    ///
    /// `nil` rather than a rear-only image: the composite *is* two photographs,
    /// and offering it with one would be offering a different thing under the
    /// same name. A moment with one photograph shares as one photograph, which
    /// the other row already does.
    func combinedImage() -> SharedImageFile? {
        guard let frontData,
              let rendered = MomentCompositeRenderer.render(
                  back: backData,
                  front: frontData
              )
        else { return nil }
        return SharedImageFile.composite(day: day, data: rendered)
    }
}
