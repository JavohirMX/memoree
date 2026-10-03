import Foundation
import Testing

@testable import Memoree

/// Whether the repository is reachable from the process running these tests.
///
/// True on a simulator, where `#filePath` names a real directory on the build
/// machine. False on hardware, where it names a path the device has never heard
/// of. See the suite's documentation for why that is a property of the check and
/// not a bug in it.

/// The "no server" commitment, asserted rather than intended.
///
/// TRD §13 lists this as a verification strategy and AGENTS.md §10 says the
/// invariant "should be asserted by a test, not merely intended". It was not.
/// Nothing in the suite ever checked, so "no network" was a property of a code
/// review that had happened once — and a code review is not a property that
/// survives contact with a dependency, a snippet copied from a Stack Overflow
/// answer, or a well-meaning `URLSession.shared.data(from:)` added for a
/// thumbnail that does not need one.
///
/// ## Why it scans source rather than linking
///
/// The obvious approach is the wrong one. Linking `Network.framework` and
/// asserting its symbols are absent proves nothing: Swift and Foundation both
/// pull networking in transitively, so the symbol is present whether or not the
/// app uses it, and the test would pass vacuously or fail for reasons that have
/// nothing to do with Memoree.
///
/// So this reads the app target's own source. That is narrower than a binary
/// audit and cannot catch a request smuggled in through a C library, but it is
/// exact about what it claims: **no file in `Memoree/` names a networking
/// type.** The `nm -u` audit in Phase 11 remains the backstop for the rest.
///
/// ## Why the suite is disabled on a device
///
/// `#filePath` is resolved by the *compiler* and baked into the binary as a
/// string, so it names a path on the machine that built the app. That path
/// exists on a simulator and does not exist on hardware, and the first device
/// run failed all four tests with "the app source is not where this test
/// expects it".
///
/// This is a real limitation, stated rather than hidden. A source scan cannot be
/// performed on-device, because the source is not there. The device-side
/// complement is the Phase 11 binary audit.
///
/// `.enabled(if:)` rather than an early `return`, deliberately: Swift Testing
/// counts a returned test as **passed**, which is precisely how four live tests
/// in this project "passed" in a millisecond having asserted nothing, twice.
/// A disabled suite is reported as not run.
@Suite("No networking", .enabled(if: sourceIsReadableOnThisHost))
struct NoNetworkingTests {

    /// Type names, matched on **word boundaries**.
    ///
    /// The boundaries are the whole reason this suite is written the way it is,
    /// and they were added because the first version failed on its own
    /// protection: it flagged `options.isNetworkAccessAllowed = false` in
    /// `PhotoKitLibrary`, on the grounds that the string "Network" appears.
    ///
    /// That line is the app *refusing* a network request — PhotoKit is being
    /// told to serve thumbnails from on-disk only, not from iCloud. A substring
    /// scan cannot tell a prohibition from a violation, and a test that fires on
    /// both teaches people to delete the line that is keeping them off the
    /// network.
    private static let forbiddenTypes = [
        "URLSession",
        "URLSessionConfiguration",
        "URLRequest",
        "URLProtocol",
        "URLProtocolClient",
        "NSURLConnection",
        "NSURLSession",
        "NWPathMonitor",
        "Network",
        "CFNetwork",
        "WKWebView",
        "WKWebViewConfiguration",
        "ASWebAuthenticationSession",
        "SFSafariViewController",
        "getaddrinfo",
        "CFStreamCreatePairWithSocketToHost",
        "NSNetService",
    ]

    /// Substrings that cannot be matched on a word boundary because they are not
    /// bare identifiers.
    private static let forbiddenPatterns = [
        "import Network",
        // **`Data(contentsOf:)` is here because it can reach the network, not
        // because it is a networking type** — it is a file read that silently
        // becomes an HTTP fetch when handed an `http` URL. Local reads use
        // `FileManager.contents(atPath:)`, which takes a path and therefore has no
        // network-shaped failure mode at all. Do not "simplify" it back to this;
        // the substitution is the point, and it is what lets the symbol stay banned
        // outright instead of carrying an exemption list.
        //
        // The one place in the app that used this was `LiveBTSRecorder.trim`,
        // which read back a temporary file and handed the bytes to the camera
        // layer. `trim` now returns `Data`, so the read never leaves `Services/`
        // at all (`AGENTS.md` §3) — see `BTSRecorder.trim`.
        "Data(contentsOf:",
    ]

    /// Deliberately **absent** from the list above: `CLLocationManager`.
    ///
    /// It was in the first draft, because there is genuinely no `CLLocationManager`
    /// in this app. But a class called "no networking" that also carries
    /// opinions about location is a class whose name lies, and location is not
    /// declined on privacy grounds here — it is deferred to Phase 10 (ADR-016).
    /// If that ever changes, it wants its own test and its own reasoning.

