import Foundation
import Testing

@testable import Memoree

/// Phase 8 — haptics.
///
/// **The app had none at all.** `grep` for `UIImpactFeedback` found nothing, so
/// the plan's "Haptics | Capture, and the camera switch" had never been started
/// rather than being half-done.
///
/// The tests exist because the *wiring* is the easy thing to get wrong. A haptic
/// is a physical sensation attached to an event, and both halves drift: add a
/// third press path and it buzzes differently, move the switch and the tap fires
/// before the thing it describes, or a retry buzzes twice for one photograph.
/// None of that is visible in a screenshot and none of it is worth a device run.
///
/// ## What one press actually does
///
/// Writing these found that the app's own documentation and its code disagree,
/// which is worth recording before the assertions that depend on it:
///
/// - `shutterPressed`'s doc comment says *"The second press doing the switch is
///   the whole point (ADR-021)"*.
/// - The code switches on the **first** press. One press photographs, sees
///   `captured.count != 2`, and swaps; the second press photographs and enters
///   review.
///
/// So a complete moment is **two presses**, not three, and the first press does
/// two things. The device tests pass and the app works, so the behaviour is
/// right and the *comment* is wrong — recorded here rather than fixed, because
/// changing which press swaps is a product change to ADR-021 and not a Phase 8
/// errand.
@Suite("Phase 8 — haptics")
@MainActor
struct HapticFeedbackTests {

    /// A recorder that accepts everything, spelled as a `MomentRecorder` value.
    ///
    /// The type alias is `@MainActor @Sendable (CommittedCapture) async throws
    /// -> Void`, and an inline closure literal does not satisfy it — Swift treats
    /// a closure literal as non-`Sendable` and refuses the conversion. Naming the
    /// intermediate is the whole fix.
    private static let acceptsEverything: MomentRecorder = { _ in }

    private struct Harness {
        let model: CameraViewModel
        let haptics: InMemoryHapticFeedback
    }

    private func makeHarness() -> Harness {
        let haptics = InMemoryHapticFeedback()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        return Harness(
            model: CameraViewModel(
                service: InMemoryCaptureService(),
                photoLibrary: library,
                haptics: haptics,
                record: Self.acceptsEverything,
                chooseFirstCamera: { .back }
            ),
            haptics: haptics
        )
    }

    // MARK: - One press, one haptic

    @Test("One press buzzes once, even though it also swaps the camera")
    func onePressOneBuzz() async throws {
        // The assertion this phase's design turns on. One press photographs
        // *and* swaps, so a haptic for each would tell the user two things
        // happened when they pressed once — and the second buzz would arrive
        // while the preview was still the old camera, describing something that
        // had not happened yet.
        let harness = makeHarness()
        await harness.model.start()
        await harness.model.shutterPressed()

        #expect(harness.model.livePosition == .front, "the press did swap the camera")
        #expect(harness.haptics.events == [.shutter], "and it buzzed exactly once")
    }

    @Test("The camera switch has no haptic of its own")
    func theSwitchIsSilent() async throws {
        // Stated as its own test because it is the decision most likely to be
        // "fixed" by someone who reads the plan's "Haptics | Capture, and the
        // camera switch" and wires one up without reading why.
        let harness = makeHarness()
        await harness.model.start()
        await harness.model.shutterPressed()
        await harness.model.shutterPressed()
        await harness.model.commit()

        #expect(!harness.haptics.events.contains(.cameraSwitch))
    }

    // MARK: - The whole sequence

    @Test("A completed moment is shutter, shutter, commit")
    func theFullSequence() async throws {
        // The order *is* the test. Haptics communicate sequence, and the same
        // three events in a different order describe a different interaction
        // than the one that happened.
        let harness = makeHarness()
        await harness.model.start()
        await harness.model.shutterPressed()
        await harness.model.shutterPressed()
        #expect(harness.model.phase == .review)

        await harness.model.commit()

        #expect(
            harness.haptics.events == [.shutter, .shutter, .commit],
            "got \(harness.haptics.events)"
        )
    }

    @Test("A reshoot is silent, and the press that follows it is not")
    func reshootIsSilentUntilTheShutter() async throws {
        // The distinction this pins: `reshoot` **reopens** the camera, it does not
        // photograph. Nothing was taken, so nothing should buzz — and the first
        // version of this test asserted the opposite, on the reasonable-sounding
        // grounds that a reshoot is a capture. It is a *setup* for one.
        //
        // Worth its own test because the two are one press apart and a haptic
        // wired to the wrong one would report a photograph the user never took.
        let harness = makeHarness()
        await harness.model.start()
        await harness.model.shutterPressed()
        await harness.model.shutterPressed()
        #expect(harness.model.phase == .review)

        let beforeReshoot = harness.haptics.events.count
        await harness.model.reshoot(.back)

        #expect(harness.haptics.events.count == beforeReshoot,
                "reshoot reopens the camera; it takes no photograph")
        #expect(harness.model.phase == .shooting, "and the user is back at the shutter")

        await harness.model.shutterPressed()
        #expect(harness.haptics.events.count == beforeReshoot + 1,
                "the press that follows it is the one that buzzes")
    }

    // MARK: - Failure

    @Test("Nothing buzzes on a failed commit")
    func failureIsSilent() async throws {
        // A failure buzz would be the phone telling the user they did something
        // wrong, and the commonest failure is a permission they declined an hour
        // ago. The screen's own copy is what should be saying that.
        let haptics = InMemoryHapticFeedback()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.denied)

        let model = CameraViewModel(
            service: InMemoryCaptureService(),
            photoLibrary: library,
            haptics: haptics,
            record: Self.acceptsEverything
        )
        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        #expect(haptics.events.contains(.shutter),
                "the photographs were still taken")
        #expect(!haptics.events.contains(.commit),
                "but nothing succeeded, and nothing said it did")
    }

    @Test("A failed commit does not buzz twice when it is retried")
    func retryDoesNotDoubleBuzz() async throws {
        // `retry()` re-runs the commit, not the shutter. A retry that buzzed
        // again would report a new photograph for a pair that was already
        // written — and they are the same photographs.
        let haptics = InMemoryHapticFeedback()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        // A lock-guarded counter, because the recorder is `@Sendable` and a
        // captured `var` is not. Same shape as `PlaceholderBox`.
        let attempts = AttemptCounter()
        let flaky: MomentRecorder = { _ in
            if attempts.next() == 1 {
                throw StoreError.wrapping(URLError(.timedOut))
            }
        }

        let model = CameraViewModel(
            service: InMemoryCaptureService(),
            photoLibrary: library,
            haptics: haptics,
            record: flaky
        )
        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()
        #expect(!haptics.events.contains(.commit), "the first commit failed")

        await model.retry()
        #expect(haptics.events.filter { $0 == .commit }.count == 1,
                "one success, one buzz")
    }

    // MARK: - The double

    @Test("The recording double is itself silent until asked")
    func theDoubleIsHonest() {
        let haptics = InMemoryHapticFeedback()
        #expect(haptics.isSilent)
        haptics.shutter()
        #expect(!haptics.isSilent)
        #expect(haptics.events == [.shutter])
    }

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }
}
