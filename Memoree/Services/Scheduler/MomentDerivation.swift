import CryptoKit
import Foundation

/// Derives the daily moment time for a given day.
///
/// Pure, synchronous, deterministic: the same inputs always produce the same
/// moment. That property is what makes the riskiest logic in Memoree testable
/// against golden vectors instead of against a clock.
///
/// The alternative — seeding a random generator and persisting the result — also
/// works, but then a bug that re-rolls the moment is invisible until a user
/// notices their notification moved. Derivation makes re-rolling impossible by
/// construction: there is nothing to re-roll.
enum MomentDerivation {

    /// Derives the moment start for `day` inside `window`.
    ///
    /// - Parameters:
    ///   - day: The local calendar day.
    ///   - window: The configured daily window.
    ///   - secret: The per-install secret. Changes the entire schedule, so it is
    ///     held in the Keychain rather than `UserDefaults`.
    ///   - windowDuration: Capture window length. Reserved in the HMAC input so
    ///     that changing it reshuffles future days rather than silently
    ///     producing times that collide with an in-progress notification.
    /// - Returns: An instant inside `window` on `day`.
    static func momentStart(
        for day: DayIdentifier,
        window: TimeWindow,
        secret: Data,
        windowDuration: TimeInterval
    ) -> Date {
        precondition(!secret.isEmpty, "Derivation secret must not be empty")

        let message = Self.message(
            for: day,
            window: window,
            windowDuration: windowDuration
        )
        let digest = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: secret)
        )

        let offsetSeconds = Self.offsetSeconds(
            from: Array(digest),
            span: window.spanSeconds
        )
        return window.earliestStart(on: day).addingTimeInterval(TimeInterval(offsetSeconds))
    }

    /// The exact bytes fed to the HMAC.
    ///
    /// Field separator is `|` and fields are length-prefixed where ambiguity is
    /// possible, so that distinct inputs cannot collide into the same message.
    static func message(
        for day: DayIdentifier,
        window: TimeWindow,
        windowDuration: TimeInterval
    ) -> Data {
        let parts: [String] = [
            "memoree.moment.v1",
            day.rawValue,
            "\(window.startMinutes)",
            "\(window.endMinutes)",
            "\(Int(windowDuration.rounded()))",
        ]
        return Data(parts.joined(separator: "|").utf8)
    }

    /// Maps a digest to an offset within `[0, span)`.
    ///
    /// Uses the first 8 bytes as a big-endian `UInt64` and scales by the span.
    /// `UInt64.max` is approximated by `Double.greatestFiniteMagnitude`-safe
    /// arithmetic: dividing by `UInt64.max` then multiplying by `span` keeps the
    /// result strictly below `span` without an overflow path.
    static func offsetSeconds(from digest: [UInt8], span: Int) -> Int {
        precondition(digest.count >= 8, "SHA-256 digest is always 32 bytes")
        guard span > 0 else { return 0 }

        let value: UInt64 = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let fraction = Double(value) / Double(UInt64.max)
        let scaled = fraction * Double(span)
        // `.down` guarantees the result is within [0, span).
        return min(span - 1, max(0, Int(scaled.rounded(.down))))
    }
}
