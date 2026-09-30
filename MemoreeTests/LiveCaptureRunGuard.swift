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

    @Test("The live camera suite is not silently skipped")
    func liveTestsWereNotSilentlySkipped() {
        let executed = LiveCaptureTests.runCount

        #expect(
            executed > 0,
            """

            The live camera suite was skipped, so Phase 4's exit criterion — \
            20 reliable captures on hardware — is NOT met.

            \(executed) of 6 live tests executed.

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
