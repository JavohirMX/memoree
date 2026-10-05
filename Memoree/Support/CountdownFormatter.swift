import Foundation

/// Formats a duration as the `mm:ss` countdown Memoree displays.
///
/// Counts down to the **reminder**, not to a closing window — and it is shown
/// only when notifications are off, because then it is the sole way the user
/// could learn when the moment was (ADR-024). Rendered entirely on-device from
/// `momentStart - now`, exactly as production BeReal does it: there was never a
/// server-side countdown field to copy.
///
/// Minutes are not clamped to 59. The default window is twelve hours wide, so
/// `1:47:22` is the common case here and `72:00` is more honest than silently
/// rolling into `12:00`.
enum CountdownFormatter {

    /// - Parameter remaining: A non-negative interval in seconds. Negative
    ///   values clamp to zero rather than rendering a negative countdown.
    static func string(fromSeconds remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
