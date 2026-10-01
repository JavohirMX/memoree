import Foundation
import Testing

@testable import Memoree

/// Whether the repository is reachable from the process running these tests.
///
/// True on a simulator, where `#filePath` names a real directory on the build
/// machine. False on hardware, where it names a path the device has never heard
/// of. See the suite's documentation for why that is a property of the check and
/// not a bug in it.
private let sourceIsReadableOnThisHost: Bool = {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
}()

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
        "Data(contentsOf:",
    ]

    /// Deliberately **absent** from the list above: `CLLocationManager`.
    ///
    /// It was in the first draft, because there is genuinely no `CLLocationManager`
    /// in this app. But a class called "no networking" that also carries
    /// opinions about location is a class whose name lies, and location is not
    /// declined on privacy grounds here — it is deferred to Phase 10 (ADR-016).
    /// If that ever changes, it wants its own test and its own reasoning.

    private static var appSourceRoot: URL {
        URL(fileURLWithPath: #filePath)      // MemoreeTests/NoNetworkingTests.swift
            .deletingLastPathComponent()     // MemoreeTests
            .deletingLastPathComponent()     // repo root
            .appendingPathComponent("Memoree", isDirectory: true)
    }

    /// Every Swift file in the app target, plus the plist and privacy manifest.
    private static func sourceFiles() throws -> [URL] {
        let root = appSourceRoot
        try #require(
            FileManager.default.fileExists(atPath: root.path),
            "the app source is not where this test expects it: \(root.path)"
        )
        return try FileManager.default
            .subpathsOfDirectory(atPath: root.path)
            .filter {
                ["swift", "plist", "xcprivacy"].contains(
                    URL(fileURLWithPath: $0).pathExtension
                )
            }
            .map { root.appendingPathComponent($0) }
    }

    private static func swiftFiles() throws -> [URL] {
        try sourceFiles().filter { $0.pathExtension == "swift" }
    }

    /// Whether a line names a networking type.
    ///
    /// One function, so the scan and the two tests that prove the scan is not
    /// vacuous cannot disagree about what it means. A test suite that checks its
    /// own matcher with a re-implementation of it is two matchers.
    /// Which networking name a line contains, if any.
    ///
    /// Returns the *symbol* rather than a `Bool`, so a failure can say what it
    /// matched. An earlier version returned `Bool` and reported the offending
    /// line, which sounds sufficient and is not: a clean file will produce a
    /// report that names lines without saying which of the seventeen symbols
    /// fired, so the reader is left reimplementing the matcher by hand to find
    /// out. The symbol is the whole diagnosis.
    static func networkingName(in line: String) -> String? {
        if let pattern = forbiddenPatterns.first(where: line.contains) {
            return pattern
        }
        return forbiddenTypes.first {
            line.range(of: "\\b\($0)\\b", options: .regularExpression) != nil
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
        ]
        for line in mustBeCaught {
            #expect(Self.namesNetworkingType(line), "the scan would miss: \(line)")
        }
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
}
