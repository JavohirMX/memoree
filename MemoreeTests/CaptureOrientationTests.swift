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

    @Test("The front camera is mounted a half turn from the rear")
    func frontIsHalvedFromRear() throws {
        // **This is the row written from the mounting relationship rather than
        // measured**, and it is the one to distrust. The front sensor is mounted
        // 180° from the rear, and the app also mirrors the front, so the two
        // concerns interact and a wrong entry here shows up as a selfie that is
        // upside down — after the whole feature has shipped.
        //
        // Compared in integer degrees because `%` is unavailable on `CGFloat`,
        // which is the same reason the implementation does its arithmetic in
        // quarter turns.
        let front = try #require(
            CaptureOrientation.rotation(for: .portrait, position: .front)
        )
        let rear = try #require(
            CaptureOrientation.rotation(for: .portrait, position: .back)
        )
        #expect((Int(front.previewAngle) + 180) % 360 == Int(rear.previewAngle))

        // And it holds for every orientation, not just portrait.
        for orientation in DeviceOrientation.allCases {
            guard let frontAngle = CaptureOrientation.rotation(for: orientation, position: .front),
                  let rearAngle = CaptureOrientation.rotation(for: orientation, position: .back)
            else { continue }
            #expect(
                (Int(frontAngle.previewAngle) + 180) % 360 == Int(rearAngle.previewAngle),
                "\(orientation): front \(frontAngle.previewAngle) rear \(rearAngle.previewAngle)"
            )
        }
    }

    @Test("Every angle the table can produce is one AVFoundation accepts")
    func everyAngleIsSupported() {
        // **Only 0, 90, 180 and 270 are legal**, and setting anything else throws
        // `NSInvalidArgumentException` — a crash, not an error, and not one that
        // any test would otherwise reach. So the property is asserted over the
        // whole input space rather than over the four values in the table.
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
