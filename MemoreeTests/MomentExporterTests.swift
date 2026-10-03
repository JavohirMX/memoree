import Foundation
import Testing

@testable import Memoree

/// Phase 9 — the export format.
///
/// The format is a **contract with a future reader**, and these tests are the
/// contract. Everything here is about what a file does and does not say, because
/// the two ways an export goes wrong are both about a reader forming a false belief
/// from it:
///
/// - A reader believes it can **restore** the archive. It cannot — there are no
///   photographs in it, and by design there are no asset identifiers that look like
///   they might lead to some.
/// - A reader **silently loses** a field because the file came from a newer build.
///   Hence `formatVersion`, and hence refusing rather than partially parsing.
///
/// The asymmetry that runs through all of it: **an export is a record, not a
/// backup**, and the format is shaped to make that true rather than to look like a
/// backup.
@Suite("Phase 9 — export format")
struct MomentExporterTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func facts(
        _ day: String,
        hour: Int = 17,
        minute: Int = 59,
        onTime: Bool = true,
        retakes: Int = 0
    ) throws -> MomentFacts {
        let identifier = try #require(DayIdentifier(string: day, calendar: calendar))
        let capturedAt = identifier.date.addingTimeInterval(Double(hour * 3600 + minute * 60))
        return MomentFacts(
            id: UUID(),
            day: identifier,
            isOnTime: onTime,
            capturedAt: capturedAt,
            windowEndsAt: capturedAt.addingTimeInterval(120),
            retakeCount: retakes,
            hasBTS: false
        )
    }

    /// A fixed export moment, so the assertions can be literal.
    private func referenceMoment() throws -> ExportedMoment {
        let identifier = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar))
        let captured = identifier.date.addingTimeInterval(17 * 3600 + 59 * 60 + 12)
        return ExportedMoment(
            day: "2026-10-01",
            capturedAt: captured,
            windowEndsAt: captured.addingTimeInterval(120),
            isOnTime: true,
            retakeCount: 2
        )
    }

    // MARK: - What the file says

    @Test("Every field survives a round trip")
    func roundTrip() throws {
        let original = MomentExport(
            moments: [
                try facts("2026-09-30"),
                try facts("2026-10-01", onTime: false, retakes: 2),
            ],
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let decoded = try MomentExporter.decode(MomentExporter.encode(original))

        #expect(decoded.formatVersion == MomentExport.currentFormatVersion)
        #expect(decoded.exportedAt == original.exportedAt, "the export date survives")
        #expect(decoded.moments == original.moments, "and every moment field with it")
    }

    @Test("The moments are newest first, agreeing with the archive and the stats screen")
    func newestFirst() throws {
        let export = MomentExport(
            moments: [
                try facts("2026-09-30", hour: 9),
                try facts("2026-10-01", hour: 20),
                try facts("2026-09-30", hour: 21),
            ],
            exportedAt: Date()
        )

        let times = export.moments.map(\.capturedAt)
        #expect(times == times.sorted(by: >))
    }

    @Test("Timestamps carry their offset")
    func timestampsCarryAnOffset() throws {
        // **`2026-10-01T17:59:00Z` is a fact about a moment in the world;
        // `2026-10-01T17:59:00` is a fact about a moment only if you already know
        // where you are.** The offset is the whole reason an export is readable on a
        // machine in another country, which is the only reason to export one.
        //
        // Checked in the *encoded bytes* rather than by round-tripping, because a
        // round trip through the same decoder proves nothing about what is written —
        // a naive strategy would round-trip perfectly through itself.
        let export = MomentExport(moments: [try facts("2026-10-01")], exportedAt: Date())
        let json = try #require(String(data: MomentExporter.encode(export), encoding: .utf8))

        // **Asserted on the shape, not on a literal.** The first version of this
        // test asserted the JSON contained `"2026-10-01T17:59:00"` and it failed —
        // because `17:59` is the moment's time *in the machine's own time zone*, and
        // the machine running it was eight hours off UTC. **The test had committed
        // the exact mistake the offset exists to prevent**, which is worth recording
        // because it is the mistake anyone makes when writing this file by hand.
        //
        // So: find the field, check it is ISO 8601 with an offset, and check that
        // reading it back gives the same *instant*. None of that depends on where
        // the test is run.
        let written = try #require(Self.captureField(in: json), "no capturedAt in the file")
        #expect(written.hasSuffix("Z") || Self.hasExplicitOffset(written),
                "an offset rather than a floating local time: \(written)")
        #expect(!written.contains("."), "and no fractional seconds: \(written)")

        let reparsed = try #require(
            Self.parseISO8601(written),
            "the written timestamp does not parse as ISO 8601: \(written)"
        )
        #expect(abs(reparsed.timeIntervalSince(export.moments[0].capturedAt)) < 1,
                "and it is the same instant, not the same wall clock")
    }

    /// The raw JSON text of `capturedAt`.
    ///
    /// A regex over the encoded string rather than a re-decode, because re-decoding
    /// through this app's own decoder would prove nothing about what was written.
    private static func captureField(in json: String) -> String? {
        let expression = try? NSRegularExpression(
            pattern: #""capturedAt"\s*:\s*"([^"]+)""#
        )
        // `NSRange` is UTF-16 offsets, which is *not* the same as `String.count` for a
        // string containing an emoji or a flag — so this uses `utf16.count`
        // explicitly rather than `count`, which would silently match in the wrong
        // place on exactly the input most likely to contain one.
        let whole = NSRange(location: 0, length: json.utf16.count)
        guard let match = expression?.firstMatch(in: json, range: whole),
              let captured = Range(match.range(at: 1), in: json)
        else { return nil }
        return String(json[captured])
    }

    /// Whether a timestamp ends in `+HH:MM` or `-HH:MM`.
    private static func hasExplicitOffset(_ timestamp: String) -> Bool {
        // After the `T`, and after the time itself — so a `-` inside the date is not
        // mistaken for a sign.
        guard let time = timestamp.split(separator: "T").last else { return false }
        return time.contains("+") || (time.contains("-") && time.first != "-")
    }

    /// A fresh formatter per call rather than a shared static.
    ///
    /// `ISO8601DateFormatter` is a `class` and is not `Sendable`, so a `static let`
    /// is a mutable global and Swift 6 refuses it — correctly, because two suites
    /// running in parallel would be mutating the same instance's format options.
    /// Formatting one timestamp is not worth a lock.
    private static func parseISO8601(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }

    // MARK: - What the file does not say

    @Test("No asset identifiers, because they would look restorable and are not")
    func noAssetIdentifiers() throws {
        // **The decision that shapes the whole format.** A `PHAsset.localIdentifier`
        // is meaningless on another device, after a reinstall, and to anything but
        // PhotoKit. Including one would give the JSON a field that *looks* like a
        // pointer to the photograph and points at nothing — which is the exact
        // belief that makes someone not check whether their archive came back.
        //
        // So the export has no asset fields at all, and this asserts the absence
        // rather than trusting that nobody will add one later.
        let export = MomentExport(moments: [try facts("2026-10-01")], exportedAt: Date())
        let json = try #require(String(data: MomentExporter.encode(export), encoding: .utf8))

        #expect(!json.contains("Asset"), "no asset identifier fields")
        #expect(!json.contains("localIdentifier"))
        // And `MomentFacts` *does* carry them, so this is not passing because the
        // source had nothing to leak — proved by the marker test below, which
        // builds a moment with recognisable identifiers.
    }

    @Test("The app's own identifiers are not in the file either")
    func noInternalIdentifiers() throws {
        // `id` is stable only within one install and identifies nothing outside it,
        // so it is excluded for the same reason the asset identifiers are. Checked
        // by giving a moment a recognisable UUID and looking for it.
        var identifiable = try facts("2026-10-01")
        let marker = UUID()
        identifiable = MomentFacts(
            id: marker,
            day: identifiable.day,
            isOnTime: identifiable.isOnTime,
            capturedAt: identifiable.capturedAt,
            windowEndsAt: identifiable.windowEndsAt,
            retakeCount: 0,
            hasBTS: false,
            // The asset identifiers the export must *not* leak. Real ones, so the
            // test is checking the mapping rather than a literal that was never in
            // the source to begin with.
            assets: SavedAssetPair(back: "BACK-MARKER", front: "FRONT-MARKER")
        )

        let json = try #require(String(
            data: MomentExporter.encode(
                MomentExport(moments: [identifiable], exportedAt: Date())
            ),
            encoding: .utf8
        ))

        #expect(!json.contains(marker.uuidString), "not the row's UUID")
        #expect(!json.contains("BACK-MARKER"), "not a rear asset identifier")
        #expect(!json.contains("FRONT-MARKER"), "not a front asset identifier")
        #expect(!json.contains("latitude"), "and no coordinates — nothing writes them yet")
        #expect(!json.contains("longitude"))
    }

    @Test("The on-time flag is in the file, even though no screen may read it")
    func onTimeIsExported() throws {
        // **The opposite of the asset identifiers, and for the opposite reason.**
        //
        // ADR-023 removed the late badge because a badge on a photograph described
        // the *user*. It did not remove the fact. "375 of 500 on time" is on the
        // Stats screen as an aggregate; an export is the most aggregate thing there
        // is, and a record of the archive that omitted whether a photograph counted
        // would be a record of the wrong archive.
        //
        // So this is the one field the UI is forbidden from knowing that the format
        // is obliged to carry.
        let export = MomentExport(
            moments: [try facts("2026-10-01", onTime: false)],
            exportedAt: Date()
        )
        let json = try #require(String(data: MomentExporter.encode(export), encoding: .utf8))

        #expect(json.contains("\"isOnTime\""))
        #expect(json.contains("false"), "and the value survives, not just the key")
    }

    // MARK: - Reading one back

    @Test("A file from a newer version is refused rather than half-read")
    func newerVersionsAreRefused() throws {
        // **The specific failure an export exists to prevent.** An older reader
        // handed a newer file would otherwise produce an archive that looks complete
        // and is missing whatever was added since — silent data loss in the one
        // place the user was told they could trust.
        //
        // Hand-written JSON rather than a round trip, because a round trip through
        // this encoder can only ever produce the version this build writes.
        let future = """
            {
              "exportedAt": "2026-10-01T00:00:00Z",
              "formatVersion": \(MomentExport.currentFormatVersion + 1),
              "moments": []
            }
            """

        #expect(throws: ExportError.unsupportedVersion(
            found: MomentExport.currentFormatVersion + 1,
            supported: MomentExport.currentFormatVersion
        )) {
            try MomentExporter.decode(Data(future.utf8))
        }
    }

    @Test("An older file is still readable")
    func olderVersionsAreReadable() throws {
        // The other direction, and the reason a version field is worth having at
        // all: a file written by a previous build must not become unreadable when
        // the app updates.
        let older = """
            {
              "exportedAt": "2026-10-01T00:00:00Z",
              "formatVersion": 1,
              "moments": [
                {
                  "capturedAt": "2026-10-01T17:59:00Z",
                  "day": "2026-10-01",
                  "isOnTime": true,
                  "retakeCount": 0,
                  "windowEndsAt": "2026-10-01T18:01:00Z"
                }
              ]
            }
            """

        let decoded = try MomentExporter.decode(Data(older.utf8))
        #expect(decoded.moments.count == 1)
        #expect(decoded.moments.first?.day == "2026-10-01")
    }

    @Test("A file that is not JSON says so rather than crashing")
    func nonJSONIsRejected() {
        // A recoverable UI state, not a `fatalError` (AGENTS.md §6). Someone will
        // point this at the wrong file eventually.
        #expect(throws: ExportError.self) {
            try MomentExporter.decode(Data("this is not json at all".utf8))
        }
    }

    @Test("A hand-edited date is caught at the door")
    func malformedDaysAreCaught() throws {
        // A `DayIdentifier` that is not one is a corrupt or edited file. Carrying it
        // through would put a nonsense day into whatever the reader does next — and
        // the moment's day is the one field a reader has no other source for.
        let broken = """
            {
              "exportedAt": "2026-10-01T00:00:00Z",
              "formatVersion": 1,
              "moments": [
                {
                  "capturedAt": "2026-10-01T17:59:00Z",
                  "day": "the first of October",
                  "isOnTime": true,
                  "retakeCount": 0,
                  "windowEndsAt": "2026-10-01T18:01:00Z"
                }
              ]
            }
            """

        #expect(throws: ExportError.malformedDay("the first of October")) {
            try MomentExporter.decode(Data(broken.utf8))
        }
    }

    @Test("Every error has something to show a person")
    func errorsExplainThemselves() {
        // Three failures and three sentences. A screen showing "The operation
        // couldn't be completed" is the same dead end as a button that does nothing
        // (AGENTS.md §6).
        for error in [
            ExportError.unreadable("bad"),
            .unsupportedVersion(found: 9, supported: 1),
            .malformedDay("x"),
        ] {
            // Not `try? #require(error.errorDescription)`: every case returns a
            // non-optional literal, so the compiler knows it cannot be nil and
            // warns that the unwrap is redundant. The assertion that matters is
            // that the string is *not empty* — a case that returned `""` would
            // pass a `!= nil` check and render a blank error.
            let description = error.errorDescription
            #expect(description?.isEmpty == false)
        }

        // And the version one says the file is *fine*, which is the part a user
        // actually needs: they did nothing wrong and their data is intact.
        let newer = ExportError.unsupportedVersion(found: 9, supported: 1)
        #expect(newer.errorDescription?.contains("Nothing was lost") == true,
                "a refused file is still a good file")
    }

    // MARK: - The filename

    @Test("The filename is dated and portable")
    func theFilename() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!

        #expect(MomentExporter.filename(for: date, calendar: calendar)
                == "memoree-export-2026-10-01.json")
    }

    @Test("The filename does not follow the device's numerals")
    func theFilenameIsNotLocalised() {
        // A filename is not prose. A user whose phone is set to Arabic should not
        // find a file with Arabic-Indic digits that no other tool will match, and
        // the date is pinned to `en_US_POSIX` for exactly that reason.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!

        let name = MomentExporter.filename(for: date, calendar: calendar)
        #expect(name.allSatisfy { $0.isASCII }, "got \(name)")
    }

    @Test("Encoding is stable, so two exports of the same data are the same bytes")
    func encodingIsStable() throws {
        // `sortedKeys` is what makes this true, and it is what lets a test compare a
        // *file* rather than a parse of one — which is a stronger claim, because it
        // pins the bytes a user will open in a text editor.
        let moments = [try facts("2026-09-30"), try facts("2026-10-01", retakes: 1)]
        let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try MomentExporter.encode(
            MomentExport(moments: moments, exportedAt: exportedAt)
        )
        let second = try MomentExporter.encode(
            MomentExport(moments: moments, exportedAt: exportedAt)
        )
        #expect(first == second)

        // And it is pretty-printed, because the realistic use for this file is a
        // person opening it.
        let json = try #require(String(data: first, encoding: .utf8))
        #expect(json.contains("\n"), "multi-line, so a human can read it")
    }

    // MARK: - The empty export

    @Test("An archive with nothing in it is still a valid file")
    func emptyIsValid() throws {
        // Exporting from a fresh install must produce a file, not an error. The user
        // pressed a button and a share sheet has to open — and a file with no
        // moments is an accurate description of the archive.
        let export = MomentExport(moments: [], exportedAt: Date())
        let decoded = try MomentExporter.decode(MomentExporter.encode(export))

        #expect(decoded.moments.isEmpty)
        #expect(decoded.formatVersion == MomentExport.currentFormatVersion)
    }
}
