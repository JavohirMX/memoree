import CryptoKit
import Foundation
import Testing

@testable import Memoree

/// Phase 1 — the moment derivation.
///
/// This is the riskiest logic in Memoree: a bug here is invisible until a user
/// notices their notification moved, or stopped moving. It is pure and
/// synchronous specifically so it can be tested by execution rather than by
/// inspection.
///
/// Golden vectors matter more than property tests here. A property test proves
/// the output is *in* the window; a golden vector proves the exact instant does
/// not drift when the implementation is refactored.
@Suite("Phase 1 — MomentDerivation")
struct MomentDerivationTests {

    /// Fixed 32-byte secret so vectors are reproducible.
    private static let secret = Data((0..<32).map { UInt8($0) })
    private static let otherSecret = Data((0..<32).map { UInt8(255 - Int($0)) })

    private static let window = TimeWindow.default   // 11:00–23:00
    private static let duration: TimeInterval = 120

    private func start(
        for day: String,
        window: TimeWindow = MomentDerivationTests.window,
        secret: Data = MomentDerivationTests.secret,
        duration: TimeInterval = MomentDerivationTests.duration,
        calendar: Calendar = .current
    ) throws -> Date {
        let dayIdentifier = try #require(DayIdentifier(string: day, calendar: calendar))
        return MomentDerivation.momentStart(
            for: dayIdentifier, window: window, secret: secret, windowDuration: duration
        )
    }

    // MARK: - Golden vectors

    /// Pinning the exact derived instant catches a refactor that changes the
    /// output while every property test still passes.
    ///
    /// Asserted as **seconds since local midnight**, not as a wall-clock time,
    /// so the vector is independent of the timezone the suite runs in.
    @Test("Golden vector — exact offset is stable")
    func goldenVectors() throws {
        let day = try #require(DayIdentifier(string: "2026-09-30"))

        let withSecretA = MomentDerivation.momentStart(
            for: day, window: Self.window, secret: Self.secret, windowDuration: Self.duration)
        #expect(Int(withSecretA.timeIntervalSince(day.date)) == 71_215)

        let withSecretB = MomentDerivation.momentStart(
            for: day, window: Self.window, secret: Self.otherSecret, windowDuration: Self.duration)
        #expect(Int(withSecretB.timeIntervalSince(day.date)) == 71_562)
    }

    @Test("The derived offset spans the full window rather than a narrow slice")
    func derivedOffsetsSpanTheWindow() throws {
        let day = try #require(DayIdentifier(string: "2026-09-30"))
        let moment = MomentDerivation.momentStart(
            for: day, window: Self.window, secret: Self.secret, windowDuration: Self.duration)

        // Inside the window, and not pinned to either extreme.
        let seconds = Int(moment.timeIntervalSince(day.date))
        #expect(seconds > Self.window.startMinutes * 60)
        #expect(seconds < Self.window.endMinutes * 60)
    }

    // MARK: - Determinism

    @Test("The same day, secret and window always derive the same instant")
    func isDeterministic() throws {
        let first = try start(for: "2026-09-30")
        for _ in 0..<100 {
            #expect(try start(for: "2026-09-30") == first)
        }
    }

    @Test("Different days derive different instants")
    func differentDaysDiffer() {
        var seen = Set<TimeInterval>()
        for offset in 0..<60 {
            let day = DayIdentifier(string: "2026-09-30")!.offset(by: offset)
            seen.insert(MomentDerivation.momentStart(
                for: day, window: Self.window, secret: Self.secret, windowDuration: Self.duration
            ).timeIntervalSince1970)
        }
        // Collisions are possible but should be vanishingly rare over 12h of span.
        #expect(seen.count > 55)
    }

    @Test("Different secrets reshuffle the schedule")
    func differentSecretsDiffer() {
        var differ = 0
        for offset in 0..<100 {
            let day = DayIdentifier(string: "2026-09-30")!.offset(by: offset)
            let a = MomentDerivation.momentStart(
                for: day, window: Self.window, secret: Self.secret, windowDuration: Self.duration)
            let b = MomentDerivation.momentStart(
                for: day, window: Self.window, secret: Self.otherSecret, windowDuration: Self.duration)
            if a != b { differ += 1 }
        }
        #expect(differ > 95)
    }

    // MARK: - Window containment

