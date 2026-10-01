import Testing

@testable import Memoree

/// Phase 0 smoke test.
///
/// Its only job is to prove the test target links, runs, and can see the app
/// target. Real coverage starts in Phase 1 with the moment scheduler.
@Suite("Phase 0 — toolchain")
struct Phase0SmokeTests {

    @Test("App target is linked into the test bundle")
    func appTargetIsLinked() {
        // Reference a symbol from the app target. If linking were broken this
        // would not compile, which is the point.
        #expect(Theme.Color.canvas == .black)
    }

    @Test("Countdown renders mm:ss with tabular-safe padding")
    func countdownFormatting() {
        #expect(CountdownFormatter.string(fromSeconds: 120) == "02:00")
        #expect(CountdownFormatter.string(fromSeconds: 60) == "01:00")
        #expect(CountdownFormatter.string(fromSeconds: 0) == "00:00")
        // Negative time clamps rather than rendering a negative countdown.
        #expect(CountdownFormatter.string(fromSeconds: -5) == "00:00")
    }

    @Test("Countdown does not roll into hours below an hour")
    func countdownUnderOneHour() {
        #expect(CountdownFormatter.string(fromSeconds: 3599) == "59:59")
    }

    @Test("Countdown keeps counting past an hour rather than wrapping")
    func countdownOverOneHour() {
        // The default window is twelve hours wide, so `h:mm:ss` is the common
        // case for the one configuration that shows a countdown at all — and it
        // is shown *before* the moment, counting hours down. Wrapping to `mm:ss`
        // would render 12:00:00 as 00:00 and read as an imminent moment.
        #expect(CountdownFormatter.string(fromSeconds: 3600) == "1:00:00")
        #expect(CountdownFormatter.string(fromSeconds: 12 * 3600) == "12:00:00")
        #expect(CountdownFormatter.string(fromSeconds: 3600 + 90) == "1:01:30")
    }
}
