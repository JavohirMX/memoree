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

    @Test("Lateness reads as days past 24h, not hours")
    func lateDescription() {
        // 5400s is 1h30m. Note that 90s is NOT — that is 1m, and asserting
        // otherwise masks a real bug in whichever direction it errs.
        #expect(CountdownFormatter.lateDescription(from: 5400) == "1h30m")
        #expect(CountdownFormatter.lateDescription(from: 90) == "1m")
        #expect(CountdownFormatter.lateDescription(from: 300) == "5m")
        #expect(CountdownFormatter.lateDescription(from: 6 * 86400) == "6d")
        // Negative lateness clamps rather than rendering a negative duration.
        #expect(CountdownFormatter.lateDescription(from: -60) == "0m")
    }
}
