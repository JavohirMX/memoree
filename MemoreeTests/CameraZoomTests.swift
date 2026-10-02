import CoreGraphics
import Testing

@testable import Memoree

/// Phase 4 — the zoom control.
///
/// ## What is worth testing off-device, and what is not
///
/// The mapping from a button to a `videoZoomFactor` **cannot** be verified in a
/// simulator, and the device survey says why: what a zoom factor actually *looks*
/// like is a property of the sensor. It measured the two facts the control rests
/// on — the rear upscale threshold is 1.0, and the dual-wide device hands off at
/// 2.00 — and nothing else about the framing is knowable without a phone.
///
/// So what is tested here is everything that is ours: that the three cases are
/// distinct, that the device factor is derived rather than restated, that the
/// front refuses what it does not have, and that the labels are what a person
/// recognises. A test that asserted "2× looks like twice as far" would be
/// asserting the sensor.
@Suite("Phase 4 — camera zoom")
struct CameraZoomTests {

    @Test("Three buttons, three distinct magnifications")
    func theThreeAreDistinct() {
        #expect(CameraZoom.allCases.count == 3)
        #expect(Set(CameraZoom.allCases.map(\.factor)).count == 3,
                "two buttons zoom to the same place")
        #expect(CameraZoom.ultraWide.factor < CameraZoom.wide.factor)
        #expect(CameraZoom.wide.factor < CameraZoom.doubleWide.factor)
    }

    @Test("The device factor is derived from the button, not restated")
    func deviceFactorIsDerived() {
        // **The virtual device's 1.0 is its own widest field of view** — the
        // ultra-wide's — and its wide lens sits at 2.0, which is the switch-over
        // the survey measured. So the device factor is double the button, and
        // stating that relationship once is what keeps the two from drifting.
        for zoom in CameraZoom.allCases {
            #expect(zoom.virtualDeviceZoomFactor == zoom.factor * 2,
                    "\(zoom): \(zoom.virtualDeviceZoomFactor) vs \(zoom.factor * 2)")
        }

        #expect(CameraZoom.ultraWide.virtualDeviceZoomFactor == 1.0,
                "0.5x is the virtual device's own widest view")
        #expect(CameraZoom.doubleWide.virtualDeviceZoomFactor == 4.0)
    }

    @Test("The front camera refuses 0.5x rather than pretending")
    func frontRefusesUltraWide() {
        // **The front of a phone has one lens.** Clamping to 1x instead would
        // leave a button showing 0.5x selected while the camera sits at 1x — a
        // control lying about the state of the world, which is the failure mode
        // AGENTS.md §6 calls a dead end.
        #expect(!CameraZoom.ultraWide.isAvailable(on: .front))
        #expect(CameraZoom.wide.isAvailable(on: .front))
        #expect(CameraZoom.doubleWide.isAvailable(on: .front))

        // And nothing about the rear is restricted — every case is available there,
        // which is the reason the rear uses a virtual device.
        for zoom in CameraZoom.allCases {
            #expect(zoom.isAvailable(on: .back), "\(zoom)")
        }
    }

    @Test("The labels are the ones a person recognises")
    func labelsAreTheCameraConventions() {
        // **Not localised, deliberately.** These are camera conventions rather than
        // numbers: every camera app writes them this way in every language, and a
        // button reading "0,5x" in one locale and "0.5x" in another would be a
        // label whose meaning changed with the phone's settings. The `x` is the
        // multiplication sign, not the letter.
        #expect(CameraZoom.ultraWide.label == "0.5×")
        #expect(CameraZoom.wide.label == "1×")
        #expect(CameraZoom.doubleWide.label == "2×")
    }

    @Test("A zoom read back from a device lands on the nearest button")
    func nearestRoundsToTheNearestButton() {
        // Rounds rather than clamping to the ends, so a device left at an odd zoom
        // reports the button the user would have meant.
        #expect(CameraZoom.nearest(to: 1.0) == .wide)
        #expect(CameraZoom.nearest(to: 1.4) == .wide)
        #expect(CameraZoom.nearest(to: 1.6) == .doubleWide)
        #expect(CameraZoom.nearest(to: 0.2) == .ultraWide)
        #expect(CameraZoom.nearest(to: 0.5) == .ultraWide)
        #expect(CameraZoom.nearest(to: 2.0) == .doubleWide)
    }

    @Test("Every device factor is within a plausible range")
    func factorsAreSane() {
        // The survey measured a ceiling of 189x on this hardware, so nothing here
        // is near a limit — but the point of the clamp in the controller is that
        // AVFoundation *would* accept 189 and hand back a rectangle of pixels, so
        // these three numbers are the only ones the app is ever allowed to ask
        // for. If one of them changed by an order of magnitude, this catches it.
        for zoom in CameraZoom.allCases {
            let factor = zoom.virtualDeviceZoomFactor
            #expect(factor >= 1.0, "\(zoom): below the device's own widest view")
            #expect(factor <= 8.0, "\(zoom): \(factor)x is not a photograph")
        }
    }
}

@Suite("Phase 4 — zoom survives the camera swap")
@MainActor
struct CameraZoomPersistenceTests {

    /// **The failure this whole suite exists for.**
    ///
    /// ADR-021 tears the input down and rebuilds it between the two shutter
    /// presses. A device comes back at 1.0, so without remembering the choice a
    /// user who picked 0.5× gets two photographs of one moment at two different
    /// framings — and the composite puts them side by side, which reads as a
    /// rendering bug rather than as zoom resetting.
    @Test("A zoom survives the swap to the other camera and back")
    func zoomSurvivesTheSwap() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)
        let model = CameraViewModel(
            service: service,
            photoLibrary: library,
            chooseFirstCamera: { .back }
        )

        await model.start()
        #expect(await model.chooseZoom(.ultraWide), "0.5x on the rear")
        #expect(model.zoom == .ultraWide)

        // Swap, exactly as the second shutter press does.
        try await service.switchCamera(to: .front)
        // The choice is remembered even though the front cannot do 0.5x — it is
        // the *user's* choice, not a property of the camera, and it is applied
        // when the rear comes back.
        #expect(await service.currentZoom() == .ultraWide,
                "the swap dropped the user's zoom")

        try await service.switchCamera(to: .back)
        #expect(await service.currentZoom() == .ultraWide,
                "returning to the rear dropped the user's zoom")

        await model.stop()
    }

    @Test("A zoom the front cannot do is refused, and the old one stands")
    func refusedZoomLeavesTheChoiceAlone() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)
        let model = CameraViewModel(
            service: service,
            photoLibrary: library,
            chooseFirstCamera: { .front }
        )

        await model.start()
        #expect(await model.chooseZoom(.doubleWide))

        let refused = await model.chooseZoom(.ultraWide)
        #expect(!refused, "the front has no 0.5x and must say so")
        #expect(model.zoom == .doubleWide,
                "a refused zoom must not silently become 1x — the button would lie")

        await model.stop()
    }
}
