import AVFoundation
import Foundation
import Testing

@testable import Memoree

/// DEVICE-ONLY diagnostic: isolates the frame-wait and measures it.
///
/// **Why this exists.** Five device runs of `twentyConsecutiveCaptures` each
/// produced a different failure, and each had to be diagnosed by reading an
/// error message and inferring which of ten steps produced it. The pattern
/// across runs was consistent — roughly eight captures succeed, then
/// `noDeliveredFrame(.front)`, then the session wedges — which points at the
/// frame-wait as the weak step, but that was an inference.
///
/// This measures it directly. It performs the input swap and the frame-wait
/// *without* a photo capture, so the two concerns separate, and reports the
/// distribution rather than a pass or fail. A wait that occasionally takes
/// four seconds against a two-second deadline is a completely different
/// problem from one that is genuinely dead, and the two are indistinguishable
/// from an error message.
///
/// Run with:
///
/// ```sh
/// xcodebuild test -project Memoree.xcodeproj -scheme Memoree \
///   -destination 'platform=iOS,id=<your device>' \
///   -only-testing:MemoreeTests/FrameWaitDiagnostics
/// ```
@Suite("Phase 4 — frame-wait diagnostics", .serialized)
struct FrameWaitDiagnostics {

    private var hasCamera: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return CaptureFormatSelector.wideAngleDevice(for: .back) != nil
                && CaptureFormatSelector.wideAngleDevice(for: .front) != nil
        #endif
    }

    @Test("Measures how long a delivered frame takes after each input swap")
    func measureFrameWait() async throws {
        guard hasCamera else {
            print("frame-wait diagnostic: no camera on this host, skipped")
            return
        }

        let controller = CaptureSessionController()
        if controller.authorizationStatus() != .authorized {
            _ = await controller.requestAuthorization()
        }
        try await controller.startSession()

        var waits: [TimeInterval] = []
        var failures: [String] = []

        // Forty swaps: twenty round trips, the same count as the reliability
        // loop, so the failure point is comparable.
        for index in 1...40 {
            let target: CameraPosition = index.isMultiple(of: 2) ? .back : .front
            let start = Date()
            do {
                try await controller.swapInput(to: target)
                waits.append(Date().timeIntervalSince(start))
            } catch {
                waits.append(Date().timeIntervalSince(start))
                failures.append("swap \(index) -> \(target.rawValue): \(error)")
                print("SWAP \(index)/40 -> \(target.rawValue) FAILED after "
                      + String(format: "%.3f", Date().timeIntervalSince(start)) + "s: \(error)")
                // Recover, so one failure does not end the measurement.
                try? await controller.rebuildSession()
            }
        }

        await controller.stopSession()

        guard !waits.isEmpty else { return }

        let sorted = waits.sorted()
        let total = waits.reduce(0, +)
        print("FRAMEWAIT summary:")
        print("  swaps      = \(waits.count)")
        print("  failures   = \(failures.count)")
        for failure in failures { print("    \(failure)") }
        print(String(format: "  min        = %.3fs", sorted.first ?? 0))
        print(String(format: "  median     = %.3fs", sorted[sorted.count / 2]))
        print(String(format: "  p90        = %.3fs", sorted[Int(Double(sorted.count - 1) * 0.9)]))
        print(String(format: "  max        = %.3fs", sorted.last ?? 0))
        print(String(format: "  mean       = %.3fs", total / Double(waits.count)))
        // The number that matters: how close the slowest wait ran to the
        // 2s deadline in the controller.
        print("  deadline   = \(CaptureSessionController.frameWaitTimeoutForDiagnostics)s")
    }
}
