import Foundation
import Testing

/// Locates the app target's source, for the suites that scan it.
///
/// Three suites need this — no-networking, the design-system invariants, and
/// anything that follows — and each one used to carry its own copy of the
/// `#filePath` walk. Three copies of a path derivation is three places to fix
/// when a file moves, and the copy that gets missed is the one that then scans
/// the wrong directory and passes vacuously, which is the failure mode these
/// suites exist to prevent.
///
/// `internal` rather than `fileprivate` and not a `@Suite`: this is a
/// mechanism, not a test, and a struct with no tests would be reported as an
/// empty suite.
enum SourceScan {

    /// The repository's `Memoree/` directory.
    ///
    /// Derived from `#filePath`, which the **compiler** resolves and bakes into
    /// the binary as a string. So it names a path on the machine that built the
    /// app: it exists on a simulator and does not exist on hardware, which is why
    /// every suite that uses this is `.enabled(if:)` on the simulator rather
    /// than returning early. A returned test is reported as *passed* by Swift
    /// Testing.
    static var appRoot: URL {
        URL(fileURLWithPath: #filePath)      // MemoreeTests/SourceScan.swift
            .deletingLastPathComponent()     // MemoreeTests
            .deletingLastPathComponent()     // repo root
            .appendingPathComponent("Memoree", isDirectory: true)
    }

    /// Whether the source can be read from this host at all.
    static var isReadable: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Every Swift file in the app target.
    static func swiftFiles() throws -> [URL] {
        try files(matching: { $0.hasSuffix(".swift") })
    }

    /// Every Swift file in the test target.
    ///
    /// **Added for the live suite's count check**, which needs to read
    /// `LiveCaptureTests.swift` — and `swiftFiles()` could not, because it is
    /// scoped to `Memoree/` deliberately: every existing caller is asserting
    /// something about *production* code, and quietly widening that root would
    /// have let app-only invariants start passing by scanning tests instead.
    ///
    /// A second named root is the honest shape. The alternative — scanning
    /// `MemoreeTests/` from the design-system invariants — would have made all of
    /// them vacuous.
    static func testFiles() throws -> [URL] {
        let root = appRoot.deletingLastPathComponent()
            .appendingPathComponent("MemoreeTests", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw SourceScanError.sourceNotWhereExpected(root)
        }
        return try FileManager.default
            .subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
            .map { root.appendingPathComponent($0) }
    }

    /// One file in the test target, by name.
    static func testFile(named name: String) throws -> URL {
        try #require(
            try testFiles().first { $0.lastPathComponent == name },
            "\(name) was not found in MemoreeTests/"
        )
    }

    /// Files in the app target with any of `extensions`.
    static func files(extensions: Set<String>) throws -> [URL] {
        try files { extensions.contains(URL(fileURLWithPath: $0).pathExtension) }
    }

    /// Every path under the app root that `matches` accepts.
    static func files(matching: (String) -> Bool) throws -> [URL] {
        let root = appRoot
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw SourceScanError.sourceNotWhereExpected(root)
        }
        return try FileManager.default
            .subpathsOfDirectory(atPath: root.path)
            .filter(matching)
            .map { root.appendingPathComponent($0) }
    }

    /// One file, by name.
    static func file(named name: String) throws -> URL {
        try #require(
            try swiftFiles().first { $0.lastPathComponent == name },
            "\(name) was not found by the scan"
        )
    }

    /// One line of a source file, with the code separated from the comment.
    ///
    /// A struct rather than a tuple because three members is past the point where
    /// a tuple reads as a value, and because the accessors name what they are.
    struct Line {
        /// 1-based, so a failure report matches what an editor shows.
        let number: Int
        /// The line with any trailing `//` comment removed.
        let code: String
        /// The line as written, for a failure report that quotes the source.
        let full: String
    }

    /// A file's lines, with the code separated from the comment.
    ///
    /// Returning both is what lets a scanner ignore prose. Every suite here has a
    /// rule that its *own documentation* violates — `Theme.swift` says "there is
    /// no `colorScheme` branch", `NoNetworkingTests` lists `URLSession` seventeen
    /// times, and that file's comment mentions `CLLocationManager`. A scanner
    /// that cannot tell a prohibition from a violation teaches people to delete
    /// the comment that documents the rule, and the rule goes with it.
    static func codeLines(of file: URL) throws -> [Line] {
        let contents = try String(contentsOf: file, encoding: .utf8)
        return contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, raw in
                let full = String(raw)
                let code = full
                    .split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespaces)
                guard let code, !code.isEmpty else { return nil }
                return Line(number: index + 1, code: code, full: full)
            }
    }
}

enum SourceScanError: Error, CustomStringConvertible {
    case sourceNotWhereExpected(URL)

    var description: String {
        switch self {
        case .sourceNotWhereExpected(let url):
            return """
                the app source is not where this test expects it: \(url.path)

                The scan is `.enabled(if:)` on the simulator, so reaching this on a \
                device means the guard is wrong rather than the path. A suite that \
                returns early here would be reported as *passed* by Swift Testing.
                """
        }
    }
}
