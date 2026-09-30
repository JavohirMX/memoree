import AVFoundation
import Foundation
import Testing

@testable import Memoree

/// DEVICE-ONLY diagnostic. Not part of any phase's exit criterion.
///
/// Exists because `LiveCaptureTests` failed on hardware with
/// `noInputAvailable(.back)` in five tests while the preceding test — which
/// calls the same device lookup — passed. That contradiction is the clue, and
/// guessing at it from the outside wastes more time than printing the state.
///
/// Run with:
///
/// ```sh
/// xcodebuild test -project Memoree.xcodeproj -scheme Memoree \
///   -destination 'platform=iOS,id=<your device>' \
///   -only-testing:MemoreeTests/CameraDiagnostics
/// ```
@Suite("Phase 4 — camera diagnostics", .serialized)
struct CameraDiagnostics {

    @Test("Prints authorization, device availability and TCC state")
    func printState() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("DIAG authorizationStatus(for: .video) = \(status.rawValue)")

        let back = CaptureFormatSelector.wideAngleDevice(for: .back)
        let front = CaptureFormatSelector.wideAngleDevice(for: .front)
        print("DIAG wideAngle back  = \(back == nil ? "nil" : "present")")
        print("DIAG wideAngle front = \(front == nil ? "nil" : "present")")

        // The full device list, which is non-empty even when `.default` returns
        // nil — that difference is the whole diagnosis if it turns out to be
        // authorization rather than hardware.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        print("DIAG discovery count = \(discovery.devices.count)")
        for device in discovery.devices {
            print("DIAG   device: \(device.deviceType.rawValue) pos=\(device.position.rawValue)")
        }

        // Can we actually *open* an input? `default` returning non-nil does not
        // mean the device can be opened — another app holding it, or a denied
        // authorisation, both fail here with a different error.
        if let back {
            do {
                let input = try AVCaptureDeviceInput(device: back)
                print("DIAG AVCaptureDeviceInput opened OK; ports = \(input.ports.count)")
            } catch {
                let nsError = error as NSError
                print("DIAG input open FAILED domain=\(nsError.domain) code=\(nsError.code)")
                print("DIAG   \(nsError.localizedDescription)")
            }
        }

        // The count of 3:4 formats, so a nil selection is distinguishable from
        // a nil device.
        if let back {
            let formats = back.formats
            let threeByFour = formats.filter {
                CaptureFormatSelector.isThreeByFour(
                    CaptureFormatSelector.dimensions(of: $0)
                )
            }
            print("DIAG formats total=\(formats.count) threeByFour=\(threeByFour.count)")

            // Every distinct dimension, so the sensor's actual orientation
            // convention is visible rather than inferred.
            var seen = Set<String>()
            for format in formats {
                let d = CaptureFormatSelector.dimensions(of: format)
                seen.insert("\(d.width)x\(d.height)")
            }
            print("DIAG distinct dimensions (\(seen.count)):")
            for entry in seen.sorted() { print("DIAG   \(entry)") }
        }
    }
}
