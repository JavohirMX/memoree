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

    @Test("The front has 0.5x and 1x, and no 2x")
    func frontHasNoTelephoto() {
        // **The front of a phone has one lens**, so 2x on it is a digital crop of
        // one cheek — and it is the magnification that turns a selfie into a
        // close-up. iOS Camera omits it for the same reason. The rear's 2x is
        // different: the virtual dual-wide device hands off to a genuinely longer
        // lens at that point.
        #expect(CameraZoom.ultraWide.isAvailable(on: .front), "0.5x exists on the front")
        #expect(CameraZoom.wide.isAvailable(on: .front))
        #expect(!CameraZoom.doubleWide.isAvailable(on: .front),
                "the front has no telephoto, so 2x is a crop")

        // The row's contents, which is what the buttons are actually built from.
        #expect(CameraZoom.offered(on: .front) == [.ultraWide, .wide])
        #expect(CameraZoom.offered(on: .back) == CameraZoom.allCases)

        // And the rear is unrestricted — which is the reason it uses one virtual
        // device rather than three lenses.
        for zoom in CameraZoom.allCases {
            #expect(zoom.isAvailable(on: .back), "\(zoom)")
        }
    }

    @Test("Only the front's 0.5x costs a lens change")
    func onlyFrontUltraWideNeedsItsOwnDevice() {
        // ## Why this is worth stating rather than hiding in the controller
        //
        // **Because the cost differs by an order of magnitude.** The rear's whole
        // range is one virtual dual-wide input, so every rear zoom is a
        // `videoZoomFactor` write under `lockForConfiguration`. The front has no
        // virtual device — the device survey found `.builtInDualWideCamera` only
        // at the back — so front 0.5x has to `removeInput`/`addInput`.
        //
        // A caller that assumed every zoom was a property write would build the
        // rear's cheap path for the front's expensive one, and the symptom is the
        // frame output dying mid-moment, which is the hardest failure in this app
        // to diagnose.
        #expect(CameraZoom.ultraWide.requiresItsOwnDevice(on: .front))
        #expect(!CameraZoom.ultraWide.requiresItsOwnDevice(on: .back),
                "the rear reaches 0.5x on the virtual device")

        for zoom in [CameraZoom.wide, .doubleWide] {
            #expect(!zoom.requiresItsOwnDevice(on: .front), "\(zoom)")
            #expect(!zoom.requiresItsOwnDevice(on: .back), "\(zoom)")
        }
    }

    @Test("Front 0.5x to 1x and back both need a session reconfigure")
    func frontUltraWideSwapIsBidirectional() {
        // The bug: needsNewLens only fired when *entering* UW, so 1× stayed on
        // the ultra-wide at factor 1.0 (FOV still 0.5× while the UI said 1×).
        #expect(CameraZoom.requiresSessionReconfigure(
            from: .wide, to: .ultraWide, on: .front
        ))
        #expect(CameraZoom.requiresSessionReconfigure(
            from: .ultraWide, to: .wide, on: .front
        ))
        #expect(!CameraZoom.requiresSessionReconfigure(
            from: .wide, to: .wide, on: .front
        ))
        #expect(!CameraZoom.requiresSessionReconfigure(
            from: .ultraWide, to: .wide, on: .back
        ), "rear never swaps physical lenses for zoom")
        #expect(!CameraZoom.requiresSessionReconfigure(
            from: .wide, to: .doubleWide, on: .back
        ))
    }

    @Test("Remembered rear 2x becomes 1x on the front without losing the preference case")
    func effectiveZoomOnFrontDropsTelephoto() {
        #expect(CameraZoom.doubleWide.effective(for: .front) == .wide)
        #expect(CameraZoom.doubleWide.effective(for: .back) == .doubleWide)
        #expect(CameraZoom.ultraWide.effective(for: .front) == .ultraWide)
        #expect(CameraZoom.wide.effective(for: .front) == .wide)
    }

    @Test("Virtual device factor respects a live switch-over")
    func virtualFactorUsesSwitchOver() {
        #expect(CameraZoom.wide.virtualDeviceZoomFactor(switchOver: 2.0) == 2.0)
        #expect(CameraZoom.wide.virtualDeviceZoomFactor(switchOver: 2.5) == 2.5)
        #expect(CameraZoom.ultraWide.virtualDeviceZoomFactor(switchOver: 2.0) == 1.0)
        #expect(CameraZoom.doubleWide.virtualDeviceZoomFactor(switchOver: 2.0) == 4.0)
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
    /// Tap to focus passes a **normalised** point, and the conversion lives in the
    /// service.
    ///
    /// Normalised because the alternative is a device point, which only the capture
    /// layer can compute — `captureDevicePointConverted(fromLayerPoint:)` needs
    /// AVFoundation, and `Features/` is not allowed to import it (`AGENTS.md` §3).
    /// A test that asserted a view-sized point would pin the seam in the wrong
    /// place, so this pins the contract instead.
    @Test("A tap on the preview reaches the service as a normalised point")
    func focusIsNormalised() async throws {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)
        let model = CameraViewModel(
            service: service,
            photoLibrary: library,
            chooseFirstCamera: { .back }
        )

        await model.start()

        // **Nothing happens before the preview has been laid out.** A tap cannot
        // arrive before that, and dividing by a zero size would produce a NaN
        // point, which AVFoundation throws on.
        await model.focus(at: CGPoint(x: 100, y: 200))
        #expect(service.focusRequests.isEmpty, "focused against an unlaid-out preview")

        model.previewSize = CGSize(width: 400, height: 800)
        await model.focus(at: CGPoint(x: 100, y: 200))
        #expect(service.focusRequests.count == 1)
        let point = try #require(service.focusRequests.first)
        #expect(abs(point.x - 0.25) < 0.001, "got \(point.x)")
        #expect(abs(point.y - 0.25) < 0.001, "got \(point.y)")

        // **Clamped, not trusted.** A drag can produce a tap outside the preview,
        // and an out-of-range point asks the sensor to focus where it cannot see.
        await model.focus(at: CGPoint(x: -50, y: 9_000))
        let clamped = try #require(service.focusRequests.last)
        #expect(clamped.x == 0, "got \(clamped.x)")
        #expect(clamped.y == 1, "got \(clamped.y)")

        await model.stop()
    }

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
        #expect(await model.chooseZoom(.wide))

        // **2x on the front is a digital crop of one cheek**, so it is refused
        // rather than clamped. Clamping would leave a button showing 2x selected
        // while the camera sat at 1x — a control lying about the state of the
        // world, which is the failure mode AGENTS.md §6 calls a dead end.
        let refused = await model.chooseZoom(.doubleWide)
        #expect(!refused, "the front has no telephoto and must say so")
        #expect(model.zoom == .wide,
                "a refused zoom must not silently become something else")

        // 0.5x on the front *is* real — it is a different lens, not a zoom factor.
        #expect(await model.chooseZoom(.ultraWide),
                "the front has an ultra-wide device and must offer it")

        await model.stop()
    }
}
