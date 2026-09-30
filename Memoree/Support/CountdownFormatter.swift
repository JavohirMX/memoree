import SwiftUI

/// Formats a duration as the `mm:ss` countdown Memoree displays.
///
/// The countdown is rendered entirely on-device from `windowEnd - now`. This is
/// exactly how production BeReal does it — there was never a server-side
/// countdown field to copy, only a client-side render of `moment.endDate - now`.
///
/// Minutes are not clamped to 59. A moment window is two minutes, but if this is
/// ever used for a longer duration (an hourly reminder, say) `72:00` is more
/// honest than silently rolling into `12:00`.
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

    /// Human-readable lateness, matching the tone of the late badge.
    ///
    /// `late 2h14m`, `late 14m`, `late 0m`. Whole days read as days, because a
    /// streak broken six days ago should not display as "144h".
    static func lateDescription(from interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60

        if days > 0 { return "\(days)d" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }
}