    private static var appSourceRoot: URL { SourceScan.appRoot }

    /// Every Swift file in the app target, plus the plist and privacy manifest.
    private static func sourceFiles() throws -> [URL] {
        try SourceScan.files(extensions: ["swift", "plist", "xcprivacy"])
    }

    private static func swiftFiles() throws -> [URL] {
        try sourceFiles().filter { $0.pathExtension == "swift" }
    }

    /// Whether a line names a networking type.
    ///
    /// Which networking name a line contains, if any.
    ///
    /// Returns the *symbol* rather than a `Bool`, so a failure can say what it
    /// matched. An earlier version returned `Bool` and reported the offending
    /// line, which sounds sufficient and is not: a clean file will produce a
    /// report that names lines without saying which of the seventeen symbols
    /// fired, so the reader is left reimplementing the matcher by hand to find
    /// out. The symbol is the whole diagnosis.
    static func networkingName(in line: String) -> String? {
        let code = line.strippingTrailingComment()
        if let pattern = forbiddenPatterns.first(where: code.contains) {
            return pattern
        }
        return forbiddenTypes.first {
            code.range(of: "\\b\($0)\\b", options: .regularExpression) != nil
        }
    }

    static func namesNetworkingType(_ line: String) -> Bool {
        networkingName(in: line) != nil
    }

    // MARK: - The scan

    @Test("No file in the app target names a networking type")
    func noNetworkingTypesInTheAppTarget() throws {
        let files = try Self.sourceFiles()
        #expect(!files.isEmpty, "the scan found no source files, so it proved nothing")

        var offences: [String] = []
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() {
                let text = String(line)
                guard let symbol = Self.networkingName(in: text) else { continue }
                offences.append(
                    "\(file.lastPathComponent):\(number + 1): \(symbol) — \(text.trimmed)"
                )
            }
        }

