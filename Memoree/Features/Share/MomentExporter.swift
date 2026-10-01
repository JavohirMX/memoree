import Foundation

/// The export format: every moment's metadata as one JSON document.
///
/// ## What this is for
///
/// BeReal cannot get your photographs out. Neither can this app — **Memoree holds
/// add-only authorisation and never deletes, so the photographs are in the user's
/// own library where any of a thousand apps can reach them (ADR-008).** What BeReal
/// cannot do is get the *record* out: which day each photograph belongs to, whether
/// it counted, how many times it was retaken. That is this document.
///
/// So the honest framing is narrow and worth stating: **an export restores nothing
/// and contains no photographs.** It is a readable record, not a backup. A file
/// called "export" that a user believes will bring their archive back is worse than
/// no file, because they will not check.
///
/// ## What is deliberately *not* in it
///
/// - **`PHAsset.localIdentifier`.** This is the decision that shapes the format.
///   The identifiers are meaningless on another device, meaningless after a
///   reinstall, and meaningless to anything but PhotoKit. Including them would make
///   the JSON look restorable — it would carry a field that *looks* like a pointer
///   to the photograph and points at nothing. So the export has no asset fields at
///   all, and the photographs are found by date in the user's own library.
/// - **Coordinates.** Nothing ever writes them; there is no location prompt in the
///   app. If that changes the export gains a field, and that is an ADR.
/// - **`id`, the internal UUID.** Stable only within one install, and it identifies
///   nothing outside it.
///
/// ## Versioning
///
/// `formatVersion` is not ceremony. A file that cannot be read back is not an
/// export, and the only thing that makes a format readable later is a version and a
/// reader that tolerates versions it does not know. An unknown *newer* version is
/// refused rather than partially parsed — a moment that silently loses `retakeCount`
/// is worse than a file that says it cannot read it.
struct MomentExport: Codable, Equatable {

    /// The format this document is written in. See above.
    ///
    /// **Start at 1 and change it only when the shape changes.** A field being
    /// added is a change; a comment being fixed is not.
    static let currentFormatVersion = 1

    let formatVersion: Int

    /// When the export was made. A record of when it was taken is worth having in a
    /// document about time.
    let exportedAt: Date

    /// The moments, newest first.
    ///
    /// Newest first to match the archive and the stats screen, on the same reasoning
    /// as everywhere else in the app: two screens listing the same photographs in
    /// different orders make the user work out which is "the first".
    let moments: [ExportedMoment]

    init(moments: [MomentFacts], exportedAt: Date) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.moments = moments
            .sorted { $0.capturedAt > $1.capturedAt }
            .map(ExportedMoment.init(facts:))
    }
}

/// One moment's metadata.
///
/// A distinct type rather than encoding `MomentFacts` directly, for two reasons
/// that are the same reason: **the export is a contract with a future reader, and it
/// is not the app's internal shape.** A field added to `MomentFacts` for some
/// unrelated screen reason would appear in every export and change the format by
/// accident; a field removed for a refactor would break every export already made.
/// The mapping is explicit, so both changes have to be *chosen*.
struct ExportedMoment: Codable, Equatable {

    /// The day this moment belongs to, `"2026-10-01"`.
    ///
    /// **A string, not a `Date`.** The day is a calendar concept — it is the thing
    /// the window was drawn in, and it is what a moment is *for*. Encoding it as an
    /// instant would make it mean "midnight somewhere", which is not the same claim
    /// and would not survive the reader being in a different time zone.
    let day: String

    /// When the shutter fired, ISO 8601, with an offset.
    ///
    /// **With the offset, deliberately.** `2026-10-01T17:59:00Z` is a fact about a
    /// moment in the world; `2026-10-01T17:59:00` is a fact about a moment only if
    /// you already know where you are. The offset is what makes an export readable
    /// on a machine in another country, which is the only reason to export one.
    let capturedAt: Date

    /// When today's window closed, ISO 8601 with an offset.
    ///
    /// Included so a reader can check `isOnTime` themselves rather than trusting
    /// this app's arithmetic — and so that a future change to the window rules does
    /// not silently change what the past means.
    let windowEndsAt: Date

