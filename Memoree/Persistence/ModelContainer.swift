import Foundation
import SwiftData

/// The SwiftData stack.
///
/// Configuration lives here rather than being scattered so that the persistence
/// shape can be inspected in one place during review.
enum Persistence {

    /// The production container. Store data lives in the app's Application
    /// Support directory, excluded from iCloud backup by the URL resource value
    /// below — moment metadata is device-local by design (ADR-001), and
    /// replicating it would quietly become a sync mechanism.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            Moment.self,
            DayRecord.self,
            StreakRecord.self,
            AppSettings.self,
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none     // No CloudKit. No server, no sync (ADR-001).
        )

        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// A container backed by memory only, for tests and previews.
    static func inMemoryContainer() throws -> ModelContainer {
        try makeContainer(inMemory: true)
    }
}
