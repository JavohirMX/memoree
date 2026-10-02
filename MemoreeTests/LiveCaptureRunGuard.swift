import Foundation
import Testing

/// Fails the run when the live camera suite was skipped.
///
/// Swift Testing counts an early-returning test as **passed**. A green run that
/// verified nothing is the worst possible outcome for the phase whose entire
/// risk is "does this work on hardware" — so this makes that outcome loud.
///
/// Deliberately independent of configuration, for the same reason as
/// `LivePhotoRunGuardTests`: an environment-variable gate required wiring
/// through the scheme's `TestAction`, and a misplaced element would have
/// disabled the very check meant to prevent exactly that. Whether a live test
/// ran is directly observable, so that is what this asserts.
///
/// Two consequences, both intended:
///
/// - On a **device**, the whole suite passes, because the live tests execute.
/// - On a **simulator**, this one test fails with an explanation. That is
///   correct: Phase 4's exit criterion is still outstanding.
@Suite("Phase 4 — live capture run guard")
struct LiveCaptureRunGuardTests {

    @Test("The live suite's expected count matches the tests it actually contains")
    func expectedCountMatchesTheSource() throws {
        // **A literal count rots, and this one rotted immediately.** The failure
        // message used to interpolate a bare `6`; adding the lens survey made that
        // wrong on the same day. Replacing it with `expectedCount` on the suite
        // just moved the problem — the first value written there was `7`, and
        // there are nine `@Test`s in that file, because two of them are easy to
        // forget when counting by eye.
        //
        // So the count is **measured from the source** instead. This runs
        // everywhere, including on a simulator where every live test skips and
        // `runCount` is 0, which is exactly why it belongs in its own test: the
        // other guard can only be exercised on a device, and by then a stale
        // count has already been printed as though it were information.
        //
        // Counting `@Test` in the source is an approximation — a `@Test` inside a
        // disabled branch or a comment would inflate it — and `SourceScan`
        // strips comments, so only a real declaration can match.
        let declarations = try SourceScan.codeLines(
            of: SourceScan.testFile(named: "LiveCaptureTests.swift")
        )
        .filter { $0.code.hasPrefix("@Test") }

        #expect(
            declarations.count == LiveCaptureTests.expectedCount,
            """
            LiveCaptureTests.expectedCount is \(LiveCaptureTests.expectedCount) but the \
            file contains \(declarations.count) @Test declarations, at lines \
            \(declarations.map(\.number).map(String.init).joined(separator: ", ")).
            The guard prints this number, so a wrong one is worse than none — \
            it looks like information. Update expectedCount.
            """
        )
    }

    @Test("The live camera suite is not silently skipped")
    func liveTestsWereNotSilentlySkipped() {
        let executed = LiveCaptureTests.runCount

        #expect(
            executed > 0,
            """

            The live camera suite was skipped, so Phase 4's exit criterion — \
            20 reliable captures on hardware — is NOT met.

            \(executed) of \(LiveCaptureTests.expectedCount) live tests executed.

            This host has no camera. The simulator returns nil from \
            AVCaptureDevice.default, has no capture session, and reports \
            isMultiCamSupported as permanently false. No assertion about \
            mirroring, 3:4 geometry or sequential-capture reliability can be \
            made there.

            To satisfy the criterion, run on a physical device:

                xcodebuild test -project Memoree.xcodeproj -scheme Memoree \\
                    -destination 'platform=iOS,name=<your device>' \\
                    -only-testing:MemoreeTests/LiveCaptureTests

            Expect 40 photographs captured in memory and discarded, plus two \
            written to the camera roll by the write-path test. Nothing is \
            deleted — Memoree never removes anything from the user's library \
            (ADR-008).

            To run everything else without this guard:

                -skip-testing:MemoreeTests/LiveCaptureRunGuardTests

            """
        )
    }
}
