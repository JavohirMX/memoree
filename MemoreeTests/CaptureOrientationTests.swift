import CoreGraphics
import Foundation
import Testing

@testable import Memoree

/// Phase 4 — the rotation applied to the preview and photo connections.
///
/// ## Why this is worth a table test at all
///
/// The defect was that **nothing set an orientation**, on either connection, on
/// either API. Everything sat at the AVFoundation default, which assumes a
/// landscape-held device — so the symptom could not be reproduced or diagnosed
/// off-device at all, because there is no camera in the simulator.
///
/// That means the *mapping* is the only part that can be tested without
/// hardware, so it is tested exhaustively, and the part that cannot is a live
/// test that reads the EXIF tag back out of a photograph. Between them there is
/// no untested step: the table says what angle goes where, and the device says
/// whether that produced an upright picture.
@Suite("Phase 4 — capture orientation")
struct CaptureOrientationTests {

    // MARK: - The table

    @Test("Held upright in portrait, the rear camera gets a quarter turn")
    func portraitRear() throws {
        let orientation = try #require(
            CaptureOrientation.rotation(for: .portrait, position: .back)
        )
        // A rear sensor is upright when the phone is held landscape, so portrait
        // is one quarter turn — and 90° is the value that makes a native 3:4
        // sensor produce a portrait photograph rather than a sideways one.
        #expect(orientation.previewAngle == 90)
        #expect(orientation.captureAngle == 90)
    }

    @Test("The four held orientations are a quarter turn apart, in order")
    func theFourAreDistinct() throws {
        let rear = try [
            DeviceOrientation.portrait,
            .landscapeLeft,
            .portraitUpsideDown,
            .landscapeRight
        ].map { try #require(CaptureOrientation.rotation(for: $0, position: .back)) }

        // 90, 0, 270, 180 — a full turn with no repeats. A table with a duplicate
        // is the failure that makes two orientations photograph identically and
        // nobody notices until a user does.
        #expect(rear.map(\.previewAngle) == [90, 0, 270, 180])
        #expect(Set(rear.map(\.previewAngle)).count == 4, "two orientations collide")
    }

    @Test("Each held orientation saves the photograph the way it was held")
    func eachOrientationMapsToItsOwnAngle() throws {
        // **The claim the feature exists to make**, stated as a table so the whole
        // mapping is visible in one place: held portrait saves portrait, held
        // landscape saves landscape.
        //
        // A rear sensor is natively landscape, so a portrait photo is a quarter
        // turn and a landscape one is not. Everything else — the EXIF tag that
        // ends up in the file, and whether the saved image is tall or wide — is
        // downstream of this row.
        let expected: [DeviceOrientation: Int] = [
            .portrait: 90,
            .landscapeLeft: 0,
            .portraitUpsideDown: 270,
            .landscapeRight: 180
        ]

        for (orientation, degrees) in expected {
            let resolved = try #require(
                CaptureOrientation.rotation(for: orientation, position: .back),
                "\(orientation) did not resolve"
            )
            #expect(Int(resolved.captureAngle) == degrees, "\(orientation)")
            #expect(Int(resolved.previewAngle) == degrees, "\(orientation) preview")
        }
    }

    @Test("A flat phone keeps the rotation it has")
    func faceUpKeepsWhatItHas() {
        // **The case that makes `rotation` return `nil`.** Face-up and face-down
        // are how a phone lies on a table; there is no orientation to report, and
        // the answer is to keep what is applied rather than pick a default. The
        // alternative rotates the preview under someone who has done nothing,
        // which is worse than a stale rotation.
        for flat in [DeviceOrientation.faceUp, .faceDown, .unknown] {
            #expect(
                CaptureOrientation.rotation(for: flat, position: .back) == nil,
                "\(flat) should defer, not decide"
            )
        }
    }

    @Test("The front camera is never rotated")
    func frontIsLeftAlone() {
        // **This test replaces one that asserted the opposite, and the replacement
        // is the more important half of the story.**
        //
        // The first version derived a half turn for the front from the sensor
        // mounting relationship and tested that it was consistent across all four
        // orientations. It passed, it was internally coherent, and it was wrong:
        // the front preview came out rotated when it had been correct before,
        // because **nothing set any orientation until this feature, and the front
        // camera was already right on the AVFoundation default.**
        //
        // So the front is now never touched. The assertion is deliberately about
        // *absence*: every orientation resolves to `nil` for `.front`, meaning
        // the connection keeps whatever AVFoundation gave it.
        //
        // A test that checked the front agreed with a mounting diagram could only
        // have confirmed the diagram. This one pins what someone actually saw.
        for orientation in DeviceOrientation.allCases {
            #expect(
                CaptureOrientation.rotation(for: orientation, position: .front) == nil,
                "\(orientation): the front camera must be left as AVFoundation set it"
            )
        }
    }

    @Test("Every angle the table can produce is one AVFoundation accepts")
    func everyAngleIsSupported() {
        // **Only 0, 90, 180 and 270 are legal**, and setting anything else throws
        // `NSInvalidArgumentException` — a crash, not an error, and not one that
        // any test would otherwise reach. So the property is asserted over the
        // whole input space rather than over the four values in the table.
        //
        // The front camera contributes nothing here: it resolves to `nil` for
        // every orientation, so no angle from it can ever reach a connection.
        for orientation in DeviceOrientation.allCases {
            for position in CameraPosition.allCases {
                guard let resolved = CaptureOrientation.rotation(for: orientation, position: position)
                else { continue }
                #expect(CaptureOrientation.isSupported(resolved.previewAngle),
                        "\(orientation)/\(position) preview \(resolved.previewAngle)")
                #expect(CaptureOrientation.isSupported(resolved.captureAngle),
                        "\(orientation)/\(position) capture \(resolved.captureAngle)")
            }
        }
    }

    @Test("The rejected angles are the ones AVFoundation would throw on")
    func isSupportedRejectsQuarterIncrements() {
        for legal in [CGFloat(0), 90, 180, 270] {
            #expect(CaptureOrientation.isSupported(legal))
        }
        for illegal in [CGFloat(45), 1, -90, 360, 89.9] {
            #expect(!CaptureOrientation.isSupported(illegal), "\(illegal) would throw")
        }
    }

    @Test("The first frame is portrait, not the camera's landscape default")
    func startupIsUpright() {
        // **A portrait startup rather than a zero rotation.** The app is
        // portrait-first (ADR-019), and a first frame that appears sideways is
        // what a user notices before anything else — including, in the original
        // code, the only thing they noticed.
        #expect(CaptureOrientation.startup.previewAngle == 90)
        #expect(CaptureOrientation.startup.captureAngle == 90)
    }
}
