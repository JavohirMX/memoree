import Foundation
import Testing

@testable import Memoree

/// Whether the repository is readable from the process running these tests.
///
/// The same property `NoNetworkingTests` depends on, and for the same reason:
/// `#filePath` is baked in by the compiler and names a path on the build machine,
/// which exists on a simulator and does not exist on hardware.
private let sourceIsReadableOnThisHost = SourceScan.isReadable

/// The design-system and accessibility commitments, asserted rather than intended.
///
/// The plan has carried a row reading *"Dark-mode audit — assert no `colorScheme`
/// branch anywhere; light mode is not a feature"* since Phase 10 was written, and
/// nothing checked it. That is the same shape as the missing no-networking test
/// TRD §13 promised: a commitment that is true because a review happened once,
/// which is not a property that survives contact with a well-meaning
/// `if colorScheme == .dark` added for "just this one screen".
///
/// ## Why it scans source
///
/// Same reasoning as `NoNetworkingTests`, and deliberately not repeated here: a
/// binary or symbol audit would pass vacuously, because SwiftUI's own symbols
/// include the colour-scheme machinery whether or not Memoree uses it. This
/// reads the app target's source and is exact about what it claims — **no file
/// in `Memoree/` branches on the colour scheme, and every colour literal lives
/// in `Theme.swift`.**
///
/// ## Why the suite is disabled on a device
///
/// The source is not on the device. Stated rather than hidden; a returned test
/// would be reported as **passed** by Swift Testing, which is how four live tests
/// in this project asserted nothing and looked green.
@Suite("Design system invariants", .enabled(if: sourceIsReadableOnThisHost))
struct DesignSystemInvariantTests {

