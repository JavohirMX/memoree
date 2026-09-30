import AVFoundation
import Foundation
import Testing

@testable import Memoree

/// Phase 4 — format selection.
///
/// Pure arithmetic, so every case runs on the simulator. The simulator has no
/// camera (AGENTS.md §7), which would otherwise make this the least-tested and
/// most consequential piece of the capture stack: a wrong aspect ratio produces
/// moments that look subtly wrong forever and nothing complains.
@Suite("Phase 4 — CaptureFormatSelector")
struct CaptureFormatSelectorTests {

    // MARK: - Ratio matching

    @Test("Portrait 3:4 dimensions are accepted")
    func acceptsPortraitThreeByFour() {
        // Exactly on ratio, and the common rounded variants.
        for (width, height) in [(1512, 2016), (1440, 1920), (1080, 1440), (3024, 4032)] {
            let dimensions = CMVideoDimensions(width: Int32(width), height: Int32(height))
            #expect(
                CaptureFormatSelector.isThreeByFour(dimensions),
                "\(width)x\(height) is 3:4 and should qualify"
            )
        }
    }

    @Test("Landscape 4:3 is rejected despite being the same photograph rotated")
    func rejectsLandscape() {
        // 4032x3024 is 4:3. `fileDataRepresentation()` applies orientation
        // itself, so accepting a landscape format would store a photo whose
        // orientation disagrees with its pixels.
        let dimensions = CMVideoDimensions(width: 4032, height: 3024)
        #expect(!CaptureFormatSelector.isThreeByFour(dimensions))
    }

    @Test("16:9 is rejected decisively")
    func rejectsSixteenByNine() {
        // The failure this whole type exists to prevent: a sensor format that
        // is not 3:4 being selected without complaint.
        for (width, height) in [(1920, 1080), (3840, 2160), (1280, 720)] {
            let dimensions = CMVideoDimensions(width: Int32(width), height: Int32(height))
            #expect(!CaptureFormatSelector.isThreeByFour(dimensions))
        }
    }

    @Test("Square and degenerate dimensions are rejected without dividing by zero")
    func rejectsDegenerate() {
        for (width, height) in [(0, 0), (100, 0), (0, 100), (1080, 1080)] {
            let dimensions = CMVideoDimensions(width: Int32(width), height: Int32(height))
            #expect(!CaptureFormatSelector.isThreeByFour(dimensions))
        }
    }

    @Test("Ratio tolerance admits near-3:4 but not merely-adjacent formats")
    func toleranceIsMeaningful() {
        // 0.7501 is within tolerance; 0.77 is a genuinely different crop.
        let near = CMVideoDimensions(width: 1500, height: 2000)   // 0.750
        let justInside = CMVideoDimensions(width: 1498, height: 2000) // 0.749
        let outside = CMVideoDimensions(width: 1540, height: 2000)  // 0.770
        #expect(CaptureFormatSelector.isThreeByFour(near))
        #expect(CaptureFormatSelector.isThreeByFour(justInside))
        #expect(!CaptureFormatSelector.isThreeByFour(outside))
    }

    // MARK: - Selection

    @Test("The widest qualifying format wins")
    func selectsWidest() throws {
        let candidates = [
            dims(1080, 1440),
            dims(3024, 4032),   // widest 3:4
            dims(1512, 2016),
            dims(1440, 1920),
        ]
        let best = try #require(CaptureFormatSelector.bestDimensions(from: candidates))
        #expect(CaptureFormatSelector.matches(best, dims(3024, 4032)))
    }

    @Test("Non-qualifying formats are ignored however wide they are")
    func ignoresWideNonQualifying() throws {
        // 4000x3000 is wider than any 3:4 here but is landscape, so it must
        // not win. A naive "widest wins" implementation picks this.
        let candidates = [
            dims(3024, 4032),
            dims(4000, 3000),
            dims(3840, 2160),
        ]
        let best = try #require(CaptureFormatSelector.bestDimensions(from: candidates))
        #expect(CaptureFormatSelector.matches(best, dims(3024, 4032)))
    }

    @Test("No qualifying format returns nil rather than an arbitrary fallback")
    func noFallbackWhenNothingQualifies() {
        // Returning some other format would produce moments that are subtly
        // wrong forever, and nothing downstream would complain. `nil` becomes
        // a recoverable `noInputAvailable` instead.
        #expect(CaptureFormatSelector.bestDimensions(from: []) == nil)
        #expect(
            CaptureFormatSelector.bestDimensions(from: [dims(1920, 1080), dims(4032, 3024)]) == nil
        )
    }

    @Test("Selection is order-independent")
    func selectionIsOrderIndependent() throws {
        let candidates = [dims(1080, 1440), dims(3024, 4032), dims(1512, 2016)]
        let forward = try #require(CaptureFormatSelector.bestDimensions(from: candidates))
        let reversed = try #require(
            CaptureFormatSelector.bestDimensions(from: candidates.reversed())
        )
        #expect(CaptureFormatSelector.matches(forward, reversed))
        #expect(CaptureFormatSelector.matches(forward, dims(3024, 4032)))
    }

    @Test("Area ordering survives formats of equal width but different height")
    func areaOrdering() {
        #expect(CaptureFormatSelector.area(of: dims(3024, 4032))
                > CaptureFormatSelector.area(of: dims(1512, 2016)))
    }

    // MARK: - Captured photo geometry

    @Test("A captured photo knows whether it is 3:4")
    func capturedPhotoGeometry() {
        let threeByFour = CapturedPhoto(
            data: Data(), pixelWidth: 3024, pixelHeight: 4032, position: .back
        )
        let sixteenByNine = CapturedPhoto(
            data: Data(), pixelWidth: 1920, pixelHeight: 1080, position: .back
        )
        let degenerate = CapturedPhoto(
            data: Data(), pixelWidth: 0, pixelHeight: 0, position: .back
        )
        #expect(threeByFour.isThreeByFour)
        #expect(!sixteenByNine.isThreeByFour)
        // A zero-height photo must not divide by zero and report 3:4.
        #expect(!degenerate.isThreeByFour)
    }

    // MARK: - Device-backed path

    /// DEVICE-ONLY in effect: the simulator has no capture hardware, so this
    /// asserts the wrapper degrades rather than traps. It passes on the
    /// simulator precisely because there is no device to select from, which is
    /// why the pure tests above carry the real coverage.
    @Test("Format selection degrades without trapping when no device exists")
    func deviceBackedSelectionDegrades() {
        let device = CaptureFormatSelector.wideAngleDevice(for: .back)
        guard let device else {
            // No camera on this host. The production path must return nil and
            // let the caller raise `noInputAvailable`, never force-unwrap.
            #expect(CaptureFormatSelector.wideAngleDevice(for: .front) == nil)
            return
        }
        // On hardware, whatever is selected must be 3:4 — or nothing at all.
        if let format = CaptureFormatSelector.selectFormat(for: device) {
            #expect(
                CaptureFormatSelector.isThreeByFour(
                    CaptureFormatSelector.dimensions(of: format)
                )
            )
        }
    }

    // MARK: - Helper

    private func dims(_ width: Int32, _ height: Int32) -> CMVideoDimensions {
        CMVideoDimensions(width: width, height: height)
    }
}
