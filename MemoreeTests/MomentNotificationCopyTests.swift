import Foundation
import Testing

@testable import Memoree

@Suite("MomentNotificationCopy — Pressure-free varied notification copy")
struct MomentNotificationCopyTests {

    @Test("Prompts are deterministic for any given DayIdentifier")
    func deterministicPerDay() throws {
        let day1 = try #require(DayIdentifier(string: "2026-10-06"))
        let day2 = try #require(DayIdentifier(string: "2026-10-06"))

        let prompt1 = MomentNotificationCopy.prompt(for: day1)
        let prompt2 = MomentNotificationCopy.prompt(for: day2)

        #expect(prompt1 == prompt2)
    }

    @Test("Consecutive days yield a varied selection of prompts")
    func variedAcrossDays() throws {
        let startDay = try #require(DayIdentifier(string: "2026-10-01"))
        var uniquePrompts = Set<String>()

        for offset in 0..<30 {
            let day = startDay.offset(by: offset)
            let prompt = MomentNotificationCopy.prompt(for: day)
            uniquePrompts.insert(prompt.title)
        }

        // Must hit multiple distinct prompts over 30 days
        #expect(uniquePrompts.count >= 5)
    }

    @Test("No prompt contains countdowns, time limits, or lateness pressure")
    func noTimePressureInCopy() {
        let forbidden = ["2 minute", "two minute", "time limit", "deadline", "late", "countdown", "hurry"]

        for prompt in MomentNotificationCopy.prompts {
            let combined = "\(prompt.title) \(prompt.body)".lowercased()
            for phrase in forbidden {
                #expect(!combined.contains(phrase), "Prompt '\(prompt.title)' contains forbidden phrase '\(phrase)'")
            }
        }
    }

    @Test("Streak saver prompt encourages streak preservation")
    func streakSaverEncouragement() {
        let streakSaver = MomentNotificationCopy.streakSaverPrompt
        #expect(!streakSaver.title.isEmpty)
        #expect(!streakSaver.body.isEmpty)
        #expect(streakSaver.title.contains("streak") || streakSaver.body.contains("streak"))
    }
}