    @Test("Ten years of derived moments all land inside the configured window")
    func alwaysInsideWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        var cursor = try #require(DayIdentifier(string: "2026-01-01", calendar: calendar))
        let lower = Self.window.startMinutes * 60
        let upper = Self.window.endMinutes * 60

        for _ in 0..<3650 {
            let moment = MomentDerivation.momentStart(
                for: cursor, window: Self.window, secret: Self.secret, windowDuration: Self.duration)
            let seconds = Int(moment.timeIntervalSince(cursor.date))
            #expect(seconds >= lower && seconds <= upper,
                    "\(cursor.rawValue) derived \(seconds)s, outside [\(lower), \(upper)]")
            cursor = cursor.offset(by: 1, calendar: calendar)
        }
    }

    @Test("The distribution is not clumped toward any hour")
    func distributionIsSpread() {
        var calendar = Calendar(identifier: .gregorian)
        var cursor = DayIdentifier(string: "2026-01-01", calendar: calendar)!
        var buckets = [Int](repeating: 0, count: 12)   // 12 hourly buckets across the window

        for _ in 0..<12_000 {
            let moment = MomentDerivation.momentStart(
                for: cursor, window: Self.window, secret: Self.secret, windowDuration: Self.duration)
            let seconds = Int(moment.timeIntervalSince(cursor.date))
            buckets[min(11, (seconds - Self.window.startMinutes * 60) / 3600)] += 1
            cursor = cursor.offset(by: 1, calendar: calendar)
        }

        // Chi-squared against a uniform expectation, 11 degrees of freedom.
        let expected = 12_000.0 / 12.0
        let chiSquared = buckets.reduce(0.0) { $0 + pow(Double($1) - expected, 2) / expected }
        #expect(chiSquared < 40, "chi-squared \(chiSquared) indicates clumping: \(buckets)")
        #expect(buckets.allSatisfy { $0 > 0 }, "an hour bucket is empty: \(buckets)")
    }

    @Test("Extremes of the digest map to the ends of the window without overflowing")
    func offsetMappingIsBounded() {
        #expect(MomentDerivation.offsetSeconds(from: [UInt8](repeating: 0, count: 32), span: 43200) == 0)
        let maxDigest = [UInt8](repeating: 255, count: 32)
        let high = MomentDerivation.offsetSeconds(from: maxDigest, span: 43200)
        #expect(high >= 0 && high < 43200, "high digest produced \(high)")
        #expect(MomentDerivation.offsetSeconds(from: maxDigest, span: 0) == 0)
    }

    // MARK: - Configuration sensitivity

    @Test("Changing the window changes the derived moment")
    func windowAffectsDerivation() throws {
        let a = try start(for: "2026-09-30", window: TimeWindow(startMinutes: 9 * 60, endMinutes: 12 * 60))
        let b = try start(for: "2026-09-30", window: TimeWindow(startMinutes: 18 * 60, endMinutes: 23 * 60))
        #expect(a != b)
        // And each lands in its own window.
        let aSeconds = Int(a.timeIntervalSince(DayIdentifier(string: "2026-09-30")!.date))
        #expect(aSeconds >= 9 * 3600 && aSeconds <= 12 * 3600)
    }

    @Test("Changing the window duration reshuffles future moments")
    func durationAffectsDerivation() throws {
        let a = try start(for: "2026-09-30", duration: 120)
        let b = try start(for: "2026-09-30", duration: 180)
        #expect(a != b, "window duration must participate in the derivation")
    }

    @Test("The HMAC message is stable and field-delimited")
    func messageIsStable() {
        let day = DayIdentifier(string: "2026-09-30")!
        let message = MomentDerivation.message(
            for: day, window: Self.window, windowDuration: 120)
        let text = String(decoding: message, as: UTF8.self)
        #expect(text == "memoree.moment.v1|2026-09-30|660|1380|120")
    }

    // MARK: - DST

    @Test("A DST spring-forward day still derives a valid moment")
    func springForwardDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!

        let day = try #require(DayIdentifier(string: "2027-03-14", calendar: cal))
        let moment = MomentDerivation.momentStart(
            for: day, window: Self.window, secret: Self.secret, windowDuration: Self.duration)

        let seconds = Int(moment.timeIntervalSince(day.date))
        #expect(seconds >= Self.window.startMinutes * 60 && seconds <= Self.window.endMinutes * 60)
        // And the derived instant must still belong to the intended local day.
        #expect(DayIdentifier(date: moment, calendar: cal) == day)
    }
}
