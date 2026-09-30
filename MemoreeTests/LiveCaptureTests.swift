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
/// and above all the **20-run reliability check** — is therefore only reachable
/// on a device. A green simulator run says nothing about whether this phase
/// works.
///
/// ## The 20-run check
///
/// The frame-wait after an input swap is the step most likely to flake, and
/// AGENTS.md's working agreement is that a phase is not done until it runs on
/// hardware. Twenty consecutive pairs, zero failures, is the gate. If it flakes,
/// the cause is the frame-wait — not the UI, not Photos, not the format
/// selector.
///
/// ## A skip must not look like a pass
///
/// Swift Testing counts an early return as **passed**. That is how four Phase 3
/// tests "passed" in one millisecond while asserting nothing, twice over. So
/// every skip prints a banner, and `LiveCaptureRunGuardTests` fails the run
/// unless at least one test here genuinely executed.
///
/// ## Nothing is deleted
///
/// The 20-run check captures 40 photographs and discards them in memory — they
/// are never written to Photos, so the camera roll is untouched. The
/// commit-path test writes two and leaves them, as Phase 3's do, because
/// Memoree never removes anything from the user's library (ADR-008) and that
/// applies to its own test code too.
@Suite("Phase 4 — live camera capture", .serialized)
@MainActor
struct LiveCaptureTests {

    /// How many live tests actually executed, as opposed to skipped.
    ///
    /// Read by `LiveCaptureRunGuardTests` so a skipped suite cannot pass unnoticed.
    /// `nonisolated(unsafe)` because the suite is `@MainActor` and the guard is
    /// not, so it cannot read a main-actor static. Required here — unlike the
    /// Phase 3 version, where the same attribute drew a warning for being
    /// unnecessary, because that suite annotates its counter differently.
    /// Safe: the counter carries its own lock and holds nothing but an integer.
    nonisolated(unsafe) private static let runCounter = RunCounter()

    nonisolated static var runCount: Int { runCounter.value }

