import Foundation
import Photos
import Testing

/// Fails the run when the live Photos suite was skipped.
///
/// Swift Testing counts an early-returning test as **passed**. That is how four
/// live tests came to "pass" in one millisecond while asserting nothing, twice
/// over: once behind an environment gate that `xcodebuild` never propagated into
/// the test process, and once because the simulator reports `.authorized` and
/// then silently discards every write.
///
/// The first attempt at this guard inverted the check on an environment variable,
/// which required wiring that variable through the scheme's `TestAction` — two
/// levels of indirection that a mistake in placement disables silently, exactly
/// the failure mode the guard exists to prevent.
///
/// So it does not depend on configuration at all. Whether a live test ran is
/// directly observable, and that is what it asserts.
///
/// Two things follow:
///
/// - Running the whole suite on a **device** passes, because the live tests
///   really do execute.
/// - Running it on a **simulator** fails this one test with an explanation. That
///   is correct and intended: it is telling you the device-only exit criterion
///   for Phase 3 is still outstanding.
@Suite("Phase 3 — live run guard")
struct LivePhotoRunGuardTests {

    @Test("The live Photos suite is not silently skipped")
    func liveTestsWereNotSilentlySkipped() {
        let executed = LivePhotoLibraryTests.runCount

        #expect(
            executed > 0,
            """

            The live Photos suite was skipped, so Phase 3's exit criterion — a \
            real write to a real photo library — is NOT met.

            \(executed) of 4 live tests executed.

            This host cannot persist to a Photos library. The simulator reports \
            .authorized for .addOnly and then discards every write: \
            performChanges completes with success, no change observer fires, and \
            Photos.sqlite never appears. That is a simulator limitation, not a \
            defect in Memoree.

            To satisfy the criterion, run on a physical device and approve the \
            Photos prompt once:

                xcodebuild test -project Memoree.xcodeproj -scheme Memoree \\
                    -destination 'platform=iOS,name=<your device>'

            To run everything else without this guard, filter it out:

                -skip-testing:MemoreeTests/LivePhotoRunGuardTests

            """
        )
    }
}
