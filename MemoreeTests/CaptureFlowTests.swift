import Foundation
import QuartzCore
import Testing

@testable import Memoree

/// Phase 4 — the capture flow, driven entirely by the test double.
///
/// Everything here runs on the simulator. The simulator has **no camera** at
/// all (AGENTS.md §7), so this is the only automated coverage the capture flow
/// can have off-device — which is precisely why the double is part of the app
/// target rather than the test target.
///
/// The device-only half lives in `LiveCaptureTests`.
@Suite("Phase 4 — capture flow")
struct CaptureFlowTests {

    // MARK: - Value types

    @Test("Camera positions are opposites of each other")
    func positionsAreOpposites() {
        #expect(CameraPosition.back.opposite == .front)
        #expect(CameraPosition.front.opposite == .back)
    }

    @Test("A moment opens on the rear camera")
    func defaultPositionIsRear() {
        // BTS records only the primary camera, and rear is the default
        // primary (ADR-013).
        #expect(CameraPosition.default == .back)
    }

    // MARK: - Errors

    @Test("Every capture error has user-facing copy")
    func allErrorsHaveCopy() {
        // A dead end is a bug (AGENTS.md §6). An error with no description
        // would surface as a blank screen.
        let errors: [CaptureError] = [
            .permissionDenied, .restricted,
            .noInputAvailable(.back), .noThreeByFourFormat(.back),
            .inUseByAnotherApp, .interrupted,
            .thermalStateCritical, .noDeliveredFrame(.front),
            .photoDataUnavailable(.back), .configurationFailed("x"),
            .sessionReset,
        ]
        for error in errors {
            #expect(
                error.errorDescription?.isEmpty == false,
                "\(error) has no user-facing copy"
            )
        }
    }

    @Test("A denied permission is not offered a retry")
    func deniedPermissionIsNotRetryable() {
        // Offering "try again" for a permission the user must change in
        // Settings is a dead end. Retryable failures are the transient ones.
        #expect(!CaptureError.permissionDenied.isRetryable)
        #expect(!CaptureError.restricted.isRetryable)
        #expect(!CaptureError.noInputAvailable(.back).isRetryable)
        // A camera that cannot honour the geometry will not start honouring it
        // on a second attempt either.
        #expect(!CaptureError.noThreeByFourFormat(.back).isRetryable)

        #expect(CaptureError.interrupted.isRetryable)
        #expect(CaptureError.inUseByAnotherApp.isRetryable)
        #expect(CaptureError.thermalStateCritical.isRetryable)
        #expect(CaptureError.noDeliveredFrame(.front).isRetryable)
        #expect(CaptureError.sessionReset.isRetryable)
    }

    // MARK: - Session lifecycle

    @Test("Starting and stopping the session is recorded")
    func sessionLifecycle() async throws {
        let service = InMemoryCaptureService()
        #expect(!service.isRunning)

        try await service.startSession()
        #expect(service.isRunning)
        #expect(service.startCount == 1)

        await service.stopSession()
        #expect(!service.isRunning)
        #expect(service.stopCount == 1)
    }

    @Test("A denied permission is a state, not a crash")
    func deniedPermissionIsSupported() async {
        let service = InMemoryCaptureService()
        service.setAuthorization(.denied)

        #expect(service.authorizationStatus() == .denied)
        // Must not trap: the archive and settings stay usable without a camera.
        #expect(service.previewLayer is CALayer)
    }

    @Test("Rebuilding the session is reachable, for mediaServicesWereReset")
    func rebuildIsReachable() async throws {
        // This is the one silent failure mode in the camera stack: it raises
        // no error and fires no callback, so the only way to trust the recovery
        // path is to be able to invoke it (TRD §5.5).
        let service = InMemoryCaptureService()
        try await service.rebuildSession()
        #expect(service.rebuildCount == 1)
        #expect(service.isRunning)
    }

    // MARK: - The pair

    @Test("A pair captures rear first, then front")
    func pairOrder() async throws {
        let service = InMemoryCaptureService()
        let pair = try await service.capturePair()

        #expect(pair.back.position == .back)
        #expect(pair.front.position == .front)
        #expect(service.capturedPositions == [.back, .front])
    }

    @Test("The frame wait happens between the swap and the front capture")
    func frameWaitIsNotSkipped() async throws {
        // Step 7 of TRD §5.2. Capturing before the front sensor delivers a
        // frame yields a black or green image, silently. Asserting the wait
        // happened is the closest a simulator test can get to proving it.
        let service = InMemoryCaptureService()
        _ = try await service.capturePair()
        #expect(service.didWaitForFrameBeforeFront)
        #expect(service.swapCount == 1)
    }

    @Test("Both halves of a pair are 3:4")
    func pairGeometry() async throws {
        let service = InMemoryCaptureService()
        let pair = try await service.capturePair()
        #expect(pair.back.isThreeByFour)
        #expect(pair.front.isThreeByFour)
    }

    @Test("Repeated captures increment the count, as retakes do")
    func repeatedCaptures() async throws {
        let service = InMemoryCaptureService()
        for _ in 0..<3 {
            _ = try await service.capturePair()
        }
        #expect(service.capturePairCount == 3)
        #expect(service.capturedPositions.count == 6)
    }

    @Test("A failed capture is retryable and does not leave state wedged")
    func failureThenRetry() async throws {
        let service = InMemoryCaptureService()
        service.failNextCapture(with: .noDeliveredFrame(.front))

        await #expect(throws: CaptureError.noDeliveredFrame(.front)) {
            _ = try await service.capturePair()
        }

        // The injected failure is consumed, so the next attempt works. A
        // service that stayed broken would be a dead end (AGENTS.md §6).
        let pair = try await service.capturePair()
        #expect(pair.front.position == .front)
    }

    @Test("A thermal block surfaces as a retryable error")
    func thermalStateSurfaces() async {
        let service = InMemoryCaptureService()
        service.failNextCapture(with: .thermalStateCritical)

        await #expect(throws: CaptureError.thermalStateCritical) {
            _ = try await service.capturePair()
        }
    }

    @Test("An in-use camera is distinguished from a missing one")
    func inUseIsDistinct() async {
        let service = InMemoryCaptureService()
        service.failNextCapture(with: .inUseByAnotherApp)
        await #expect(throws: CaptureError.inUseByAnotherApp) {
            _ = try await service.capturePair()
        }
        #expect(CaptureError.inUseByAnotherApp != .noInputAvailable(.back))
    }

    // MARK: - Format application

    @Test("The format is applied for the position being captured")
    func formatAppliedPerPosition() async throws {
        let service = InMemoryCaptureService()
        try await service.configureFormat(for: .front)
        try await service.configureFormat(for: .back)
        #expect(service.configuredFormats == [.front, .back])
    }
}