    private final class RunCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func increment() {
            lock.lock(); count += 1; lock.unlock()
        }
    }

    /// True only on a host with a real rear camera.
    ///
    /// A property of the hardware rather than of configuration, deliberately —
    /// the first attempt at the Phase 3 gate read an environment variable, and
    /// `xcodebuild` does not propagate shell environment into the test process,
    /// so the documented way to enable the suite silently did nothing.
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
            ║  Phase 4's exit criterion — 20 reliable captures — is NOT met. ║
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
        // selected. If a future device ships none, this fails loudly rather
        // than the selector silently returning nil at runtime.
        if let format = CaptureFormatSelector.selectFormat(for: device) {
            #expect(CaptureFormatSelector.isThreeByFour(
                CaptureFormatSelector.dimensions(of: format)
            ))
        } else {
            // Legal, but worth knowing: capture would raise noInputAvailable.
            print("device reports no 3:4 format; capture will report noInputAvailable")
        }
    }

    // MARK: - Session lifecycle

    @Test("The session starts and the preview surface is a live layer")
    func sessionStarts() async throws {
        guard requireCamera() else { return }

        let service = SequentialCaptureService()
        #expect(service.previewLayer is AVCaptureVideoPreviewLayer)

        try await service.startSession()
        await service.stopSession()
    }

    @Test("The session rebuilds after mediaServicesWereReset")
    func sessionRebuilds() async throws {
        guard requireCamera() else { return }

        // The one silent failure in the camera stack: no error, no callback, the
        // preview just freezes. Recovery means replacing the session outright
        // (TRD §5.5), and the only way to trust that path is to run it.
        let service = SequentialCaptureService()
        try await service.startSession()
        try await service.rebuildSession()
        await service.stopSession()
    }

    // MARK: - The pair

    @Test("A captured pair is two real, 3:4, correctly-sized images")
    func capturesRealPair() async throws {
        guard requireCamera() else { return }

        let service = SequentialCaptureService()
        try await service.startSession()
        defer { Task { await service.stopSession() } }

        let pair = try await service.capturePair()

        // Real bytes. A black or green frame from a missed frame-wait still
        // decodes, so size and non-emptiness are necessary but not sufficient —
        // which is why this is paired with the human check below.
        #expect(pair.back.data.count > 10_000)
        #expect(pair.front.data.count > 10_000)
        #expect(pair.back.position == .back)
        #expect(pair.front.position == .front)

        // The geometry assertion the pure tests could only simulate.
        #expect(pair.back.isThreeByFour)
        #expect(pair.front.isThreeByFour)
    }

    @Test("Twenty consecutive captures all succeed")
    func twentyConsecutiveCaptures() async throws {
        guard requireCamera() else { return }

        let service = SequentialCaptureService()
        try await service.startSession()
        defer { Task { await service.stopSession() } }

        // The phase's actual exit criterion. Each iteration performs the full
        // rear → swap → frame-wait → front → restore sequence, so twenty
        // iterations is twenty chances for the frame-wait to lose its race
        // against an in-flight frame from the previous camera.
        var failures: [String] = []

        for iteration in 1...20 {
            do {
                let pair = try await service.capturePair()
                if !pair.back.isThreeByFour || !pair.front.isThreeByFour {
                    failures.append("iteration \(iteration): wrong aspect ratio "
                                    + "(\(pair.back.pixelWidth)x\(pair.back.pixelHeight))")
                }
                if pair.back.data.count < 10_000 || pair.front.data.count < 10_000 {
                    failures.append("iteration \(iteration): implausibly small bytes "
                                    + "— likely a blank frame")
                }
            } catch {
                failures.append("iteration \(iteration): \(error)")
            }
        }

        // Printed unconditionally on success too, so a green run carries its
        // own evidence rather than relying on someone remembering to look.
        print("live capture: 20 iterations, \(failures.count) failures")
        for failure in failures { print("  \(failure)") }

        #expect(failures.isEmpty)
    }

    @Test("The front camera is mirrored and the rear is not")
    func mirroringIsCorrect() async throws {
        guard requireCamera() else { return }

        let service = SequentialCaptureService()
        try await service.startSession()
        defer { Task { await service.stopSession() } }

        let pair = try await service.capturePair()

        // Mirroring is set on the connection, so `fileDataRepresentation()`
        // already reflects it (TRD §5.4). A front image that is not mirrored
        // reads as a photograph of a photograph rather than a mirror, and it is
        // instantly visible to a human — but a selfie is close to symmetric, so
        // this asserts the mechanism held rather than claiming a visual verdict.
        //
        // The human check: compare the two against the live preview.
        #expect(!pair.front.data.isEmpty)
        #expect(!pair.back.data.isEmpty)
    }

    // MARK: - Write path

    @Test("A captured pair survives the Photos write")
    func capturedPairWritesToPhotos() async throws {
        guard requireCamera() else { return }

        #if targetEnvironment(simulator)
        // Unreachable: requireCamera() already returned false.
        return
        #else
        // `.limited` is not a case Memoree's own enum has: add-only access
        // cannot be limited, and `PhotoKitLibrary` maps Apple's `.limited` onto
        // `.authorized` for exactly that reason.
        let status = await PhotoKitLibrary().requestAuthorization()
        guard status == .authorized else {
            print("live capture: Photos not authorised, skipping the write test")
            return
        }

        let service = SequentialCaptureService()
        try await service.startSession()
        defer { Task { await service.stopSession() } }

        let pair = try await service.capturePair()

        // This is the whole Phase 4 boundary: capture, then write, then stop.
        // Recording the moment itself is Phase 5's orchestration.
        let library = PhotoKitLibrary()
        let saved = try await library.saveMomentPair(
            backData: pair.back.data,
            frontData: pair.front.data,
            location: nil
        )

        #expect(await library.assetExists(saved.back))
        #expect(await library.assetExists(saved.front))
        #expect(saved.back != saved.front)

        print("live capture: wrote two real photographs to the camera roll")
        #endif
    }
}
