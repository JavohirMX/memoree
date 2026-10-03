import Foundation
import Testing

@testable import Memoree

/// Whether the repository is readable from the process running these tests.
///
/// `#filePath` is baked in by the compiler and names a path on the build machine,
/// which exists on a simulator and does not exist on hardware — the same
/// property `NoNetworkingTests` and `DesignSystemInvariantTests` depend on.
private let sourceIsReadableOnThisHost = SourceScan.isReadable

/// Structural claims about `CaptureSessionController` that only a device can
/// observe the consequences of.
///
/// ## Why this is a source scan and not a unit test
///
/// The defect this exists for was found by a twenty-moment device gate at 8/20,
/// and it **compiled, linted, and passed every test in the project.** There is
/// no simulator on which `AVCaptureOutput` can be added to a session, so no
/// unit test can observe that reusing one across two sessions makes
/// `canAddOutput` return false forever. The simulator has no camera at all —
/// the same reason `LiveCaptureTests` exists as a separate suite.
///
/// So the claim is checked where it can be: structurally, in the source. That is
/// a weaker instrument than a behavioural test and it is honestly weaker — it
/// would not catch an output attached to the replacement session by some other
/// route. What it does catch is the specific mistake, it catches it on every
/// simulator run rather than once per device run, and it costs nothing.
///
/// The alternative was leaving a known brick-the-camera defect guarded only by
/// a twenty-minute test that runs when someone remembers.
@Suite("Capture session rebuild invariants", .enabled(if: sourceIsReadableOnThisHost))
struct SessionRebuildInvariantTests {

    /// Rebuilding the session must replace **every output**, because an output
    /// belongs to exactly one session for its whole life.
    ///
    /// `rebuildSession` replaced `photoOutput` and reused `videoOutput`. The
    /// frame-signal output therefore stayed attached to the doomed session, so
    /// `canAddOutput` on the replacement returned false — and since nothing ever
    /// replaced the object, every later `configureSession` threw
    /// `frame-signal output rejected` for the life of the process. One dead
    /// capture subsystem became a permanently bricked camera, which is the exact
    /// failure `rebuildSession` exists to end.
    ///
    /// It survived two weeks of device runs because reaching it needed a swap to
    /// fail *and* a rebuild to have already happened. A run with one rebuild
    /// looks perfect.
    ///
    /// The check is for a bare `name =` assignment, deliberately: the old
    /// surviving line was `videoOutput.alwaysDiscardsLateVideoFrames = true`,
    /// which contains `videoOutput` and an `=` and is not a replacement. Matching
    /// on the property name alone would have passed on the defect.
    @Test("Rebuilding the session replaces every output, not just some")
    func rebuildReplacesEveryOutput() throws {
        let file = try SourceScan.file(named: "CaptureSessionController.swift")
        let lines = try SourceScan.codeLines(of: file)

        let body = try Self.body(ofFunction: "rebuildSession", in: lines)

        let replaced = Set(
            body.compactMap { line -> String? in
                let code = line.code
                for output in ["photoOutput", "videoOutput"] {
                    // A statement that *is* the assignment, not one that merely
                    // configures the property: `videoOutput = AVCapture…` yes,
                    // `videoOutput.alwaysDiscards…` no.
                    if code.hasPrefix("\(output) =")
                        || code.hasPrefix("self.\(output) =")
                        || code.contains(" \(output) = ") {
                        return output
                    }
                }
                return nil
            }
        )

        for output in ["photoOutput", "videoOutput"] {
            #expect(
                replaced.contains(output),
                """
                rebuildSession does not replace \(output). \
                An AVCaptureOutput cannot be migrated between sessions, so reusing \
                one makes canAddOutput fail on the replacement for the rest of the \
                process's life. This shipped once already: 8/20 on the device gate.
                """
            )
        }
    }

    /// Every `AVCaptureOutput` stored on the controller must be replaceable.
    ///
    /// The same defect one level up. `videoOutput` was declared `let`, which is
    /// what made replacing it impossible in the first place — the compiler could
    /// have refused the fix. A `let` output is only correct if nothing ever
    /// needs to replace it, and `rebuildSession` replaces the session.
    ///
    /// Scoped to outputs by name rather than by type, because the declarations
    /// are `private` and a test cannot ask the compiler for their types.
    @Test("No output on the controller is immutable")
    func outputsAreNotImmutable() throws {
        let file = try SourceScan.file(named: "CaptureSessionController.swift")
        let lines = try SourceScan.codeLines(of: file)

        let immutable = lines.compactMap { line -> String? in
            ["photoOutput", "videoOutput"]
                .first { line.code.hasPrefix("private let \($0)") }
                .map { _ in line.full }
        }

        #expect(
            immutable.isEmpty,
            """
            an AVCaptureOutput on CaptureSessionController is declared `let`, so \
            rebuildSession cannot replace it: \(immutable.joined(separator: ", "))
            """
        )
    }

    // MARK: - Helper

    /// The lines of one function's body, found by brace balance.
    ///
    /// **Brace counting rather than a fixed window**, because a window silently
    /// changes meaning whenever the function grows — and this file has grown
    /// several times today. Counting from the declaration to the brace that
    /// returns the nesting to zero is the only version that keeps meaning.
    private static func body(
        ofFunction name: String,
        in lines: [SourceScan.Line]
    ) throws -> [SourceScan.Line] {
        let start = try #require(
            lines.firstIndex { $0.code.contains("func \(name)") },
            "\(name) was not found in CaptureSessionController.swift"
        )

        var depth = 0
        var body: [SourceScan.Line] = []
        for line in lines[start...] {
            body.append(line)
            depth += line.code.filter { $0 == "{" }.count
            depth -= line.code.filter { $0 == "}" }.count
            if depth <= 0 && body.count > 1 { break }
        }

        return body
    }
}
