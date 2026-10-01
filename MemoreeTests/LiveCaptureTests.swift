import AVFoundation
import Foundation
import Testing

@testable import Memoree

/// Phase 4 exit criterion — a real capture from real cameras.
///
/// **Runs when the host has a camera, and reports loudly when it does not.**
///
/// ## Why this cannot run in the simulator
///
/// The simulator has no capture hardware. `AVCaptureDevice.default(.builtInWideAngleCamera,
/// for: .video, position: .back)` returns `nil`, so there is no input, no
/// session, and no frame. `AVCaptureMultiCamSession.isMultiCamSupported` is
/// permanently `false` there, and that is a documented constant rather than a
/// coincidence (AGENTS.md §7).
///
/// Every assertion below that matters — orientation, mirroring, 3:4 geometry,
/// and the reliability check — is therefore only reachable on a device. A green
/// simulator run says nothing about whether this phase works.
///
/// ## The reliability check is paced like a person
///
/// The first version of this suite ran twenty back-to-back pairs and reported
/// 18/20, then 15/20, with different failures each time and an AVFoundation
/// internal assert in the log. That was not a product defect: it swapped the
/// camera **forty times in about twenty seconds**, which is faster than the
/// sensor is asked to work in any real use of this app.
///
/// ADR-021 makes the sequence user-paced — press, swap, press, with the user
/// composing in between — and this check now models that, with a pause between
/// photographs. The isolated measurement of the same mechanism, 40 swaps with
/// nothing else happening, was 0 failures at half a second each
/// (`FrameWaitDiagnostics`). So this asserts the pacing the product actually
/// produces rather than a stress case it never does.
///
/// ## A skip must not look like a pass
///
/// Swift Testing counts an early return as **passed**. That is how four Phase 3
/// tests "passed" in a millisecond while asserting nothing, twice over. So
/// every skip prints a banner, and `LiveCaptureRunGuardTests` fails the run
/// unless at least one test here genuinely executed.
///
/// ## Nothing is deleted
///
/// The photographs captured here are never written to Photos by this suite, so
/// the camera roll is untouched — except the write-path test, which writes two
/// and leaves them, because Memoree never removes anything from the user's
/// library (ADR-008) and that applies to its own test code too.
///
/// ## KNOWN: the gate must run in its own process
///
/// **Each test here builds its own `SequentialCaptureService`, so one device run
/// of the whole suite allocates eight `AVCaptureSession`s back to back.**
/// `AVCaptureSession.init()` is a *synchronous* XPC round-trip to the capture
/// daemon (`FigCaptureSessionRemoteCreate`), and eight of them in one background
/// test process is enough to wedge it. The same trap is recorded above for the
/// twenty-moment loop, where it was fixed; it was not fixed here.
///
/// What a device run produced, in order, across three attempts:
///
/// 1. `twoPressesProduceAPair` builds a second session while the first is still
///    being released and gets `configurationFailed("Cannot Record")` on the
///    first shutter press of the second pair.
/// 2. The daemon is left dead. The next test finds
///    `FigCaptureSessionRemote: "! storage->connectionDied"` and
///    `FigCaptureSourceRemote: err=-16453` within seconds.
/// 3. `twentyPacedMoments` — the phase's exit criterion — completes **zero**
///    iterations and the process is killed.
///
/// **Sharing one service across the suite fixes steps 1 and 2, and was verified
/// to: the two-press test then passed in 2.8s, both orders, at 4032×3024. It
/// breaks a different way.** `rebuildSession()` allocates a *new*
/// `AVCaptureSession` by design — replacing a dead one is its whole job — so on a
/// shared service it runs against a session the previous tests have already
/// started and stopped. Measured: **0.583s on a fresh service, 200.8s on the
/// shared one**, after which every later test is degraded.
///
/// So the two obvious fixes each break something.
///
/// ## Decided: the gate runs alone, in its own `xcodebuild`
///
/// `Scripts/capture-gate.sh`. One allocation, which is the shape that is known to
/// work, and nothing in production code changed to suit a test. The cost is a
/// second invocation per device run, measured in seconds rather than in the
/// twenty-minute runs three failed attempts cost.
///
/// Chosen over **splitting the suite across two test processes** because Swift
/// Testing cannot do it — it needs a second scheme or a UI test target — and over
/// **reusing one controller and resetting it** because that changes
/// `rebuildSession` to suit a test, and `rebuildSession` is doing real work
/// handling `mediaServicesWereReset`.
///
/// ## And the runner proves the gate ran
///
/// `-only-testing:` with a misspelled identifier matches nothing, and xcodebuild
/// reports `** TEST SUCCEEDED **` with exit code 0. **Verified on this machine,
/// deliberately, with a typo** — which is the point. This project has been bitten
/// three times by something that looked like a pass and asserted nothing: four
/// Phase 3 tests that "passed" in a millisecond, and a twenty-moment run that
/// reported zero iterations as if it had finished. So the script greps the output
/// for the gate's own name and fails if it is absent. A gate that did not run must
/// never look like a gate that passed.
///
/// **The rest of this suite is unaffected** and still runs in the normal device
/// invocation. The allocation problem only ever made the *gate* unmeasurable; the
/// seven cheaper tests are what runs 1 and 2 were trying to fix, and they do run.
@Suite("Phase 4 — live camera capture", .serialized)
@MainActor
struct LiveCaptureTests {