    private static var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Memoree", isDirectory: true)
    }

    private static func swiftFiles() throws -> [URL] {
        try SourceScan.swiftFiles()
    }

    // MARK: - Dark only

    /// What a violation looks like, and what it does not.
    ///
    /// Matched on **word boundaries** and excluding `.dark`, because
    /// `preferredColorScheme(.dark)` is the app *forcing* dark — which is
    /// ADR-012's whole mechanism, not a branch on the user's setting. A naive
    /// substring scan for "colorScheme" fails on the line that enforces the rule.
    static func colourSchemeBranch(in line: String) -> String? {
        // An environment read, a binding to it, or a comparison against it.
        let patterns = [
            #"@Environment\(\s*\.colorScheme"#,
            #"\.colorScheme\s*\)"#,
            #"\bcolorScheme\b\s*(==|!=)"#,
            #"\.preferredColorScheme\(\s*nil"#,
        ]
        for pattern in patterns {
            if line.range(of: pattern, options: .regularExpression) != nil {
                return pattern
            }
        }
        return nil
    }

    @Test("No file branches on the colour scheme")
    func noColourSchemeBranch() throws {
        let files = try Self.swiftFiles()
        #expect(!files.isEmpty, "the scan found no source files, so it proved nothing")

        var offences: [String] = []
        for file in files {
            // Comments are excluded: `Theme.swift` and `MemoreeApp` both *name*
            // `colorScheme` while explaining that there is no branch, and a
            // scanner that cannot tell a prohibition from a violation teaches
            // people to delete the comment that documents the rule.
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, raw) in source.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let line = String(raw)
                let code = line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? line
                guard let pattern = Self.colourSchemeBranch(in: code) else { continue }
                offences.append("\(file.lastPathComponent):\(number + 1): \(pattern)")
            }
        }

        #expect(
            offences.isEmpty,
            """
            the colour scheme is branched on (ADR-012, AGENTS.md §2.6 — dark is \
            not a feature, it is the only appearance): \
            \(offences.joined(separator: ", "))
            """
        )
    }

    @Test("Forcing dark is not a branch")
    func forcingDarkIsAllowed() throws {
        // The scan must not fail on the line that enforces ADR-012, and must not
        // fail on the comments that document the rule. Both were real failures in
        // the first version of this matcher: it flagged `Theme.swift`'s own
        // "there is no `colorScheme` branch anywhere".
        let mustNotBeCaught = [
            ".preferredColorScheme(.dark)",
            "// there is no colorScheme branch anywhere",
            "/// Dark only, by construction.",
        ]
        for line in mustNotBeCaught {
            #expect(
                Self.colourSchemeBranch(in: line) == nil,
                "reads a rule as a violation: \(line)"
            )
        }
    }

    @Test("The scan would notice a real branch")
    func theScanIsNotVacuous() throws {
        let mustBeCaught = [
            "if colorScheme == .dark { Text(\"light\") }",
            "@Environment(\\.colorScheme) private var scheme",
            "Text(\"\\(colorScheme == .dark ? \"a\" : \"b\")\")",
        ]
        for line in mustBeCaught {
            #expect(Self.colourSchemeBranch(in: line) != nil, "the scan would miss: \(line)")
        }
    }

    @Test("A branch hidden in a string literal is still a branch")
    func branchInAStringIsABranch() {
        // The one that gets past a naive scan, because it does not *look* like
        // a comparison. Interpolating a colour scheme into text is still the app
        // changing appearance with the system setting.
        let sneaky = "Text(\"\\(colorScheme == .dark ? \"a\" : \"b\")\")"
        #expect(Self.colourSchemeBranch(in: sneaky) != nil)
    }

    @Test("The app does force the dark appearance")
    func darkIsForcedNotJustAbsent() throws {
        // Absence of a branch is not the same as being dark. A build that simply
        // stopped calling `preferredColorScheme` would pass the scan above and
        // follow the system, which is the defect ADR-012 exists to prevent.
        let app = try #require(
            Self.swiftFiles().first { $0.lastPathComponent == "MemoreeApp.swift" },
            "MemoreeApp.swift was not found"
        )
        let contents = try String(contentsOf: app, encoding: .utf8)
        #expect(contents.contains("preferredColorScheme(.dark)"),
                "the dark appearance must be forced, not merely never branched on")
    }

    // MARK: - No literals outside the theme

    @Test("No colour literal exists outside Theme.swift")
    func noColourLiteralsOutsideTheTheme() throws {
        // `AGENTS.md` §11: "Never hardcode a hex value in a view." The theme is
        // the only place a colour may be spelled, so this is the check that makes
        // the rule enforceable rather than aspirational.
        //
        // Matched on the *shape* of a hex literal — six or eight hex digits after
        // a `0x` — not on the word "colour", because a view may legitimately name
        // a token and a comment may discuss one.
        let hexLiteral = #"0x[0-9A-Fa-f]{6,8}\b"#

        var offences: [String] = []
        for file in try Self.swiftFiles() where file.lastPathComponent != "Theme.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, raw) in source.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let line = String(raw)
                let code = line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? line
                if code.range(of: hexLiteral, options: .regularExpression) != nil {
                    offences.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }

        #expect(
            offences.isEmpty,
            "colour literals outside Theme.swift (AGENTS.md §11): \(offences.joined(separator: ", "))"
        )
    }

    // MARK: - The amber

    @Test("The amber accent appears only where a permission is declined")
    func amberHasOneJob() throws {
        // ADR-025's whole mechanism is a *reserved job*, and a reservation that
        // nothing checks is a suggestion.
        //
        // **One job, two call sites** — and the distinction is the test. The job
        // is "a permission the user declined and cannot fix from in here", which
        // is reported in two places because it is relevant in two places: the
        // Today footer says "Reminders off", and Settings offers the only
        // remedy. Both are the same fact about the same permission.
        //
        // What must not happen is a *third* meaning arriving by accident. So the
        // assertion is on the set of files, not on a count: a new use of the
        // amber anywhere else fails here, and adding one to either of these two
        // files for a different reason would not — which is a limitation worth
        // stating rather than pretending a file-level check can catch.
        let permitted = ["SettingsView.swift", "TodayView.swift", "Theme.swift"]
        var found: [String] = []
        for file in try Self.swiftFiles() {
            guard !permitted.contains(file.lastPathComponent) else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("Theme.Color.accent") {
                found.append(file.lastPathComponent)
            }
        }

        #expect(
            found.isEmpty,
            """
            the amber means one thing only — a permission the user declined \
            (ADR-025). It also appears in: \(found.joined(separator: ", "))
            """
        )
    }

    // MARK: - Layering

    @Test("Features imports no PhotoKit and no AVFoundation")
    func featuresRespectTheLayering() throws {
        // `AGENTS.md` §3: "`Features/` contains SwiftUI views and view models
        // only. No AVFoundation, no PhotoKit." The camera screen gets its preview
        // as a bare `CALayer` precisely so this holds (ADR-018), which makes it
        // worth a test — an exception granted once is an exception that grows.
        //
        // `Services` importing `SwiftUI` is the other half of the same rule and is
        // checked here too, because a service that can see a view is a service
        // that cannot be tested without one.
        var offences: [String] = []

        for file in try Self.swiftFiles() {
            let path = file.path
            let isFeature = path.contains("/Features/")
            let isService = path.contains("/Services/")
            guard isFeature || isService else { continue }

            let source = try String(contentsOf: file, encoding: .utf8)
            for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                guard !line.hasPrefix("//") else { continue }
                if isFeature,
                   line == "import Photos" || line == "import AVFoundation" {
                    offences.append("\(file.lastPathComponent): \(line)")
                }
                if isService, line == "import SwiftUI" {
                    offences.append("\(file.lastPathComponent): \(line)")
                }
            }
        }

        #expect(
            offences.isEmpty,
            "layering violations (AGENTS.md §3): \(offences.joined(separator: ", "))"
        )
    }
}
