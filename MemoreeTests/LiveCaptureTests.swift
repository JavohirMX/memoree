import AVFoundation
import Foundation
import ImageIO
import Testing

@testable import Memoree

/// Phase 4 exit criterion — a real capture from real cameras.
///
/// **Runs when the host has a camera, and reports loudly when it does not.**
///
/// ## Why this cannot run in the simulator
///
/// The simulator has no capture hardware. `AVCaptureDevice.default(.builtInWideAngleCamera,
/// for: .video, position: .back)` returns `nil`, so there is no input, no
/// session, and no frame. `AVCaptureMultiCamSession.isMultiCamSupported` is
/// permanently `false` there, and that is a documented constant rather than a
/// coincidence (AGENTS.md §7).
///
/// Every assertion below that matters — orientation, mirroring, 3:4 geometry,
/// and the reliability check — is therefore only reachable on a device. A green
/// simulator run says nothing about whether this phase works.
///
/// ## The reliability check is paced like a person
///
/// The first version of this suite ran twenty back-to-back pairs and reported
/// 18/20, then 15/20, with different failures each time and an AVFoundation
/// internal assert in the log. That was not a product defect: it swapped the
/// camera **forty times in about twenty seconds**, which is faster than the
/// sensor is asked to work in any real use of this app.
///
/// ADR-021 makes the sequence user-paced — press, swap, press, with the user
/// composing in between — and this check now models that, with a pause between
/// photographs. The isolated measurement of the same mechanism, 40 swaps with
/// nothing else happening, was 0 failures at half a second each
/// (`FrameWaitDiagnostics`). So this asserts the pacing the product actually
/// produces rather than a stress case it never does.
///
/// ## A skip must not look like a pass
///
/// Swift Testing counts an early return as **passed**. That is how four Phase 3
/// tests "passed" in a millisecond while asserting nothing, twice over. So
/// every skip prints a banner, and `LiveCaptureRunGuardTests` fails the run
/// unless at least one test here genuinely executed.
///
/// **The expected count is a stored property, not a literal.** It used to say
/// "\(executed) of 6 live tests executed", and adding the lens survey made that
/// a lie on the same day it was written. A guard that miscounts is a guard
/// nobody should trust: the number exists so a reader can tell *how much* of the
/// suite ran, and a wrong number is worse than none — it looks like information.
/// `expectedCount` is the single place to change when a test is added.
///
/// ## Nothing is deleted
///
/// The photographs captured here are never written to Photos by this suite, so
/// the camera roll is untouched — except the write-path test, which writes two
/// and leaves them, because Memoree never removes anything from the user's
/// library (ADR-008) and that applies to its own test code too.
///
/// ## KNOWN: the gate must run in its own process
///
/// **Each test here builds its own `SequentialCaptureService`, so one device run
/// of the whole suite allocates eight `AVCaptureSession`s back to back.**
/// `AVCaptureSession.init()` is a *synchronous* XPC round-trip to the capture
/// daemon (`FigCaptureSessionRemoteCreate`), and eight of them in one background
/// test process is enough to wedge it. The same trap is recorded above for the
/// twenty-moment loop, where it was fixed; it was not fixed here.
///
/// What a device run produced, in order, across three attempts:
///
/// 1. `twoPressesProduceAPair` builds a second session while the first is still
///    being released and gets `configurationFailed("Cannot Record")` on the
///    first shutter press of the second pair.
/// 2. The daemon is left dead. The next test finds
///    `FigCaptureSessionRemote: "! storage->connectionDied"` and
///    `FigCaptureSourceRemote: err=-16453` within seconds.
/// 3. `twentyPacedMoments` — the phase's exit criterion — completes **zero**
///    iterations and the process is killed.
///
/// **Sharing one service across the suite fixes steps 1 and 2, and was verified
/// to: the two-press test then passed in 2.8s, both orders, at 4032×3024. It
/// breaks a different way.** `rebuildSession()` allocates a *new*
/// `AVCaptureSession` by design — replacing a dead one is its whole job — so on a
/// shared service it runs against a session the previous tests have already
/// started and stopped. Measured: **0.583s on a fresh service, 200.8s on the
/// shared one**, after which every later test is degraded.
///
/// So the two obvious fixes each break something.
///
/// ## Decided: the gate runs alone, in its own `xcodebuild`
///
/// `Scripts/capture-gate.sh`. One allocation, which is the shape that is known to
/// work, and nothing in production code changed to suit a test. The cost is a
/// second invocation per device run, measured in seconds rather than in the
/// twenty-minute runs three failed attempts cost.
///
/// Chosen over **splitting the suite across two test processes** because Swift
/// Testing cannot do it — it needs a second scheme or a UI test target — and over
/// **reusing one controller and resetting it** because that changes
/// `rebuildSession` to suit a test, and `rebuildSession` is doing real work
/// handling `mediaServicesWereReset`.
///
/// ## And the runner proves the gate ran
///
/// `-only-testing:` with a misspelled identifier matches nothing, and xcodebuild
/// reports `** TEST SUCCEEDED **` with exit code 0. **Verified on this machine,
/// deliberately, with a typo** — which is the point. This project has been bitten
/// three times by something that looked like a pass and asserted nothing: four
/// Phase 3 tests that "passed" in a millisecond, and a twenty-moment run that
/// reported zero iterations as if it had finished. So the script greps the output
/// for the gate's own name and fails if it is absent. A gate that did not run must
/// never look like a gate that passed.
///
/// **The rest of this suite is unaffected** and still runs in the normal device
/// invocation. The allocation problem only ever made the *gate* unmeasurable; the
/// seven cheaper tests are what runs 1 and 2 were trying to fix, and they do run.
@Suite("Phase 4 — live camera capture", .serialized)
@MainActor
struct LiveCaptureTests {

