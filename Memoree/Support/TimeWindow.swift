import Foundation

/// The daily window inside which Memoree chooses the moment time.
///
/// Defaults to 11:00–23:00 local, replicating the band production BeReal
/// observes. The lower bound exists so the notification never wakes you at 3am;
/// the app is meant to be unpredic­table, not hostile.
///
/// A window's span must be at least 60 seconds, otherwise there is no meaningful
/// randomness and the derivation below degenerates. Validation clamps rather
/// than traps, because these values come from user settings.
struct TimeWindow: Equatable, Hashable, Sendable, Codable {

    /// Minutes from local midnight. Valid range 0...1440.
    let startMinutes: Int

    /// Minutes from local midnight. Valid range 0...1440, and > `startMinutes`.
    let endMinutes: Int

    /// Minimum span. Below this the moment is effectively fixed, which defeats
    /// the purpose of the app.
    static let minimumSpanSeconds = 60

    /// Replicates BeReal's observed delivery band: 11:00 to 23:00 local.
    static let `default` = TimeWindow(startMinutes: 11 * 60, endMinutes: 23 * 60)

    init(startMinutes: Int, endMinutes: Int) {
        self = Self.validated(startMinutes: startMinutes, endMinutes: endMinutes)
    }

    /// Clamps a possibly-invalid configuration into something usable.
    ///
    /// Never traps and never returns a degenerate window. Used on every read of
    /// persisted settings, so a corrupt store degrades to defaults rather than
    /// bricking the app.
    static func validated(startMinutes: Int, endMinutes: Int) -> TimeWindow {
        let spanFloor = minimumSpanSeconds / 60   // 1 minute, rounded up below

        var start = min(max(startMinutes, 0), 24 * 60)
        var end = min(max(endMinutes, 0), 24 * 60)

        // Start at or before end, with at least the minimum span.
        if end <= start {
            // Wrap the user's intent rather than discarding it: a window of
            // 23:00–07:00 means "overnight", which some users will expect.
            if end == start { end = 24 * 60 }
        }

        // Enforce the span, extending `end` first, then pulling `start` back.
        if end - start < spanFloor {
            if end + spanFloor <= 24 * 60 {
                end = start + spanFloor
            } else {
                end = 24 * 60
                start = max(0, end - spanFloor)
            }
        }
        _ = start
        return TimeWindow(start: start, end: end)
    }

    private init(start: Int, end: Int) {
        self.startMinutes = start
        self.endMinutes = end
    }

    /// Total width of the window in seconds.
    var spanSeconds: Int {
        (endMinutes - startMinutes) * 60
    }

    var isValid: Bool {
        startMinutes >= 0
            && endMinutes <= 24 * 60
            && endMinutes > startMinutes
            && spanSeconds >= Self.minimumSpanSeconds
    }

    /// The earliest instant this window can produce, on `day`.
    func earliestStart(on day: DayIdentifier, calendar: Calendar = .current) -> Date {
        day.date.addingTimeInterval(TimeInterval(startMinutes * 60))
    }

    /// The latest instant this window can produce, on `day`.
    func latestStart(on day: DayIdentifier, calendar: Calendar = .current) -> Date {
        day.date.addingTimeInterval(TimeInterval(endMinutes * 60))
    }

    /// The last possible moment start on `day`, given a window duration.
    /// A moment must still be able to open, so the window cannot end the day.
    func latestStartAllowingWindow(
        of duration: TimeInterval,
        on day: DayIdentifier,
        calendar: Calendar = .current
    ) -> Date {
        let hardEnd = latestStart(on: day, calendar: calendar)
        let withRoom = hardEnd.addingTimeInterval(-duration)
        return max(earliestStart(on: day, calendar: calendar), withRoom)
    }
}

extension TimeWindow {
    /// Human-readable bounds for the Settings picker, e.g. `"11:00 – 23:00"`.
    ///
    /// `Self.format` is a static member of the same struct. Swift would
    /// otherwise infer this getter as mutating, which makes it unusable on a
    /// `let` binding — so `Self.` is spelled out explicitly to keep the getter
    /// non-mutating.
    var displayBounds: String {
        let start = TimeWindow.format(minutes: startMinutes)
        let end = TimeWindow.format(minutes: endMinutes)
        return "\(start) – \(end)"
    }

    private static func format(minutes: Int) -> String {
        let clamped = min(max(minutes, 0), 24 * 60)
        let hour = clamped / 60
        let minute = clamped % 60
        // 1440 is end-of-day, not a 24:00 clock time users would misread.
        if clamped == 24 * 60 { return "24:00" }
        return String(format: "%02d:%02d", hour, minute)
    }
}
