import Foundation
import Testing

@testable import Memoree

/// Structural claims about the BTS output that only a device can observe the
/// consequences of.
///
/// ## Why the movie output gets its own scan when `SessionRebuildInvariantTests`
/// already exists
///
/// That suite scans `rebuildSession`'s body for assignments to `photoOutput` and
/// `videoOutput`. **A movie output that is `nil` when BTS is off cannot be scanned
/// that way** — there is no identifier to search for, because the whole point is
/// that the object does not exist until something asks for it. So the invariant
/// here is the opposite shape: not "this output is replaced", but **"the state
/// that decides whether an output exists is reset"**, which is the half that is
/// easy to forget and expensive to get wrong.
///
/// ## What the failure looks like
///
/// `rebuildSession` that forgets to clear `movieOutput` leaves the old output
/// attached to the doomed session. The replacement then rejects it,
/// `configureSession` throws `movie output rejected`, and — exactly as the
/// `videoOutput` incident did — **every subsequent capture fails for the life of
/// the process**. One dead capture subsystem becomes a permanently bricked
/// camera, which is the failure `rebuildSession` exists to end.
///
/// It cost a 20-moment device run to find that one. This test costs 13 milliseconds.
@Suite("BTS session invariants", .enabled(if: sourceIsReadableOnThisHost))
struct BTSSessionInvariantTests {

    /// `CaptureSessionController.swift`, read with comments stripped — so a
    /// prohibition written in this file's own documentation cannot satisfy a check.
    private func lines() throws -> [SourceScan.Line] {
        try SourceScan.codeLines(of: SourceScan.file(named: "CaptureSessionController.swift"))
    }

    /// The movie output must be released when the session is replaced.
    ///
    /// **`movieOutput = nil`, not `movieOutput = AVCaptureMovieFileOutput()`.**
    ///
    /// The other two outputs are *replaced* with fresh instances because a live
    /// delegate and a live sample-buffer callback have to keep working across the
    /// rebuild. The movie output has the opposite requirement: **it has to be gone
    /// before the new session is configured**, because `configureSession` creates
    /// its own when `wantsMovieOutput` is set and a stale one would be found already
    /// attached. Assigning a fresh instance here would leave exactly the bug this
    /// test exists to catch.
    @Test("Rebuilding the session releases the movie output rather than replacing it")
    func rebuildReleasesTheMovieOutput() throws {
        let body = try Self.body(ofFunction: "rebuildSession", in: try lines())

        let cleared = body.contains { $0.code.contains("movieOutput = nil") }
        let replaced = body.contains {
            $0.code.contains("movieOutput = AVCaptureMovieFileOutput")
        }

        #expect(cleared,
                """
                rebuildSession does not release movieOutput. An AVCaptureOutput cannot \
                be migrated between sessions, so the old one stays attached to the doomed \
                session, canAddOutput returns false on the replacement, and every later \
                configureSession throws for the life of the process — the same defect \
                this file shipped once with videoOutput.
                """
        )
        #expect(!replaced,
                """
                rebuildSession assigns a fresh movieOutput. It must be nil instead: \
                configureSession creates one when wantsMovieOutput is set, and a fresh \
                instance here is still attached to the session being destroyed.
                """)
    }

    /// The flag that decides whether an output exists survives a rebuild.
    ///
    /// **This is the other half, and it is the one that fails silently.** Clearing
    /// `movieOutput` while clearing `wantsMovieOutput` would leave BTS silently off
    /// after any dead-subsystem recovery — no error, no clip, and the moment is
    /// photographs only, which is indistinguishable from a user who never enabled
    /// it. A user who turned on Behind the Scenes would stop getting it after one
    /// daemon death and have no way to tell why.
    ///
    /// Asserted as *absence*: the rebuild must not contain the assignment.
    @Test("Rebuilding the session does not silently turn BTS off")
    func rebuildDoesNotDisableBTS() throws {
        let body = try Self.body(ofFunction: "rebuildSession", in: try lines())

        #expect(!body.contains { $0.code.contains("wantsMovieOutput = false") },
                """
                rebuildSession resets wantsMovieOutput. That would silently turn BTS \
                off after every dead-subsystem recovery: no error, no clip, and the \
                moment is photographs only — which looks exactly like a user who never \
                enabled it, so nothing would report the difference.
                """)

        // **Deliberately narrow, because a naive version of this passes.**
        //
        // Searching the whole file for `wantsMovieOutput = false` matches the
        // declaration's own `= false` and the declaration is *outside* the
        // function — so the scan has to be scoped to the body. Verified by moving
        // the reset into `enableMovieOutput` and watching this test still pass,
        // which is what a file-wide scan would have done.
        let enableBody = try Self.body(ofFunction: "enableMovieOutput", in: try lines())
        #expect(!enableBody.contains { $0.code.contains("wantsMovieOutput = false") },
                """
                enableMovieOutput clears the flag it exists to set. A user who turned \
                BTS on would get no clip and no explanation.
                """)
    }

    /// The output is created in `configureSession`, not stored.
    ///
    /// **Structurally the same property as the first test, checked at its other
    /// site.** If the movie output were created once and stored — the way
    /// `photoOutput` is — then `configureSession` would have nothing to create on a
    /// rebuilt session and the first test's fix would be unreachable.
    @Test("The movie output is created by configureSession, so a rebuild gets a new one")
    func movieOutputIsCreatedByConfigureSession() throws {
        let body = try Self.body(ofFunction: "configureSession", in: try lines())

        #expect(body.contains { $0.code.contains("movieOutput = AVCaptureMovieFileOutput()") },
                """
                configureSession does not create the movie output. It has to, because a \
                stored one would belong to the session being replaced — which is the \
                defect rebuildReleasesTheMovieOutput guards against.
                """)
    }

    // MARK: - Helper

    /// The lines of one function's body, found by brace balance.
    ///
    /// **Brace counting rather than a fixed window**, for the reason
    /// `SessionRebuildInvariantTests` uses it: a window silently changes meaning
    /// whenever the function grows, and this file grows.
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