        #expect(
            offences.isEmpty,
            """
            networking symbols in the app target (AGENTS.md §2.1, ADR-001): \
            \(offences.joined(separator: "\n  "))
            """
        )
    }

    @Test("The scan would notice if a real call appeared")
    func theScanIsNotVacuous() throws {
        // A test that cannot fail is not a test. Two lines that the rules above
        // must catch, checked against the same matching the scan uses.
        //
        // Both are fake code, in the test target, which the scan does not read —
        // so this is the only place in the repository where these names appear
        // as anything other than a list of prohibitions.
        let mustBeCaught = [
            "let session = URLSession.shared",
            "import Network",
            "monitor = NWPathMonitor()",
            // The line that brought this suite a false positive. If the rule is ever
            // relaxed to "warn instead of fail", this is the line that would go
            // quiet, so it is asserted rather than assumed.
            "let bytes = try Data(contentsOf: someURL)",
        ]
        for line in mustBeCaught {
            #expect(Self.namesNetworkingType(line), "the scan would miss: \(line)")
        }
    }

    @Test("The local-file read this app does use is not caught")
    func localFileReadIsNotCaught() throws {
        // The positive form of the rule above, and the reason `LiveBTSRecorder`
        // reads its trimmed clip with `FileManager.contents(atPath:)` rather than
        // `Data(contentsOf:)`: a substituted symbol the guard cannot see is a guard
        // that has been defeated rather than satisfied. This asserts the two
        // spellings differ, and that the one this app uses is the one allowed.
        #expect(!Self.namesNetworkingType("FileManager.default.contents(atPath: url.path)"))
        #expect(Self.namesNetworkingType("let bytes = try Data(contentsOf: url)"))
    }

    @Test("Setting a network flag to false is not a violation")
    func prohibitionIsNotAViolation() throws {
        // The failure that shaped this suite. Both of these lines are in
        // `PhotoKitLibrary` and both are the app refusing a network request.
        let mustNotBeCaught = [
            "options.isNetworkAccessAllowed = false",
            "// there is no CLLocationManager in the app",
        ]
        for line in mustNotBeCaught {
            #expect(
                !Self.namesNetworkingType(line),
                "the scan reads a prohibition as a violation: \(line)"
            )
        }
    }

    @Test("A comment naming a forbidden symbol is not a violation")
    func commentIsNotCode() throws {
        // Comments are stripped, and the reason is above in
        // `strippingTrailingComment`: a guard that fires on prose gets worked
        // around by deleting the prose.
        #expect(!Self.namesNetworkingType(
            "// use FileManager.contents(atPath:), not Data(contentsOf:)"
        ))
        #expect(!Self.namesNetworkingType("/// Data(contentsOf: is banned"))
    }

    @Test("Stripping a comment does not hide code after it")
    func strippingCommentsDoesNotBlindTheScan() throws {
        // The failure mode a naive `components(separatedBy: "//")[0]` would have:
        // a `//` inside a string literal truncates the line, and anything the
        // author put after the literal goes unexamined.
        let line = #"let path = "a/b"; let s = URLSession.shared"#
        #expect(Self.namesNetworkingType(line),
                "a URL after a path string was not seen — the scan is blind past a quoted slash")

        // The ordinary case still works.
        #expect(Self.networkingName(in: "let x = 1 // and a comment") == nil)
    }

    // MARK: - The positive form

    @Test("Every Photos read pins itself to on-disk only")
    func photoReadsAreLocalOnly() throws {
        // The absence of a symbol is weak evidence. This is the strong version,
        // and it is the one that would actually catch a regression: if
        // `isNetworkAccessAllowed` were ever flipped to `true`, the archive
        // would start silently pulling thumbnails from iCloud and nothing in
        // this file would notice — no `URLSession` appears, no forbidden type is
        // named, the app would simply begin making requests.
        //
        // ADR-007 says thumbnails stream from Photos. The user's photographs are
        // already on the device, so a request here is pure waste *and* a
        // transfer of their library contents to Apple's servers (ADR-001).
        let library = try #require(
            Self.swiftFiles().first { $0.lastPathComponent == "PhotoKitLibrary.swift" },
            "PhotoKitLibrary.swift was not found by the scan"
        )
        let contents = try String(contentsOf: library, encoding: .utf8)

        let assignments = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains("isNetworkAccessAllowed") }
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Every mention must set it to false. The flag is never read from a
        // variable, so a bare `options.isNetworkAccessAllowed` with no
        // assignment would also trip this.
        #expect(!assignments.isEmpty, "the flag is no longer used; re-verify the read path")
        for line in assignments {
            #expect(
                line.contains("= false"),
                "a Photos read is allowed to hit the network: \(line)"
            )
        }
    }

    // MARK: - The manifests

    @Test("The Info.plist registers no URL scheme and no exception domains")
    func infoPlistRegistersNoSchemes() throws {
        let plist = try #require(
            Self.sourceFiles().first { $0.lastPathComponent == "Info.plist" },
            "Info.plist was not found by the scan"
        )
        let contents = try String(contentsOf: plist, encoding: .utf8)

        // A custom scheme is how a "local" app quietly becomes one that can be
        // opened by a link, and the associated-domains list is where a network
        // entitlement appears. Neither may be present.
        #expect(!contents.contains("CFBundleURLTypes"))
        #expect(!contents.contains("com.apple.developer.associated-domains"))
        #expect(!contents.contains("NSAppTransportSecurity"))
    }

    @Test("The privacy manifest declares no tracking and collects nothing")
    func privacyManifestIsHonest() throws {
        let manifest = try #require(
            Self.sourceFiles().first { $0.lastPathComponent == "PrivacyInfo.xcprivacy" },
            "PrivacyInfo.xcprivacy was not found by the scan"
        )
        let contents = try String(contentsOf: manifest, encoding: .utf8)

        #expect(contents.contains("NSPrivacyTracking"))
        #expect(!contents.contains("<true/>"), "nothing in this app tracks anyone (ADR-001)")
    }
}

// MARK: - Helpers

private extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }

    /// The line with any `//` comment removed.
    ///
    /// ## Why the scan has to strip comments at all
    ///
    /// Because a guard that fires on prose trains people to work around the
    /// guard. The first version did exactly that: documenting *why* `LiveBTSRecorder`
    /// reads its trimmed clip with `FileManager.contents(atPath:)` — a note whose
    /// entire job is to name `Data(contentsOf:)` — failed the suite on its own
    /// comment. The obvious "fix" would have been to reword the comment until the
    /// scan stopped firing, which deletes the explanation and leaves the next
    /// reader to rediscover the rule from a prohibition with no reasoning.
    ///
    /// **Comment text is not code.** A `URLSession` named in a comment is not a
    /// request, and stripping the comment makes the prohibition mean what it says.
    ///
    /// ## String literals are respected, because `//` appears in them
    ///
    /// A path or a URL inside a string would otherwise be truncated at the second
    /// slash and the rest of the line — which could contain code — would go
    /// unexamined. Tracking quote state is the difference between removing a
    /// comment and removing the tail of a line that is still code.
    func strippingTrailingComment() -> String {
        var inString = false
        var previousWasEscape = false
        var characters = Array(self)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" && !previousWasEscape { inString.toggle() }
            if !inString, character == "/", index + 1 < characters.count,
               characters[index + 1] == "/" {
                characters.removeSubrange(index...)
                break
            }
            previousWasEscape = character == "\\" && !previousWasEscape
            if character != "\\" { previousWasEscape = false }
            index += 1
        }
        return String(characters)
    }
}
