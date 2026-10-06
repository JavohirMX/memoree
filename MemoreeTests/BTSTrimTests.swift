import Foundation
import Testing

@testable import Memoree

/// The trim arithmetic, exhaustively.
///
/// `BTSTrim` is the only part of Behind the Scenes that can be reasoned about
/// without a camera, a microphone or an export session, so it is where the
/// rules live: which part of a continuous recording survives, what happens when
/// the recording is shorter than the request, and when there is nothing worth
/// keeping at all.
///
/// **Table-driven rather than one test per case**, because the interesting
/// failures are the *boundaries* — one second either side of the floor, the
/// recording exactly as long as the request — and a hand-written test per case
/// tends to assert the cases someone thought of.
@Suite("BTSTrim — keeping the last N seconds")
struct BTSTrimTests {

    // MARK: - The shape of the window

    @Test("A long recording keeps the tail, and the tail is the clip")
    func keepsTheTail() throws {
        let window = try #require(BTSTrim.window(recordedDuration: 30, clipDuration: 5))

        // ADR-013: BTS is the few seconds *before* the shutter. A recording
        // opened when the camera screen appeared and trimmed at commit must
        // yield the moment, so the kept range ends at the recording's end.
        #expect(window.start == 25)
        #expect(window.duration == 5)
        #expect(window.end == 30)
    }

