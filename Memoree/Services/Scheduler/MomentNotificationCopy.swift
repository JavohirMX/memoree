import Foundation

/// Pure value model holding engaging, pressure-free copy for daily moment notifications
/// and streak-saver evening reminders.
///
/// ## Why varied prompts
/// The original notification was a static "It's time. You have 2 minutes to capture a moment."
/// Per ADR-023 and ADR-032, captures have no time limits or lateness penalties. Removing
/// the artificial 2-minute deadline and providing diverse, playful prompts invites the user
/// to capture an honest snapshot of their day without unnecessary anxiety.
enum MomentNotificationCopy {

    struct Prompt: Equatable, Sendable {
        let title: String
        let body: String
    }

    /// Curated prompts encouraging spontaneity and memory keeping without time pressure.
    static let prompts: [Prompt] = [
        Prompt(
            title: "What are you up to right now? 👀",
            body: "Capture a memory of this moment."
        ),
        Prompt(
            title: "Time to make a Memoree 📸",
            body: "Capture what's right in front of you."
        ),
        Prompt(
            title: "Pause for a second ✨",
            body: "Snap today's memory before it slips away."
        ),
        Prompt(
            title: "How's your day going? ☀️",
            body: "Take a quick memory of what you're doing."
        ),
        Prompt(
            title: "Look up from what you're doing 🌿",
            body: "Capture the scene and yourself."
        ),
        Prompt(
            title: "A memory in the making ⏳",
            body: "Take a spontaneous shot of your day."
        ),
        Prompt(
            title: "Where are you right now? 📍",
            body: "Save this moment in your timeline."
        ),
        Prompt(
            title: "Spontaneous moment! ⚡️",
            body: "Front and back camera — show your world."
        ),
        Prompt(
            title: "Stop and capture ⏱️",
            body: "Take today's memory whenever you're ready."
        ),
        Prompt(
            title: "Today's chapter 📖",
            body: "Add a snapshot to your personal archive."
        ),
        Prompt(
            title: "Capture this moment 📷",
            body: "Show what your day looks like right now."
        ),
        Prompt(
            title: "Hey! What's happening? 👋",
            body: "Take a two-sided snapshot of your day."
        )
    ]

    /// Selects a prompt deterministically from the day's identifier.
    ///
    /// Uses a stable hash of the day string so the selected prompt is identical across
    /// multiple app launches and horizon refreshes.
    static func prompt(for day: DayIdentifier) -> Prompt {
        let scalarSum = day.rawValue.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        let index = abs(scalarSum) % prompts.count
        return prompts[index]
    }

    // MARK: - Streak Saver

    /// Notification prompt for the evening streak-saver reminder.
    static let streakSaverPrompt = Prompt(
        title: "Keep your streak going! 🔥",
        body: "You haven't captured a memory today yet. Take a moment before the day ends!"
    )
}