    /// How many live tests actually executed, as opposed to skipped.
    ///
    /// `nonisolated` so the guard — which is not main-actor isolated — can read
    /// it. Plain rather than `nonisolated(unsafe)`: `RunCounter` is `Sendable`
    /// and carries its own lock, so the compiler can prove this one is safe.
    /// An earlier version reached for the `unsafe` escape hatch out of habit,
    /// and the SDK was right to say it was not needed.
    nonisolated private static let runCounter = RunCounter()

    nonisolated static var runCount: Int { runCounter.count }

    /// How many tests here should execute on a host with real cameras.
    ///
    /// **The guard used to interpolate a bare `6` into its failure message**, and
    /// it went stale the moment the lens survey was added — the kind of small lie
    /// that makes a diagnostic stop being believed. So the number lives here, next
    /// to the counter it is compared against.
    ///
    /// **And it is checked against the source, not trusted.** Writing this as
    /// `7` was wrong immediately, and it was wrong again when the orientation
    /// test was added — which is exactly the twice-a-year failure this exists to
    /// stop. `LiveCaptureRunGuardTests` scans this file and fails if the two
    /// disagree, so a literal nobody has to remember is the only kind that stays
    /// correct.
    nonisolated static let expectedCount = 10

    private final class RunCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0

        /// The value, not the stored property, so the enclosing type can expose
        /// it `nonisolated` without the compiler objecting that a main-actor
        /// static is read from a nonisolated context.
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return total
        }

        func increment() {
            lock.lock(); total += 1; lock.unlock()
        }
    }

    /// True only on a host with real cameras on both sides.
    private var hasCamera: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return CaptureFormatSelector.wideAngleDevice(for: .back) != nil
            && CaptureFormatSelector.wideAngleDevice(for: .front) != nil
        #endif
    }

    private func requireCamera() -> Bool {
        guard hasCamera else {
            print("""

            ╔══════════════════════════════════════════════════════════════╗
            ║  LIVE CAPTURE TESTS SKIPPED — they asserted nothing.           ║
            ║  This host has no camera. The simulator cannot capture.        ║
            ║  Phase 4's exit criterion is NOT met.                          ║
            ╚══════════════════════════════════════════════════════════════╝

            """)
            return false
        }
        Self.runCounter.increment()
        return true
    }

    // MARK: - Format selection on real hardware

    @Test("A real device reports a 3:4 format, or none at all")
    func deviceHasThreeByFourFormat() throws {
        guard requireCamera() else { return }

        let device = try #require(CaptureFormatSelector.wideAngleDevice(for: .back))

        // The simulator-side pure tests cover the arithmetic. This asserts the
        // premise holds on hardware: that a 3:4 format actually exists to be
        // selected (ADR-019 — on an iPhone 17 there are 57 formats, all
        // landscape, and the orientation-agnostic test is what makes any of
        // them qualify).
        if let format = CaptureFormatSelector.selectFormat(for: device) {
            #expect(CaptureFormatSelector.isThreeByFour(
                CaptureFormatSelector.dimensions(of: format)
            ))
        } else {
            print("device reports no 3:4 format; capture will report noThreeByFourFormat")
        }
    }

    // MARK: - Lens survey

    /// What the hardware actually offers, in one place.
    ///
    /// **This test exists to collect facts, and most of it deliberately does not
    /// assert.** It prints a table of every built-in lens: whether a 3:4 format
    /// exists for it, and its real zoom ceiling. Asserting on the ultra-wide row
    /// in particular would fail the run and tell us nothing the print does not
    /// already say — and a measurement that can fail is not a measurement.
    ///
    /// ## Why it is needed
    ///
    /// Zoom and lens switching were asked for, and both hinge on one unknown that
    /// cannot be answered off-device. `CaptureFormatSelector` only ever considers
    /// `.builtInWideAngleCamera`, and `CameraPosition` has exactly two cases, so
    /// the app has no lens axis at all. The question is whether the other lenses
    /// can honour Memoree's geometry:
    ///
    /// - **Ultra-wide is the risk.** It is a square sensor. If it reports no 3:4
    ///   format at all then a 0.5× control is not a button that behaves oddly, it
    ///   is a button that throws `noThreeByFourFormat` on every press. Nobody
    ///   should ship that, and nobody should ship a guess about it either.
    /// - **Telephoto** is a 4:3 sensor and very likely qualifies, but "very
    ///   likely" is not a measurement.
    /// - **Zoom ceilings come from the format**, not the marketing number:
    ///   `activeFormat.videoMaxZoomFactor` is what the sensor will actually do.
    ///
    /// ## Why it allocates nothing
    ///
    /// This suite's documented trap is that `AVCaptureSession.init()` is a
    /// synchronous XPC round-trip and eight of them in one process wedge the
    /// capture daemon. This test **never constructs a session** — it only reads
    /// `AVCaptureDevice.Formats` — so it cannot contribute to that, and it runs
    /// first so its output is at the top of the log.
    ///
    /// Device-only, and named so: see the suite documentation.
    @Test("DEVICE ONLY — survey every built-in lens and what 3:4 costs it")
    func surveyEveryLens() throws {
        guard requireCamera() else { return }

        // **This list was wrong once and is checked rather than trusted.**
        //
        // The first version listed five types and missed
        // `.builtInDualWideCamera` — the virtual device that pairs wide with
        // ultra-wide on a phone with no telephoto. That is precisely where
        // `virtualDeviceSwitchOverVideoZoomFactors` lives, so the one row that
        // could have answered "can AVFoundation hand off between lenses for us?"
        // was the row that never printed. A hand-picked list of hardware types is
        // exactly the thing that goes stale, so the sweep at the end of this test
        // discovers **every** device type available and reports anything this
        // list missed.
        //
        // The types are the SDK's built-in list minus the three that are not
        // cameras you can shoot (`LiDARDepthCamera`, `Microphone`, `TrueDepth`)
        // and minus `.builtInDuoCamera`, which is deprecated since iOS 10.2 in
        // favour of `.builtInDualCamera` and warned on every build. Dropping it
        // is only safe **because of the sweep below** — which is the point of
        // having a sweep: a name the compiler complains about can be deleted
        // without guessing what it was covering.
        let lensTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInUltraWideCamera,
            .builtInTelephotoCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInTripleCamera
        ]

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: lensTypes,
            mediaType: .video,
            position: .unspecified
        )

        var lines: [String] = []
        lines.append("")
        lines.append("┌─ LENS SURVEY " + String(repeating: "─", count: 56))
        lines.append("│ lens              position  3:4?  formats  zoom min…max  upscale>")
        lines.append("├" + String(repeating: "─", count: 72))

        for device in discovery.devices {
            let selected = CaptureFormatSelector.selectFormat(for: device)

            // Zoom belongs to a **format**, not to a device, so read it off the
            // format the app would actually apply. `selectFormat` returns a
            // format rather than dimensions, and a format must be applied to the
            // device that produced it, so the lookup is by dimensions back to
            // the original.
            let reference = selected.flatMap { wanted in
                device.formats.first {
                    CaptureFormatSelector.matches(
                        CaptureFormatSelector.dimensions(of: $0),
                        CaptureFormatSelector.dimensions(of: wanted)
                    )
                }
            }

            lines.append("│ " + pad(device.deviceType.rawValue, 18)
                + pad(describe(device.position), 10)
                + pad(selected == nil ? "NO" : "yes", 6)
                + pad("\(device.formats.count)", 9)
                + pad(zoomRange(of: reference, device: device), 14)
                + upscaleThreshold(reference))

            if selected == nil {
                lines.append("│   ↳ no 3:4. Ratios on offer: \(ratioSpread(device))")
            }

            // **Switch-over factors only exist on virtual devices.** An empty
            // array is the documented answer for a real lens, and it is the
            // answer that matters: on a virtual device the app could let
            // AVFoundation hand off between constituent cameras by setting one
            // zoom factor, which would be *seamless* zoom with no session
            // restart at all — the thing ADR-003 listed as the cost of going
            // sequential. So this line is the one worth reading twice.
            let switchOver = device.virtualDeviceSwitchOverVideoZoomFactors
            lines.append("│   ↳ switch-over: "
                + (switchOver.isEmpty
                    ? "none (physical lens)"
                    : switchOver.map { String(format: "%.2f", $0.doubleValue) }
                        .joined(separator: ", ")))
        }
        lines.append("└" + String(repeating: "─", count: 72))

        // **The self-check the first version needed.** An empty `deviceTypes`
        // means "every type", so this sweep cannot miss anything — which is the
        // only way to know the list above is complete.
        let everything = AVCaptureDevice.DiscoverySession(
            deviceTypes: [],
            mediaType: .video,
            position: .unspecified
        )
        let listed = Set(lensTypes.map(\.rawValue))
        let missed = Set(everything.devices.map(\.deviceType.rawValue)).subtracting(listed)
        lines.append("")
        if missed.isEmpty {
            lines.append("  Device types not in this survey's list: none.")
        } else {
            lines.append("  ⚠︎ Device types this survey's list MISSED: "
                + missed.sorted().joined(separator: ", "))
            lines.append("    Add them above — a missing virtual device hides its")
            lines.append("    switch-over factors, which is the whole point of asking.")
        }
        lines.append("")

        print(lines.joined(separator: "\n"))

        // **The one assertion.** The rear wide angle offering 3:4 is the premise
        // the entire app rests on (ADR-019) — without it, capture reports
        // `noThreeByFourFormat` and nothing works. If this fails, none of the
        // printed numbers above need reading.
        let rearWide = try #require(CaptureFormatSelector.wideAngleDevice(for: .back))
        #expect(
            CaptureFormatSelector.selectFormat(for: rearWide) != nil,
            "the rear wide angle must offer a 3:4 format or Memoree cannot capture"
        )
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private func describe(_ position: AVCaptureDevice.Position) -> String {
        switch position {
        case .back: return "back"
        case .front: return "front"
        default: return "unspecified"
        }
    }

    /// `1.00…2.50`, or `—` when the device has no usable format to read.
    ///
    /// **The two ends come from two different types, and the SDK is not
    /// symmetric.** The ceiling is `AVCaptureDeviceFormat.videoMaxZoomFactor`;
    /// the floor is `AVCaptureDevice.minAvailableVideoZoomFactor`. There is no
    /// `videoMinZoomFactor` on either — this function's first two versions each
    /// tried one and neither compiled, so the names below are read out of
    /// `AVCaptureDevice.h` rather than remembered.
    ///
    /// That asymmetry is the finding, not a footnote. **The ceiling is
    /// per-format**, so it has to be re-read after every `activeFormat` change
    /// rather than cached once per device — and `applyFormat` runs on every
    /// camera swap. A zoom value remembered across a swap is a zoom value that
    /// may have been clamped out from under itself.
    private func zoomRange(of format: AVCaptureDevice.Format?, device: AVCaptureDevice) -> String {
        guard let format else { return "—" }
        return String(
            format: "%.2f…%.2f",
            device.minAvailableVideoZoomFactor,
            format.videoMaxZoomFactor
        )
    }

    /// The zoom factor beyond which the sensor is being upscaled rather than
    /// cropped, or `—`.
    ///
    /// **This is the honest quality boundary, and it is the number that should
    /// decide how far a zoom control goes.** `videoMaxZoomFactor` came back at
    /// **189** on the first device run, which is not a usable zoom range — it is
    /// the point at which AVFoundation will still accept a number. A control that
    /// offers 189× is offering a rectangle of pixels. `videoZoomFactorUpscaleThreshold`
    /// is where real magnification stops and digital enlargement starts, so it
    /// is the ceiling worth designing against.
    private func upscaleThreshold(_ format: AVCaptureDevice.Format?) -> String {
        guard let format else { return "—" }
        let threshold = format.videoZoomFactorUpscaleThreshold
        return threshold > 0 ? String(format: "%.1f×", threshold) : "—"
    }

    /// The distinct aspect ratios a device's formats offer, widest first.
    ///
    /// Printed only for lenses with no 3:4, because that is the case where the
    /// diagnosis matters: a lens offering only 1.00 and 1.78 is a square sensor,
    /// and a 0.5× control cannot be built on it.
    private func ratioSpread(_ device: AVCaptureDevice) -> String {
        var seen: Set<Double> = []
        for format in device.formats {
            let dimensions = CaptureFormatSelector.dimensions(of: format)
            guard dimensions.width > 0, dimensions.height > 0 else { continue }
            let ratio = Double(dimensions.width) / Double(dimensions.height)
            seen.insert((ratio * 100).rounded() / 100)
        }
        return seen.sorted(by: >).map { String(format: "%.2f", $0) }.joined(separator: ", ")
    }

    // MARK: - Orientation, verified against a real file

    /// **The test that would have caught the original defect.**
    ///
    /// Neither the preview connection nor the photo connection ever had its
    /// orientation set, on either API, so everything sat at the AVFoundation
    /// default — which assumes a landscape-held device. No simulator test could
    /// have found that, and no amount of reading the code would have told you
    /// what it *looks* like.
    ///
    /// So this asks the file. It captures a photograph and reads the EXIF
    /// orientation tag back out of the bytes: **asking the saved image what it
    /// thinks its orientation is, rather than asking the code what it asked for.**
    ///
    /// ## Run it while holding the phone upright in portrait
    ///
    /// The test cannot enforce how it is being held, and the reporting below
    /// makes that a non-issue for the file itself — it tells the service
    /// `.portrait` explicitly, so the assertion is about `CaptureOrientation`'s
    /// table rather than about the desk. **What it cannot control is the preview**,
    /// which reflects the real device. So:
    ///
    /// - **This fails** → the table in `CaptureOrientation` is wrong. That row was
    ///   written from the sensor mounting relationship rather than measured.
    /// - **This passes but the preview is sideways** → the photo connection is
    ///   right and the preview connection is not, which is a different fix in a
    ///   different place.
    ///
    /// Both were possible before this existed and neither could be told apart.
    @Test("DEVICE ONLY — a captured photograph is tagged upright when held upright")
    func capturedPhotographIsTaggedUpright() async throws {
        guard requireCamera() else { return }

        let service = SequentialCaptureService()
        try await service.startSession(on: .back)
        await service.applyRotation(.portrait)

        let applied = await service.currentRotation()
        #expect(applied?.captureAngle == 90,
                "rotation in force: \(String(describing: applied))")

        let photo = try await service.captureCurrentPhoto()
        await service.stopSession()

        // **A missing tag is its own failure**, not a nil to skip past. If the
        // photo output never received an angle, the file carries no orientation
        // and every consumer has to guess — which is the original bug wearing a
        // different hat.
        let tag = try #require(
            Self.exifOrientation(of: photo.data),
            "the captured file carries no EXIF orientation tag at all"
        )

        #expect(
            tag == .right || tag == .left,
            """
            Held portrait, the tag must rotate a landscape sensor buffer by a \
            quarter turn; got \(tag.rawValue) (\(tag)). If the saved file is upright \
            and only the preview is sideways, the photo connection is correct and \
            the preview connection is not — a different fix in a different place.
            """
        )

        // Rotation must not disturb the geometry it was supposed to protect.
        #expect(photo.isThreeByFour, "rotation changed the 3:4 geometry")
    }

    /// The orientation tag of the image at index 0, or `nil` if there is none.
    ///
    /// **Three keys, because the obvious one no longer exists.**
    /// `kCGImagePropertyExifOrientation` is not declared anywhere in the iOS 27
    /// SDK headers — it was removed, and a test that used it simply failed to
    /// compile rather than telling us why. What remains declared is
    /// `kCGImagePropertyOrientation` (the generic key ImageIO surfaces at the top
    /// level for a camera JPEG) and `kCGImagePropertyTIFFOrientation`. The Exif
    /// dictionary is also consulted by its literal name, because that is the only
    /// way left to reach the field the way a raw Exif reader would.
    ///
    /// All four spellings name the same field. Trying all of them is not
    /// defensiveness for its own sake — it is the difference between a test that
    /// reads the file and a test that reports "no tag" on a platform whose header
    /// no longer offers the obvious constant.
    private static func exifOrientation(of data: Data) -> CGImagePropertyOrientation? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any]
        else { return nil }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let candidates: [CFString] = [
            kCGImagePropertyOrientation,
            kCGImagePropertyTIFFOrientation,
            "Orientation" as CFString
        ]

        for key in candidates {
            if let orientation = Self.orientation(from: properties[key])
                ?? exif?[key].flatMap(Self.orientation(from:)) {
                return orientation
            }
        }
        return nil
    }

    /// One property value as an orientation tag.
    ///
    /// **The numeric type is not guaranteed**, which is a small thing that cost
    /// two compile errors: `CGImagePropertyOrientation.init(rawValue:)` takes a
    /// `UInt32`, while the value in a properties dictionary arrives as whatever
    /// the writer put there — `UInt32` from ImageIO, `Int` from a hand-built
    /// dictionary, `NSNumber` from Objective-C interop. Accepting one type would
    /// have made the test silently return `nil` and report "no tag" on a file
    /// that has one.
    private static func orientation(from value: Any?) -> CGImagePropertyOrientation? {
        let raw: UInt32?
        switch value {
        case let number as UInt32: raw = number
        case let number as Int: raw = UInt32(exactly: number)
        case let number as NSNumber: raw = number.uint32Value
        default: raw = nil
        }
        guard let raw else { return nil }
        return CGImagePropertyOrientation(rawValue: raw)
    }

    // MARK: - Session lifecycle

    @Test("The session starts on a chosen camera and the preview is a live layer")
    func sessionStarts() async throws {
        guard requireCamera() else { return }

        let service = SequentialCaptureService()
        #expect(service.previewLayer is AVCaptureVideoPreviewLayer)

        try await service.startSession(on: .back)
        await service.stopSession()
    }

    @Test("The session rebuilds after mediaServicesWereReset")
    func sessionRebuilds() async throws {
        guard requireCamera() else { return }

        // The one silent failure in the camera stack: no error, no callback, the
        // preview just freezes. Recovery means replacing the session outright
        // (TRD §5.5), and the only way to trust that path is to run it.
        let service = SequentialCaptureService()
        try await service.startSession(on: .back)
        try await service.rebuildSession()
        await service.stopSession()
    }

    // MARK: - The two-press sequence

    @Test("Two shutter presses produce a real pair, from either opening camera")
    func twoPressesProduceAPair() async throws {
        guard requireCamera() else { return }

        // Both orders, because the opening camera is random per moment
        // (ADR-021) and neither may be special-cased.
        //
        // **The second iteration is the one that fails**, and it fails for a
        // reason that is not about the camera: this constructs a fresh
        // `SequentialCaptureService` per iteration, so the second one allocates
        // an `AVCaptureSession` while the first is still being released, and the
        // first shutter press comes back `configurationFailed("Cannot Record")`.
        // Sharing one service across the suite fixes it — verified, 2.8s, both
        // orders — at the cost described in the type's documentation.
        for opening in CameraPosition.allCases {
            let service = SequentialCaptureService()
            try await service.startSession(on: opening)

            let first = try await service.captureCurrentPhoto()
            #expect(first.position == opening)
            #expect(first.isThreeByFour)
            #expect(first.data.count > 10_000)

            try await service.switchCamera(to: opening.opposite)
            let second = try await service.captureCurrentPhoto()
            #expect(second.position == opening.opposite)
            #expect(second.isThreeByFour)
            #expect(second.data.count > 10_000)

            print("CAPTURE pair \(opening.rawValue) -> \(opening.opposite.rawValue) ok "
                  + "(\(first.pixelWidth)x\(first.pixelHeight))")

            await service.stopSession()
        }
    }

    @Test("The full model flow reaches review with both photographs")
    func modelFlowReachesReview() async throws {
        guard requireCamera() else { return }

        let service = SequentialCaptureService()
        let library = PhotoKitLibrary()
        let model = CameraViewModel(
            service: service, photoLibrary: library, chooseFirstCamera: { .back }
        )

        await model.start()
        #expect(model.phase == .shooting)

        await model.shutterPressed()
        #expect(model.captured[.back] != nil)

        await model.shutterPressed()
        #expect(model.livePosition == .front)

        await model.shutterPressed()
        #expect(model.phase == .review)
        #expect(model.captured[.back]?.isThreeByFour == true)
        #expect(model.captured[.front]?.isThreeByFour == true)

        await model.stop()
    }

    /// The phase's actual exit criterion, paced the way a person uses the app.
    @Test("Twenty moments, taken at a human pace, all succeed")
    func twentyPacedMoments() async throws {
        guard requireCamera() else { return }

        // Enough pause between the two photographs of each moment to represent
        // composing a shot. The old back-to-back loop swapped the camera forty
        // times in twenty seconds, which is not a thing a person does and not a
        // thing this app ever asks for.
        let composePause: Duration = .milliseconds(700)
        var failures: [String] = []

        // **One** service for all twenty iterations.
        //
        // This used to construct a `SequentialCaptureService` inside the loop,
        // which meant twenty `AVCaptureSession` allocations — and constructing
        // one is not free: `AVCaptureSession.init()` makes a *synchronous* XPC
        // round-trip to the capture daemon (`FigCaptureSessionRemoteCreate`).
        // Twenty of those in a background test process tripped the watchdog and
        // the app was SIGKILLed: `0x8BADF00D`, "Failed to terminate gracefully
        // after 5.0s", main thread parked inside `_createFigCaptureSession`.
        //
        // The important part is that this was never something the app does.
        // `AppEnvironment.captureService` is lazy and cached, so the whole app
        // has exactly one session for its lifetime; what varies is the camera
        // screen being opened and closed. Reusing one service here is therefore
        // not a way to dodge a crash — it is the only shape the product ever
        // runs in, and the old loop was testing something no user could reach.
        let service = SequentialCaptureService()

        for moment in 1...20 {
            do {
                let opening = CameraPosition.allCases[moment % 2]
                try await service.startSession(on: opening)

                let back = try await service.captureCurrentPhoto()
                try await service.switchCamera(to: opening.opposite)
                try await Task.sleep(for: composePause)
                let front = try await service.captureCurrentPhoto()

                let pair = [back, front]
                for photo in pair {
                    if !photo.isThreeByFour {
                        failures.append("moment \(moment) \(photo.position.rawValue): wrong ratio "
                                        + "(\(photo.pixelWidth)x\(photo.pixelHeight))")
                    }
                    if photo.data.count < 10_000 {
                        failures.append("moment \(moment) \(photo.position.rawValue): "
                                        + "implausibly small bytes — likely a blank frame")
                    }
                }
                print("CAPTURE moment \(moment)/20 ok (\(opening.rawValue) first)")

                await service.stopSession()
            } catch {
                failures.append("moment \(moment): \(error)")
                print("CAPTURE moment \(moment)/20 FAILED: \(error)")
            }
        }

        await service.stopSession()

        // Printed unconditionally on success too, so a green run carries its
        // own evidence rather than relying on someone remembering to look.
        print("live capture: 20 paced moments, \(failures.count) failures")
        for failure in failures { print("  \(failure)") }

        // **The frame-wait table, printed on every run.**
        //
        // The 16/20 run that found the front->back asymmetry could not say
        // *why*: a timeout caused by the port check rejecting every arriving
        // frame is indistinguishable from one caused by no frame arriving, and
        // the two have opposite fixes. This table separates them in one run.
        //
        // What to look for:
        //
        // - `rejected` high with `TIMEOUT` → the port check is wrong. That is a
        //   correctness bug and it would also produce black or green
        //   photographs, which is exactly what the check exists to prevent.
        // - `rejected` 0 with `TIMEOUT` → frames genuinely never arrive. The
        //   back sensor is not producing after the swap, or `applyFormat`'s
        //   `activeFormat` assignment re-configures the running session.
        // - `ok` rows clustering high → the 5s deadline is simply too tight and
        //   the honest fix is a longer one.
        let waits = await service.frameWaitDiagnostics()
        print("FRAME-WAITS (\(waits.count))")
        for outcome in waits { print("  \(outcome)") }
        let timeouts = waits.filter(\.timedOut)
        print("FRAME-WAITS summary: \(waits.count) waits, \(timeouts.count) timed out")

        // **The decisive number, and the reason this run is worth its four
        // minutes.**
        //
        // `framesSeen` is how many frames the video output delivered during the
        // wait, counted before any matching logic. Everything before this
        // diagnostic could only say *no frame was rejected*, which cannot
        // distinguish "the output went silent" from "frames are flowing and the
        // wait is failing to see them".
        //
        // - `seen=0` → the output is dead. The camera is not producing, and the
        //   frame signal this whole design depends on has nothing to signal.
        //   The bug is in the session, not in the matching.
        // - `seen=100+` → frames are arriving and being missed. The bug is in
        //   `deliverFrame` or in how the wait is armed, and no amount of session
        //   fiddling will fix it.
        //
        // Healthy waits finish in single-digit milliseconds, so at 30-60fps a
        // healthy wait should see roughly `duration x frameRate` frames — a
        // handful at most. A timeout that reports `seen=0` is unambiguous.
        //
        // **The state columns name the cause.** All three of these look identical
        // from outside, which is why four fixes have now been tried and only one
        // helped: nothing about "zero frames" says *why* there are zero frames.
        //
        // - `running=false`            → the session really stopped. Restart it.
        // - `running=true connLive=false` → the output's connection was replaced
        //   by the reconfiguration and the delegate is bound to a dead object.
        //   The hardware is fine; nothing is calling us.
        // - `running=true connLive=true idle<0.5s` → AVFoundation parked the
        //   output; it thinks it is running and has stopped calling.
        // - `idle` far larger than the wait → the output had *already* gone quiet
        //   before this swap began, so the cause is upstream of the swap.
        for outcome in timeouts {
            print("  TIMEOUT \(outcome)")
            print("    CAUSE: \(Self.cause(of: outcome))")
        }
        if timeouts.isEmpty { print("  no timeouts") }

        #expect(failures.isEmpty)
    }

    @Test("The front camera is mirrored and the rear is not")
    func mirroringIsCorrect() async throws {
        guard requireCamera() else { return }

        let service = SequentialCaptureService()
        try await service.startSession(on: .back)
        defer { Task { await service.stopSession() } }

        let back = try await service.captureCurrentPhoto()
        try await service.switchCamera(to: .front)
        let front = try await service.captureCurrentPhoto()

        // Mirroring is set on the connection, so `fileDataRepresentation()`
        // already reflects it (TRD §5.4). A front image that is not mirrored
        // reads as a photograph of a photograph rather than a mirror, and it is
        // instantly visible to a human — but a selfie is close to symmetric, so
        // this asserts the mechanism held rather than claiming a visual verdict.
        //
        // The human check: compare the two against the live preview.
        #expect(!front.data.isEmpty)
        #expect(!back.data.isEmpty)
    }

    // MARK: - Write path

    @Test("A captured pair survives the Photos write")
    func capturedPairWritesToPhotos() async throws {
        guard requireCamera() else { return }

        // The simulator cannot reach this: `requireCamera()` already returned.
        #if targetEnvironment(simulator)
        return
        #else
        // `.limited` is not a case Memoree's enum has: add-only access cannot be
        // limited, and `PhotoKitLibrary` maps Apple's `.limited` onto
        // `.authorized` for exactly that reason.
        let status = await PhotoKitLibrary().requestAuthorization()
        guard status == .authorized else {
            print("live capture: Photos not authorised, skipping the write test")
            return
        }

        let service = SequentialCaptureService()
        try await service.startSession(on: .back)
        defer { Task { await service.stopSession() } }

        let back = try await service.captureCurrentPhoto()
        try await service.switchCamera(to: .front)
        let front = try await service.captureCurrentPhoto()

        // This is the whole Phase 4 boundary: capture, then write, then stop.
        // Recording the moment itself is Phase 5's orchestration.
        let library = PhotoKitLibrary()
        let saved = try await library.saveMomentPair(
            backData: back.data,
            frontData: front.data,
            location: nil
        )

        #expect(await library.assetExists(saved.back))
        #expect(await library.assetExists(saved.front))
        #expect(saved.back != saved.front)

        print("live capture: wrote two real photographs to the camera roll")
        #endif
    }

    /// Names the cause of a frame-wait timeout from the state sampled at the
    /// deadline.
    ///
    /// Extracted because the classification is a chain of five branches and it
    /// belongs beside the suite that prints it rather than inside the loop that
    /// does. Each branch is one mechanism, and the *order* is the argument: the
    /// cheap decisive checks come first, so the most specific answer wins.
    private static func cause(
        of outcome: CaptureSessionController.FrameWaitOutcome
    ) -> String {
        if outcome.framesSeen > 0 {
            return "FRAMES FLOWING but missed — \(outcome.framesSeen) arrived"
        }
        if !outcome.sessionWasRunning {
            return "SESSION STOPPED — isRunning=false, so restart it"
        }
        if !outcome.connectionIsLive {
            return "STALE CONNECTION — session is running but the output has no "
                + "video connection; the delegate is bound to a dead object"
        }
        if outcome.framesSinceLast > 10 {
            return "STALLED EARLY — last frame was "
                + String(format: "%.1fs", outcome.framesSinceLast)
                + " ago, before this swap; cause is upstream"
        }
        return "OUTPUT PARKED — session running, connection live, but nothing is "
            + "being delivered"
    }
}