    @Test("The kept range never runs past the recording")
    func neverRunsPast() throws {
        for recorded in [0.5, 1, 5, 5.0001, 12, 600, 3600] {
            for requested in [0.5, 1, 5, 6.42, 15, 100] {
                let window = try #require(
                    BTSTrim.window(recordedDuration: recorded, clipDuration: requested),
                    "no window for \(recorded)s recorded, \(requested)s requested"
                )
                #expect(window.start >= 0, "negative start for \(recorded)/\(requested)")
                #expect(window.duration > 0, "non-positive duration for \(recorded)/\(requested)")
                #expect(window.end <= recorded + 1e-9,
                        "end \(window.end) past recording \(recorded) for \(requested)")
                #expect(window.start + window.duration >= window.start,
                        "inverted range for \(recorded)/\(requested)")
            }
        }
    }

    @Test("A recording shorter than the request keeps all of it")
    func shortRecordingKeepsEverything() throws {
        // Asking for 5 seconds of a 2-second recording cannot conjure the other
        // 3, and refusing to produce a clip at all would lose the two seconds
        // that do exist.
        let window = try #require(BTSTrim.window(recordedDuration: 2, clipDuration: 5))

        #expect(window.start == 0)
        #expect(window.duration == 2)
    }

    @Test("A recording exactly as long as the request is a whole-recording clip")
    func exactLength() throws {
        let window = try #require(BTSTrim.window(recordedDuration: 5, clipDuration: 5))

        #expect(window.start == 0)
        #expect(window.duration == 5)
    }

    @Test("One second either side of an exact length never produces a gap or an overrun")
    func eitherSideOfExact() throws {
        let shorter = try #require(BTSTrim.window(recordedDuration: 4.999, clipDuration: 5))
        #expect(shorter.start == 0)
        #expect(shorter.duration == 4.999)

        let longer = try #require(BTSTrim.window(recordedDuration: 5.001, clipDuration: 5))
        #expect(abs(longer.start - 0.001) < 1e-9)
        #expect(abs(longer.duration - 5) < 1e-9)
    }

    // MARK: - The zero-length guard

    @Test("Nothing shorter than the floor produces a clip")
    func belowFloorProducesNothing() {
        // The guard the plan called for. Clamping at zero prevents an *inverted*
        // range; this prevents a range so short it is a frozen frame, which
        // `AVAssetExportSession` would happily write into the user's library.
        #expect(BTSTrim.window(recordedDuration: 0.49, clipDuration: 5) == nil)
        #expect(BTSTrim.window(recordedDuration: 0, clipDuration: 5) == nil)
        #expect(BTSTrim.window(recordedDuration: -3, clipDuration: 5) == nil)
    }

    @Test("Exactly the floor is kept, and the boundary is pinned from both sides")
    func floorBoundary() throws {
        // A boundary asserted from one side is a boundary that can move.
        let atFloor = try #require(BTSTrim.window(recordedDuration: 0.5, clipDuration: 5))
        #expect(atFloor.start == 0)
        #expect(atFloor.duration == 0.5)

        #expect(BTSTrim.window(recordedDuration: 0.4999, clipDuration: 5) == nil)
    }

    @Test("A non-positive request produces nothing rather than a negative range")
    func nonPositiveRequest() {
        #expect(BTSTrim.window(recordedDuration: 12, clipDuration: 0) == nil)
        #expect(BTSTrim.window(recordedDuration: 12, clipDuration: -5) == nil)
    }

    @Test("A request shorter than the floor keeps what was asked for, not nothing")
    func requestBelowFloor() throws {
        // The floor guards the *recording*, not the user's preference. Asking
        // for a third of a second is a strange thing to ask for and a thing the
        // user is entitled to; refusing it would make the setting disagree with
        // the recorder about what is possible.
        let window = try #require(BTSTrim.window(recordedDuration: 12, clipDuration: 0.2))

        #expect(abs(window.start - 11.8) < 1e-9)
        #expect(abs(window.duration - 0.2) < 1e-9)
    }

    @Test("A recording long enough to satisfy a short request is trimmed to it")
    func shortRequestOnLongRecording() throws {
        let window = try #require(BTSTrim.window(recordedDuration: 30, clipDuration: 0.2))

        #expect(abs(window.start - 29.8) < 1e-9)
        #expect(abs(window.duration - 0.2) < 1e-9)
    }

    // MARK: - Floating point

    @Test("Floating-point inputs do not produce a range that starts after it ends")
    func floatingPointNeverInverts() {
        // `start` and `duration` are computed by subtraction, so a value chosen
        // to be unrepresentable is the realistic failure: an inverted range,
        // which `AVAssetExportSession` rejects with no error the caller can
        // act on.
        for recorded in stride(from: 0.5, through: 60, by: 0.37) {
            for requested in stride(from: 0.1, through: 15, by: 0.13) {
                guard let window = BTSTrim.window(
                    recordedDuration: recorded, clipDuration: requested
                ) else { continue }
                #expect(window.duration > 0, "zero duration at \(recorded)/\(requested)")
                #expect(
                    window.end >= window.start,
                    "inverted range at \(recorded)/\(requested): \(window)"
                )
                #expect(window.duration <= recorded + 1e-9,
                        "longer than the recording at \(recorded)/\(requested)")
            }
        }
    }

    @Test("A recording whose duration is exactly representable keeps it exactly")
    func exactlyRepresentable() throws {
        // 0.1 and 0.2 are not representable in binary floating point, and
        // `5.0 - 0.2` is not `4.8`. The assertion is on the *relationship* — the
        // kept range still ends at the recording's end — rather than on a
        // literal, because a literal here would be asserting the representation
        // error rather than the behaviour.
        let window = try #require(BTSTrim.window(recordedDuration: 5.0, clipDuration: 0.2))

        #expect(abs(window.end - 5.0) < 1e-12)
        #expect(window.start + window.duration == window.end)
    }

    // MARK: - Validated duration

    @Test("The default is five seconds, as ADR-013 specifies")
    func defaultIsFive() {
        #expect(BTSTrim.defaultClipDuration == 5)
    }

    @Test("A requested duration is clamped into a meaningful range")
    func validationClamps() {
        #expect(BTSTrim.validatedClipDuration(5) == 5)
        #expect(BTSTrim.validatedClipDuration(0) == BTSTrim.minimumRecordedDuration)
        #expect(BTSTrim.validatedClipDuration(-100) == BTSTrim.minimumRecordedDuration)
        #expect(BTSTrim.validatedClipDuration(999) == BTSTrim.maximumClipDuration)
    }

    @Test("A corrupt duration degrades to the default rather than passing through")
    func validationOnNonFinite() {
        // The same reason `TimeWindow.validated` exists: this reads a persisted
        // `Double`, and `NaN` fails every comparison — so a `min(max(…))` over a
        // NaN returns the NaN rather than clamping it.
        #expect(BTSTrim.validatedClipDuration(.nan) == BTSTrim.defaultClipDuration)
        #expect(BTSTrim.validatedClipDuration(.infinity) == BTSTrim.maximumClipDuration)
        #expect(BTSTrim.validatedClipDuration(-.infinity) == BTSTrim.minimumRecordedDuration)
    }

    @Test("A validated duration always produces a window from a real recording")
    func validatedDurationAlwaysUsable() throws {
        // The point of validating against the floor: after clamping, a setting
        // read from the store and a recording at the floor agree.
        let window = try #require(
            BTSTrim.window(
                recordedDuration: BTSTrim.minimumRecordedDuration,
                clipDuration: BTSTrim.validatedClipDuration(0)
            )
        )
        #expect(window.duration == BTSTrim.minimumRecordedDuration)
    }

    // MARK: - Multi-segment windows

    @Test("Dual-camera recordings split the clip duration equally when both are long enough")
    func multiSegmentEqualSplit() throws {
        let windows = try #require(
            BTSTrim.windows(recordedDurations: [10, 8], clipDuration: 6)
        )
        #expect(windows.count == 2)
        #expect(windows[0].index == 0)
        #expect(windows[0].window.start == 7) // 10 - 3
        #expect(windows[0].window.duration == 3)

        #expect(windows[1].index == 1)
        #expect(windows[1].window.start == 5) // 8 - 3
        #expect(windows[1].window.duration == 3)
    }

    @Test("A shorter segment lends its unused duration to the longer segment")
    func multiSegmentBorrowing() throws {
        let windows = try #require(
            BTSTrim.windows(recordedDurations: [1, 10], clipDuration: 6)
        )
        #expect(windows.count == 2)
        // Segment 0 only has 1s, so it keeps 1s (all of it)
        #expect(windows[0].window.start == 0)
        #expect(windows[0].window.duration == 1)
        // Segment 1 borrows the remaining 2s, keeping 3 + 2 = 5s
        #expect(windows[1].window.start == 5) // 10 - 5
        #expect(windows[1].window.duration == 5)
    }

    @Test("Combined duration below the floor produces no windows")
    func multiSegmentBelowFloorProducesNil() {
        #expect(BTSTrim.windows(recordedDurations: [0.2, 0.2], clipDuration: 5) == nil)
        #expect(BTSTrim.windows(recordedDurations: [], clipDuration: 5) == nil)
        #expect(BTSTrim.windows(recordedDurations: [5, 5], clipDuration: 0) == nil)
    }

    @Test("A single segment produces identical window to single window calculation")
    func singleSegmentMatches() throws {
        let windows = try #require(
            BTSTrim.windows(recordedDurations: [10], clipDuration: 5)
        )
        #expect(windows.count == 1)
        #expect(windows[0].window.start == 5)
        #expect(windows[0].window.duration == 5)
    }
}
