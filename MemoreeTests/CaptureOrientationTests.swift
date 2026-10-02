import CoreGraphics
import Testing

@testable import Memoree

/// Phase 4 — the rotation applied to the preview and photo connections.
///
/// ## What is and is not tested here
///
/// **The angles themselves are not, and cannot be, tested without a camera.**
/// They come from `AVCaptureDevice.RotationCoordinator`, which reads the device's
/// physical orientation. There is nothing to assert about AVFoundation's answer
/// off-device — only that the app applies it correctly, and that it applies the
/// *two* of them to the *two* connections that mean different things.
///
/// What used to be tested here was a hand-written table from
/// `UIDevice.orientation` to an angle. **It was wrong, and the table's two
/// defects are recorded on `CaptureOrientation`.** What survives of it is the
/// property that made it unsafe to get wrong: only quarter turns are legal, and
/// setting anything else is a crash rather than an error.
@Suite("Phase 4 — capture orientation")
struct CaptureOrientationTests {

    @Test("Only quarter turns are legal on a connection")
    func onlyQuarterTurnsAreLegal() {
        // **Setting an unsupported angle throws `NSInvalidArgumentException`.**
        // That is a crash, not an error, and not one any test would otherwise
        // reach — so the rule is a named function called before every assignment
        // rather than a comment beside it.
        for legal in [CGFloat(0), 90, 180, 270] {
            #expect(CaptureOrientation.isSupported(legal), "\(legal)")
        }
        for illegal in [CGFloat(45), 1, -90, 360, 89.9, 270.1] {
            #expect(!CaptureOrientation.isSupported(illegal), "\(illegal) would throw")
        }
    }

    @Test("The two angles are carried independently")
    func previewAndCaptureAreDistinctFields() {
        // **They are not the same number on every device.** AVFoundation computes
        // a preview angle and a capture angle separately, because the preview
        // layer's aspect and the sensor's differ. Collapsing them into one field
        // is the mistake that makes a preview look right while the saved file is
        // tagged wrong — or the other way round, with nothing to tell them apart.
        let orientation = CaptureOrientation(previewAngle: 90, captureAngle: 270)
        #expect(orientation.previewAngle != orientation.captureAngle)
        #expect(orientation.previewAngle == 90)
        #expect(orientation.captureAngle == 270)
    }

    @Test("The startup rotation is portrait and legal")
    func startupIsUprightAndLegal() throws {
        // **It exists so the first preview frame is not sideways.** The
        // coordinator's first answer can arrive a moment after the session opens,
        // and a first frame that appears rotated is the first thing anyone
        // notices. Portrait, because that is where the app lives.
        //
        // **It was later removed** — see `thereIsNoDefaultRotation`, which is the
        // test that matters. This one remains to pin what a *correct* applied
        // rotation looks like, so the guard below is not just "nil is nil".
        let portrait = CaptureOrientation(previewAngle: 90, captureAngle: 90)
        #expect(CaptureOrientation.isSupported(portrait.previewAngle))
        #expect(CaptureOrientation.isSupported(portrait.captureAngle))
        #expect(portrait == CaptureOrientation(previewAngle: 90, captureAngle: 90))
    }

    @Test("There is no default rotation")
    func thereIsNoDefaultRotation() {
        // **The bug that shipped twice.**
        //
        // When no rotation had been derived, the app applied a portrait quarter
        // turn anyway. Because a camera sensor is natively landscape, that made
        // **portrait shots come out correct** — a landscape buffer rotated a
        // quarter turn *is* a portrait image — and **landscape shots wrong**, since
        // those need no rotation at all. So the symptom was "portrait works,
        // landscape doesn't", which reads like a mapping error rather than like
        // a default nobody asked for.
        //
        // It is `nil` now. With no rotation the photograph keeps the sensor's
        // native orientation, which is self-consistent and right for one of the
        // four ways a phone can be held. A wrong rotation is worse than a missing
        // one: it displays as something the user never photographed.
        #expect(CaptureOrientation.startup == nil,
                "there is no rotation to apply before AVFoundation supplies one")
    }

    @Test("Nothing reports orientation into the camera any more")
    func rotationIsNotReported() throws {
        // **The rotation lock is the whole reason this exists, and it cannot be
        // asserted by running the app.**
        //
        // `UIDevice.orientation` reports `.portrait` forever when the user has
        // rotation lock on, so any design that reads a held orientation and maps
        // it to an angle applies a quarter turn to a sideways photograph and saves
        // it as a portrait one. That is precisely what happened, twice, before
        // `AVCaptureDevice.RotationCoordinator` replaced the table — and the
        // rotation lock is a setting, so no amount of testing in a simulator or a
        // test suite would ever reproduce it.
        //
        // So this pins the *design* instead: the service takes no orientation, and
        // nothing in the app reads one. If a future change reintroduces a report
        // path, this fails, and whoever introduced it has to explain why the
        // rotation lock is now handled differently.
        let protocolFile = try SourceScan.file(named: "CapturePhotoService.swift")
        let code = try SourceScan.codeLines(of: protocolFile)
            .map(\.code)
            .joined(separator: "\n")

        #expect(!code.contains("DeviceOrientation"),
                "the capture protocol must not accept a held orientation at all")
        #expect(!code.contains("UIDevice"),
                "Services must not read a device orientation; the coordinator does")
    }
}
