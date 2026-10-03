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
        // The offending pattern rather than a `Bool`, so a failure can name
        // which of the four rules fired. An earlier version returned `Bool` and
        // reported the line, which is not enough — the reader is left
        // reimplementing the matcher by hand to find out.
        return patterns.first {
            line.range(of: $0, options: .regularExpression) != nil
        }
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
            for line in try SourceScan.codeLines(of: file) {
                guard let pattern = Self.colourSchemeBranch(in: line.code) else { continue }
                offences.append("\(file.lastPathComponent):\(line.number): \(pattern)")
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
            for line in try SourceScan.codeLines(of: file)
            where line.code.range(of: hexLiteral, options: .regularExpression) != nil {
                offences.append("\(file.lastPathComponent):\(line.number)")
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

    // MARK: - Sizes, which the colour rules never covered

    @Test("No view hardcodes a dimension")
    func noHardcodedDimensions() throws {
        // `AGENTS.md` §11 says no hardcoded values in a view, and the invariants
        // above enforced it **for colour only** — twelve numeric literals were
        // living in view files at the time of the audit: three button heights, two
        // tap targets, the shutter, two composite insets, three icon sizes.
        //
        // Those are not cosmetic. A fixed `52pt` on a scaling font clips its own
        // label above `accessibility-x-large`; a `20pt` icon beside a number that
        // grows to 140pt becomes punctuation. Both happened, and neither was
        // visible at the default text size.
        //
        // **Zero and one are not scanned, deliberately.** `VStack(spacing: 0)`
        // means "no gap" and a `1pt` divider is a hairline — both are literal by
        // nature, neither is a scale decision, and a token for each would be a
        // name that says "this is part of the system" when it is not. `0` and `1`
        // are also the only values that would make this scan match its own
        // regular expression's whitespace. Every value above them is checked.
        var offences: [String] = []

        for file in try SourceScan.swiftFiles() {
            guard file.lastPathComponent != "Theme.swift" else { continue }
            for line in try SourceScan.codeLines(of: file) {
                let code = line.code
                // Icon glyph sizes on a *non*-scaling system font.
                if code.range(of: #"\.system\(size:\s*\d+"#, options: .regularExpression) != nil {
                    offences.append("\(file.lastPathComponent):\(line.number) icon or font size")
                }
                // Dimension arguments to the layout modifiers.
                //
                // **`padding` is here now, and its absence was a gap rather than
                // an exemption.** The first version matched only
                // `width|height|minHeight|maxHeight|size:`, so a `.padding(6)`
                // in the shutter's press-fill overlay passed — while the token
                // written for exactly that inset, `Theme.Size.shutterInnerInset`,
                // sat unused in `Theme.swift`. A scan which cannot see a whole
                // category of the rule is not a scan of the rule; it is a scan of
                // the cases its author happened to think of, and it reads exactly
                // like one that is complete.
                let dimension = #"(?:width|height|minHeight|maxHeight|size):\s*(?:Theme\.\w+\.\w+)?\s*([0-9]+)"#
                        + #"|\.padding\(\s*([0-9]+)"#
                guard let regex = try? NSRegularExpression(pattern: dimension),
                      let match = regex.firstMatch(
                          in: code,
                          range: NSRange(code.startIndex..., in: code)
                      ) else { continue }
                // Group 1 is the `size:` form's number, group 2 is the
                // `.padding(` form's. Whichever matched, the other is absent.
                let number = (1...2).lazy
                    .compactMap { group -> String? in
                        guard match.range(at: group).location != NSNotFound else {
                            return nil
                        }
                        let range = Range(match.range(at: group), in: code)
                        return range.map { String(code[$0]) }
                    }
                    .first
                // A token reference is exactly what we want, and so is `0` and `1`:
                // a `VStack(spacing: 0)` and a 1pt divider are literals by nature,
                // which is the exemption `AGENTS.md` §12's author intended — a scan
                // with no exceptions is a scan that gets switched off.
                guard let number, let value = Int(number), value > 1 else { continue }
                offences.append(
                    "\(file.lastPathComponent):\(line.number) hardcoded dimension \(value)"
                )
            }
        }

        #expect(
            offences.isEmpty,
            """
            hardcoded dimensions in a view (AGENTS.md §11). Use a \
            `Theme.Size`, `Theme.Spacing` or `Theme.Radius` member: \
            \(offences.joined(separator: ", "))
            """
        )
    }

    @Test("Every text token passes WCAG AA against the canvas")
    func textTokensAreLegible() throws {
        // **`textTertiary` was 3.51:1 on black and 2.84:1 on a card.** AA for
        // normal text is 4.5:1. It carried real content — "best 500", the retake
        // counts, "Wider is more random" — so this was an accessibility failure,
        // not a decorative one that could be argued about.
        //
        // **The hexes are read out of `Theme.swift`, not copied here.** The first
        // version listed them in the test, which meant the test kept asserting
        // about the values the app used *before* the fix — it passed while the
        // token was wrong and failed after the token was corrected. A test that
        // carries its own copy of the thing it is testing is a test of the copy.
        let theme = try String(
            contentsOf: SourceScan.file(named: "Theme.swift"),
            encoding: .utf8
        )

        func hex(of token: String) throws -> UInt32 {
            let marker = "static let \(token) = SwiftUI.Color(hex: "
            guard let after = theme.components(separatedBy: marker).dropFirst().first
            else {
                throw SourceScanError.sourceNotWhereExpected(URL(fileURLWithPath: "Theme.swift"))
            }
            // **`0x` stripped first.** The first version took
            // `prefix { $0.isHexDigit }` straight off the source, which stops at
            // the `x` and yields `"0"` — so every token measured 1.00:1 against
            // itself and the test reported three failures at a ratio that is
            // arithmetically impossible for white on black.
            let withoutPrefix = after
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "0x", with: "")
            let digits = String(withoutPrefix.prefix { $0.isHexDigit })
            return try #require(
                UInt32(digits, radix: 16),
                "\(token) has no readable hex value"
            )
        }

        var failures: [String] = []
        for token in ["textPrimary", "textSecondary", "textTertiary"] {
            let value = try hex(of: token)
            for (label, background) in [("black", UInt32(0x000000)), ("card", UInt32(0x1C1C1E))] {
                let ratio = Self.contrast(value, against: background)
                if ratio < 4.5 {
                    failures.append(
                        "\(token) \(String(format: "%.2f", ratio)):1 on \(label)"
                    )
                }
            }
        }

        #expect(
            failures.isEmpty,
            """
            these text tokens do not reach WCAG AA (4.5:1) for normal text. \
            Legibility is not negotiable and a third shade of grey is: \
            \(failures.joined(separator: ", "))
            """
        )
    }

    @Test("Only the primary button is a filled white control")
    func filledWhiteIsReservedForThePrimaryButton() throws {
        // **AGENTS.md §11: "White is the verb."** On a black canvas there is no
        // other emphasis available — no hue, no shadow that reads, nothing — so a
        // solid white control is the loudest thing a screen can say, and it says
        // it in exactly one way.
        //
        // Settings' export row was one. It is a `ShareLink` styled as a solid
        // white capsule, on a screen whose actual choices are the window and the
        // album, at the bottom where it was the last thing the eye landed on. It
        // was spending the app's only emphatic gesture on the feature nobody
        // opens twice. Outlined now, and the border keeps it findable — which is
        // what the weight change is at risk of, and why the rule is "not filled"
        // rather than "not visible".
        //
        // **Scoped to `Components.swift`**, which is where `PrimaryButton` lives.
        // The shutter's inner dot also paints white, and it is not a control
        // background — `.fill` rather than `.background`, and it is the inside of
        // a ring the user is looking straight at.
        let offenders = try SourceScan.swiftFiles()
            .filter { $0.lastPathComponent != "Components.swift" }
            .flatMap { file in
                try SourceScan.codeLines(of: file)
                    .filter { $0.code.contains("background(Theme.Color.textPrimary)") }
                    .map { "\($0.number) \($0.code.trimmingCharacters(in: .whitespaces))" }
                    .map { "\(file.lastPathComponent):\($0)" }
            }

        #expect(
            offenders.isEmpty,
            """
            a filled white control outside PrimaryButton. White is the verb \
            (AGENTS.md §11) and there is one verb: \
            \(offenders.joined(separator: ", "))
            Use a stroked outline if the control is secondary.
            """
        )
    }

    /// WCAG 2.x relative-luminance contrast ratio.
    private static func contrast(_ foreground: UInt32, against background: UInt32) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let raw = Double((hex >> shift) & 0xFF) / 255
                return raw <= 0.03928 ? raw / 12.92 : pow((raw + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let a = luminance(foreground)
        let b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test("A primary control grows with its label rather than clipping it")
    func primaryControlsHaveNoFixedHeight() throws {
        // **The measured failure.** A fixed `52pt` against a scaling `.headline`
        // label: screenshots at each accessibility category in turn show nothing
        // wrong through `accessibility-extra-large`, and at
        // `accessibility-extra-extra-large` the "p" of "Capture" is clipped by the
        // capsule's bottom edge — descender on the boundary, zero padding.
        //
        // Asserted on `minHeight` because that is the property that prevents it,
        // and a fixed `height:` is the specific thing that causes it. The scan is
        // for the literal rather than for the concept so that a future button at
        // a different height is caught too — a rule written only for `52` is a
        // rule about one number, not about what the number was for.
        for file in try SourceScan.swiftFiles() {
            for line in try SourceScan.codeLines(of: file) {
                guard let match = line.code.range(
                    of: #"\.frame\(height:\s*(\d+)"#,
                    options: .regularExpression
                ) else { continue }

                // **A hairline is not a pinned height.** `StatsView`'s 1pt
                // divider between history rows is a border, not a control, and
                // 1 is as literal as a border gets. The rule is about heights
                // above the hairline, which is where a growing label meets a
                // frame that refuses to.
                let value = Int(
                    line.code[match].components(separatedBy: ":").last!
                        .trimmingCharacters(in: .whitespaces)
                ) ?? 0
                guard value > 1 else { continue }

                // **`Bool(false)`, not `false`.** A scan reports *every*
                // offending line with its number rather than stopping at the
                // first, which means the expectation is deliberately
                // unsatisfiable — and `#expect(false)` warns that it will
                // always fail. `Bool(false)` is the same value with the
                // compiler's constant folding suppressed, so the scan still
                // reports all of them and the build is warning-free
                // (`AGENTS.md` §12).
                #expect(
                    Bool(false),
                    """
                    \(file.lastPathComponent):\(line.number) pins a height to \(value): \
                    \(line.code.trimmingCharacters(in: .whitespaces))
                    A control's height must grow with its label, or a label at an \
                    accessibility size loses its descenders to its own frame.
                    """
                )
            }
        }
    }

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

            for line in try SourceScan.codeLines(of: file) {
                if isFeature,
                   line.code == "import Photos" || line.code == "import AVFoundation" {
                    offences.append("\(file.lastPathComponent): \(line.code)")
                }
                if isService, line.code == "import SwiftUI" {
                    offences.append("\(file.lastPathComponent): \(line.code)")
                }
            }
        }

        #expect(
            offences.isEmpty,
            "layering violations (AGENTS.md §3): \(offences.joined(separator: ", "))"
        )
    }
}