    /// Whether the capture landed inside the window.
    ///
    /// **The only thing that grows a streak (ADR-023), so the most load-bearing
    /// field in the file.** Present because a record of the archive is exactly this,
    /// and absent because the UI is not allowed to know (ADR-023).
    let isOnTime: Bool

    /// How many times either half was reshot.
    let retakeCount: Int

    init(facts: MomentFacts) {
        day = facts.day.rawValue
        capturedAt = facts.capturedAt
        windowEndsAt = facts.windowEndsAt
        isOnTime = facts.isOnTime
        retakeCount = facts.retakeCount
    }

    /// For tests and for previewing the format.
    init(
        day: String,
        capturedAt: Date,
        windowEndsAt: Date,
        isOnTime: Bool,
        retakeCount: Int
    ) {
        self.day = day
        self.capturedAt = capturedAt
        self.windowEndsAt = windowEndsAt
        self.isOnTime = isOnTime
        self.retakeCount = retakeCount
    }
}

/// Why an export could not be read.
enum ExportError: LocalizedError, Equatable {

    /// The file is not JSON, or is JSON of the wrong shape entirely.
    case unreadable(String)

    /// A newer version than this build understands.
    ///
    /// **Refused rather than partially read.** An older reader given a file from a
    /// newer writer will otherwise produce an archive that looks complete and is
    /// missing whatever was added — which is the specific failure an export exists
    /// to prevent.
    case unsupportedVersion(found: Int, supported: Int)

    /// The day string is not a day.
    case malformedDay(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "This file is not a Memoree export. \(detail)"
        case .unsupportedVersion(let found, let supported):
            return """
                This export was written by a newer version of Memoree \
                (format \(found); this version reads up to \(supported)). \
                Nothing was lost — the file is fine, this build simply cannot \
                read it.
                """
        case .malformedDay(let value):
            return "A moment in this export has an unreadable date: \(value)."
        }
    }
}

/// Reads and writes the export.
enum MomentExporter {

    /// The filename handed to the share sheet.
    ///
    /// **`memoree-export-<date>.json`,** as specified. The date is the export's
    /// date rather than the moment's — an export of 500 moments has 500 dates, and
    /// the one a user wants to find in their files later is the day they made it.
    static func filename(for date: Date, calendar: Calendar = .current) -> String {
        // Built from `DateFormatter` rather than `.formatted(.iso8601…)`, because
        // the *date* style has no two-digit options — the ISO 8601 strategy is for
        // parsing a full instant and its format style is not configurable the way a
        // plain `.dateTime` is.
        //
        // The locale is pinned to `en_US_POSIX` so the digits and the separators
        // cannot follow the device: a filename is not prose, and a user whose phone
        // is set to Arabic should not find a file with Arabic-Indic digits that no
        // other tool will match.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "memoree-export-\(formatter.string(from: date)).json"
    }

    /// Encodes an export.
    ///
    /// **Pretty-printed with sorted keys.** The output is meant to be *read* — by a
    /// person opening it in a text editor, which is the realistic use for a record
    /// whose photographs are already somewhere else. `sortedKeys` makes two exports
    /// of the same data byte-identical, which is what lets a test compare a file
    /// rather than a parse of it.
    static func encode(_ export: MomentExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    /// Decodes an export, or says why it could not.
    ///
    /// Validates the day strings rather than trusting them: a `DayIdentifier` that
    /// is not one is a corrupt or hand-edited file, and carrying it through would
    /// put a nonsense day into whatever the reader does next. The other fields are
    /// `Codable` and cannot really be wrong.
    static func decode(_ data: Data) throws -> MomentExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let export: MomentExport
        do {
            export = try decoder.decode(MomentExport.self, from: data)
        } catch {
            throw ExportError.unreadable(error.localizedDescription)
        }

        guard export.formatVersion <= MomentExport.currentFormatVersion else {
            throw ExportError.unsupportedVersion(
                found: export.formatVersion,
                supported: MomentExport.currentFormatVersion
            )
        }

        for moment in export.moments {
            guard DayIdentifier(string: moment.day, calendar: .current) != nil else {
                throw ExportError.malformedDay(moment.day)
            }
        }

        return export
    }
}