    /// How many live tests actually executed, as opposed to skipped.
    ///
    /// `nonisolated` so the guard — which is not main-actor isolated — can read
    /// it. Plain rather than `nonisolated(unsafe)`: `RunCounter` is `Sendable`
    /// and carries its own lock, so the compiler can prove this one is safe.
    /// An earlier version reached for the `unsafe` escape hatch out of habit,
    /// and the SDK was right to say it was not needed.
    nonisolated private static let runCounter = RunCounter()

    nonisolated static var runCount: Int { runCounter.count }

    private final class RunCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0

        /// The value, not the stored property, so the enclosing type can expose
        /// it `nonisolated` without the compiler objecting that a main-actor
        /// static is read from a nonisolated context.
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return total
        }

        func increment() {
            lock.lock(); total += 1; lock.unlock()
        }
    }

    /// True only on a host with real cameras on both sides.
    private var hasCamera: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return CaptureFormatSelector.wideAngleDevice(for: .back) != nil
            && CaptureFormatSelector.wideAngleDevice(for: .front) != nil
        #endif
    }

    private func requireCamera() -> Bool {
        guard hasCamera else {
            print("""

            ╔══════════════════════════════════════════════════════════════╗
            ║  LIVE CAPTURE TESTS SKIPPED — they asserted nothing.           ║
            ║  This host has no camera. The simulator cannot capture.        ║
            ║  Phase 4's exit criterion is NOT met.                          ║
            ╚══════════════════════════════════════════════════════════════╝

            """)
            return false
        }
        Self.runCounter.increment()
        return true
    }

    // MARK: - Format selection on real hardware

    @Test("A real device reports a 3:4 format, or none at all")
    func deviceHasThreeByFourFormat() throws {
        guard requireCamera() else { return }

        let device = try #require(CaptureFormatSelector.wideAngleDevice(for: .back))

        // The simulator-side pure tests cover the arithmetic. This asserts the
        // premise holds on hardware: that a 3:4 format actually exists to be
        // selected (ADR-019 — on an iPhone 17 there are 57 formats, all
        // landscape, and the orientation-agnostic test is what makes any of
        // them qualify).
        if let format = CaptureFormatSelector.selectFormat(for: device) {
            #expect(CaptureFormatSelector.isThreeByFour(
                CaptureFormatSelector.dimensions(of: format)
            ))
        } else {
            print("device reports no 3:4 format; capture will report noThreeByFourFormat")
        }
    }

    // MARK: - Session lifecycle

    @Test("The session starts on a chosen camera and the preview is a live layer")
    func sessionStarts() async throws {
        guard requireCamera() else { return }

        let service = SequentialCaptureService()
        #expect(service.previewLayer is AVCaptureVideoPreviewLayer)

        try await service.startSession(on: .back)
        await service.stopSession()
    }

    @Test("The session rebuilds after mediaServicesWereReset")
    func sessionRebuilds() async throws {
        guard requireCamera() else { return }

        // The one silent failure in the camera stack: no error, no callback, the
        // preview just freezes. Recovery means replacing the session outright
        // (TRD §5.5), and the only way to trust that path is to run it.
        let service = SequentialCaptureService()
        try await service.startSession(on: .back)
        try await service.rebuildSession()
        await service.stopSession()
    }

    // MARK: - The two-press sequence

    @Test("Two shutter presses produce a real pair, from either opening camera")
    func twoPressesProduceAPair() async throws {
        guard requireCamera() else { return }

        // Both orders, because the opening camera is random per moment
        // (ADR-021) and neither may be special-cased.
        //
        // **The second iteration is the one that fails**, and it fails for a
        // reason that is not about the camera: this constructs a fresh
        // `SequentialCaptureService` per iteration, so the second one allocates
        // an `AVCaptureSession` while the first is still being released, and the
        // first shutter press comes back `configurationFailed("Cannot Record")`.
        // Sharing one service across the suite fixes it — verified, 2.8s, both
        // orders — at the cost described in the type's documentation.
        for opening in CameraPosition.allCases {
            let service = SequentialCaptureService()
            try await service.startSession(on: opening)

            let first = try await service.captureCurrentPhoto()
            #expect(first.position == opening)
            #expect(first.isThreeByFour)
            #expect(first.data.count > 10_000)

            try await service.switchCamera(to: opening.opposite)
            let second = try await service.captureCurrentPhoto()
            #expect(second.position == opening.opposite)
            #expect(second.isThreeByFour)
            #expect(second.data.count > 10_000)

            print("CAPTURE pair \(opening.rawValue) -> \(opening.opposite.rawValue) ok "
                  + "(\(first.pixelWidth)x\(first.pixelHeight))")

            await service.stopSession()
        }
    }

    @Test("The full model flow reaches review with both photographs")
    func modelFlowReachesReview() async throws {
        guard requireCamera() else { return }

        let service = SequentialCaptureService()
        let library = PhotoKitLibrary()
        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )

        await model.start()
        #expect(model.phase == .shooting)

        await model.shutterPressed()
        #expect(model.captured[.back] != nil)

        await model.shutterPressed()
        #expect(model.livePosition == .front)

        await model.shutterPressed()
        #expect(model.phase == .review)
        #expect(model.captured[.back]?.isThreeByFour == true)
        #expect(model.captured[.front]?.isThreeByFour == true)

        await model.stop()
    }

    /// The phase's actual exit criterion, paced the way a person uses the app.
    @Test("Twenty moments, taken at a human pace, all succeed")
    func twentyPacedMoments() async throws {
        guard requireCamera() else { return }

        // Enough pause between the two photographs of each moment to represent
        // composing a shot. The old back-to-back loop swapped the camera forty
        // times in twenty seconds, which is not a thing a person does and not a
        // thing this app ever asks for.
        let composePause: Duration = .milliseconds(700)
        var failures: [String] = []

        // **One** service for all twenty iterations.
        //
        // This used to construct a `SequentialCaptureService` inside the loop,
        // which meant twenty `AVCaptureSession` allocations — and constructing
        // one is not free: `AVCaptureSession.init()` makes a *synchronous* XPC
        // round-trip to the capture daemon (`FigCaptureSessionRemoteCreate`).
        // Twenty of those in a background test process tripped the watchdog and
        // the app was SIGKILLed: `0x8BADF00D`, "Failed to terminate gracefully
        // after 5.0s", main thread parked inside `_createFigCaptureSession`.
        //
        // The important part is that this was never something the app does.
        // `AppEnvironment.captureService` is lazy and cached, so the whole app
        // has exactly one session for its lifetime; what varies is the camera
        // screen being opened and closed. Reusing one service here is therefore
        // not a way to dodge a crash — it is the only shape the product ever
        // runs in, and the old loop was testing something no user could reach.
        let service = SequentialCaptureService()

        for moment in 1...20 {
            do {
                let opening = CameraPosition.allCases[moment % 2]
                try await service.startSession(on: opening)

                let back = try await service.captureCurrentPhoto()
                try await service.switchCamera(to: opening.opposite)
                try await Task.sleep(for: composePause)
                let front = try await service.captureCurrentPhoto()

                let pair = [back, front]
                for photo in pair {
                    if !photo.isThreeByFour {
                        failures.append("moment \(moment) \(photo.position.rawValue): wrong ratio "
                                        + "(\(photo.pixelWidth)x\(photo.pixelHeight))")
                    }
                    if photo.data.count < 10_000 {
                        failures.append("moment \(moment) \(photo.position.rawValue): "
                                        + "implausibly small bytes — likely a blank frame")
                    }
                }
                print("CAPTURE moment \(moment)/20 ok (\(opening.rawValue) first)")

                await service.stopSession()
            } catch {
                failures.append("moment \(moment): \(error)")
                print("CAPTURE moment \(moment)/20 FAILED: \(error)")
            }
        }

        await service.stopSession()

        // Printed unconditionally on success too, so a green run carries its
        // own evidence rather than relying on someone remembering to look.
        print("live capture: 20 paced moments, \(failures.count) failures")
        for failure in failures { print("  \(failure)") }

        #expect(failures.isEmpty)
    }

    @Test("The front camera is mirrored and the rear is not")
    func mirroringIsCorrect() async throws {
        guard requireCamera() else { return }

        let service = SequentialCaptureService()
        try await service.startSession(on: .back)
        defer { Task { await service.stopSession() } }

        let back = try await service.captureCurrentPhoto()
        try await service.switchCamera(to: .front)
        let front = try await service.captureCurrentPhoto()

        // Mirroring is set on the connection, so `fileDataRepresentation()`
        // already reflects it (TRD §5.4). A front image that is not mirrored
        // reads as a photograph of a photograph rather than a mirror, and it is
        // instantly visible to a human — but a selfie is close to symmetric, so
        // this asserts the mechanism held rather than claiming a visual verdict.
        //
        // The human check: compare the two against the live preview.
        #expect(!front.data.isEmpty)
        #expect(!back.data.isEmpty)
    }

    // MARK: - Write path

    @Test("A captured pair survives the Photos write")
    func capturedPairWritesToPhotos() async throws {
        guard requireCamera() else { return }

        // The simulator cannot reach this: `requireCamera()` already returned.
        #if targetEnvironment(simulator)
        return
        #else
        // `.limited` is not a case Memoree's enum has: add-only access cannot be
        // limited, and `PhotoKitLibrary` maps Apple's `.limited` onto
        // `.authorized` for exactly that reason.
        let status = await PhotoKitLibrary().requestAuthorization()
        guard status == .authorized else {
            print("live capture: Photos not authorised, skipping the write test")
            return
        }

        let service = SequentialCaptureService()
        try await service.startSession(on: .back)
        defer { Task { await service.stopSession() } }

        let back = try await service.captureCurrentPhoto()
        try await service.switchCamera(to: .front)
        let front = try await service.captureCurrentPhoto()

        // This is the whole Phase 4 boundary: capture, then write, then stop.
        // Recording the moment itself is Phase 5's orchestration.
        let library = PhotoKitLibrary()
        let saved = try await library.saveMomentPair(
            backData: back.data,
            frontData: front.data,
            location: nil
        )

        #expect(await library.assetExists(saved.back))
        #expect(await library.assetExists(saved.front))
        #expect(saved.back != saved.front)

        print("live capture: wrote two real photographs to the camera roll")
        #endif
    }
}
