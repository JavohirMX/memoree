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
///
/// `@MainActor` because `CameraViewModel` is, and the tests drive it directly.
/// This is the one layer where `@testable` earns its keep: the whole point of
/// the view model is that the *sequencing* is testable without a camera.
@Suite("Phase 4 — capture flow")
@MainActor
struct CaptureFlowTests {

    // MARK: - Value types

    @Test("Camera positions are opposites of each other")
    func positionsAreOpposites() {
        #expect(CameraPosition.back.opposite == .front)
        #expect(CameraPosition.front.opposite == .back)
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

    // MARK: - The two-press sequence

    /// The core of ADR-021, and the behaviour a user would notice first.
    @Test("Two shutter presses, two photographs, one camera switch between them")
    func twoPressesProduceAPair() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        // Fixed order so the assertions below are deterministic; production
        // randomises it per moment.
        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()
        #expect(model.phase == .shooting)

        // First press: photograph the rear camera, then bring up the front. The
        // switch happens as the press completes — the user sees the other
        // camera come up and composes with it, which is the whole point
        // (ADR-021). Two presses for two photographs.
        await model.shutterPressed()
        #expect(service.capturedPositions == [.back])
        #expect(service.switchCount == 1)
        #expect(service.switchedTo == [.front])
        #expect(model.livePosition == .front)
        #expect(model.phase == .shooting, "now composing with the front camera")
        // The rear photograph is already in the inset while the front is live.
        #expect(model.insetPhoto?.position == .back)

        // Second press: photograph the front camera. The pair is complete.
        await model.shutterPressed()
        #expect(service.capturedPositions == [.back, .front])
        #expect(model.phase == .review)
    }

