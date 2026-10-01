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
    ///
    /// ## `StreakRecord` used to be here
    ///
    /// A stored `current` and `longest`, never written and never read. It
    /// contradicted TRD §7, which recomputes the streak on every read precisely
    /// because "a stored counter is one more thing that can drift out of
    /// agreement with the archive" — and it was still a live SwiftData model,
    /// which means it still owned a table and still appeared in every migration
    /// check. A registered-but-unused model is not free.
    ///
    /// Removing a model from a schema is a **destructive migration**: existing
    /// stores are reset. Free before a release, and worth stating rather than
    /// discovering after someone has an archive worth keeping.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            Moment.self,
            DayRecord.self,
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