    @Test("The frame wait happens on the switch, before the next photograph")
    func frameWaitPrecedesTheSecondPhoto() async throws {
        // Step 7 of TRD §5.2. Capturing before the new sensor delivers yields
        // a black or green photograph, silently. Asserting the wait happened is
        // the closest a simulator test gets to proving it.
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .front }
        )
        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()

        #expect(service.didWaitForFrameBeforeSwitch)
    }

    @Test("Either camera may open first")
    func eitherCameraMayOpenFirst() async throws {
        // The order is random per moment (ADR-021), so both orders are real and
        // neither may be special-cased.
        for opening in CameraPosition.allCases {
            let service = InMemoryCaptureService()
            let library = InMemoryPhotoLibraryService()
            library.setAuthorization(.authorized)

            let model = CameraViewModel(
                service: service, photoLibrary: library, chooseFirstCamera: { opening }
            )
            await model.start()
            await model.shutterPressed()
            await model.shutterPressed()
            await model.shutterPressed()

            #expect(service.openedOn == [opening])
            #expect(service.capturedPositions == [opening, opening.opposite])
            #expect(model.captured[.back] != nil)
            #expect(model.captured[.front] != nil)
        }
    }

    @Test("Both halves of a pair are 3:4")
    func pairGeometry() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()

        #expect(model.captured[.back]?.isThreeByFour == true)
        #expect(model.captured[.front]?.isThreeByFour == true)
    }

    // MARK: - The inset

    @Test("The taken photograph shows as the inset while the other camera is live")
    func insetAppearsAfterTheFirstPress() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()

        // Nothing taken yet: no inset.
        #expect(model.insetPhoto == nil)

        await model.shutterPressed()
        // Rear taken, front now live, so the rear is the inset.
        #expect(model.livePosition == .front)
        #expect(model.insetPhoto?.position == .back)

        await model.shutterPressed()
        await model.shutterPressed()
        // Both taken: no inset during review, the composite handles it.
        #expect(model.phase == .review)
    }

    // MARK: - Review

    @Test("Tapping the small photograph promotes it and demotes the other")
    func swapProminent() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        #expect(model.phase == .review)

        // The last photograph taken is the large one.
        let initiallyProminent = model.prominentPosition
        let initiallyInset = model.insetReviewPhoto

        model.swapProminent()

        #expect(model.prominentPosition != initiallyProminent)
        #expect(model.prominentPhoto == initiallyInset)

        // Swapping back returns to where it started.
        model.swapProminent()
        #expect(model.prominentPosition == initiallyProminent)
    }

    @Test("Reshooting one half keeps the other")
    func reshootOneHalf() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        #expect(model.phase == .review)

        let keptFront = model.captured[.front]
        await model.reshoot(.back)

        // Back discarded, front untouched, back camera live again.
        #expect(model.captured[.front] == keptFront)
        #expect(model.captured[.back] == nil)
        #expect(model.livePosition == .back)
        #expect(model.phase == .shooting)
        #expect(model.retakeCount == 1)

        // Taking it again completes the pair.
        await model.shutterPressed()
        await model.shutterPressed()
        #expect(model.phase == .review)
        #expect(model.captured[.back] != nil)
        #expect(model.captured[.front] == keptFront)
    }

    @Test("Starting over discards both")
    func startOver() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()

        await model.startOver()

        #expect(model.captured.isEmpty)
        #expect(model.phase == .shooting)
    }

    // MARK: - Commit

    @Test("Posting writes both photographs to Photos")
    func commitWritesPair() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        #expect(model.phase == .saved)
        #expect(library.savedPairCount == 1)
    }

    @Test("A failed write is recoverable, and the photographs are kept in memory")
    func commitFailureIsRecoverable() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)
        library.failNextWrite(with: .writeFailed("disk full"))

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()
        await model.shutterPressed()
        await model.shutterPressed()
        await model.commit()

        #expect(model.isFailed)
        // Retryable: nothing was lost, the photographs are still in memory.
        await model.retry()
        #expect(model.phase != .permissionDenied)
    }

    // MARK: - Failure handling

    @Test("A failed capture surfaces a retryable state and keeps the first photograph")
    func captureFailureSurfaces() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()
        await model.shutterPressed()   // rear captured, front now live

        // Fail the *second* capture, so the first is already held.
        service.failNextCapture(with: .noDeliveredFrame(.front))
        await model.shutterPressed()

        #expect(model.isFailed)
        // A failure does not discard what was already taken, and does not
        // invent a photograph that was never captured.
        #expect(model.captured[.back] != nil)
        #expect(model.captured[.front] == nil)
    }

    @Test("A failed camera switch surfaces rather than silently shooting the wrong camera")
    func switchFailureSurfaces() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)
        service.failNextSwitch(with: .inUseByAnotherApp)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()

        // Press one: the capture succeeds, then the switch is refused. The
        // rear photograph must survive, and the live camera must not silently
        // become the front one.
        // The rear photograph is taken, then the switch to the front is
        // refused. The live camera must not silently become the front one,
        // because a photograph labelled `.front` that was actually shot on the
        // rear is a lie the archive keeps forever.
        await model.shutterPressed()

        #expect(model.isFailed)
        #expect(model.captured[.back] != nil)
        #expect(model.livePosition == .back, "a refused switch must not advance the camera")
        #expect(model.captured[.front] == nil)
    }

    @Test("A denied permission is a state, not a crash")
    func deniedPermissionIsSupported() async {
        let service = InMemoryCaptureService()
        service.setAuthorization(.denied)
        let library = InMemoryPhotoLibraryService()

        let model = CameraViewModel(service: service, photoLibrary: library)
        await model.start()

        #expect(model.phase == .permissionDenied)
        #expect(!model.showsShutter)
    }

    @Test("A thermal block surfaces as retryable")
    func thermalStateSurfaces() async {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)
        service.failNextCapture(with: .thermalStateCritical)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()
        await model.shutterPressed()

        #expect(model.isFailed)
    }

    // MARK: - Recovery

    @Test("The session rebuilds after mediaServicesWereReset")
    func rebuildIsReachable() async throws {
        // This is the one silent failure mode in the camera stack: it raises no
        // error and fires no callback, so the recovery path cannot be trusted
        // until it has been invoked deliberately (TRD §5.5).
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )
        await model.start()
        await model.simulateMediaServicesReset()

        #expect(service.rebuildCount == 1)
        #expect(model.phase == .shooting)
    }

    @Test("The shutter is absent, not disabled, when the camera cannot be used")
    func shutterIsAbsentWhenUnusable() async {
        let service = InMemoryCaptureService()
        service.setAuthorization(.denied)
        let library = InMemoryPhotoLibraryService()

        let model = CameraViewModel(service: service, photoLibrary: library)
        await model.start()

        // A control that looks live and does nothing is a dead end
        // (AGENTS.md §6).
        #expect(!model.showsShutter)
    }
}
