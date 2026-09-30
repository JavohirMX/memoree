import Foundation
import SwiftData

/// Everything that can go wrong writing to the local store.
///
/// One enum per domain, `LocalizedError` for user-facing copy (AGENTS.md §6).
/// The fourth domain alongside `SchedulerError`, `CaptureError` and
/// `LibraryError`, and it exists because there was nowhere else to put these.
///
/// **Why this is not optional polish.** Without it, a `ModelContext.save()`
/// failure reaches the camera screen's error mapping as a bare `Error`, falls
/// through every typed case, and is rendered as
/// `error.localizedDescription` — a Core Data string in the user's hands. The
/// photographs would already be in Photos at that point, so the user has lost
/// nothing, and the message would say so in terms they cannot act on. A
/// message the user cannot act on is the same defect as no message
/// (AGENTS.md §6: every error path has a recoverable UI state).
enum StoreError: Error, LocalizedError, Equatable {

    /// A write failed. The moment is not recorded.
    case saveFailed(String)

    /// The store could not be opened at all. Unreachable in normal operation;
    /// `MemoreeApp` has a dedicated startup screen for it.
    case unavailable

    var errorDescription: String? {
        switch self {
        case .saveFailed:
            "Your photos are in your library, but Memoree could not write the "
                + "record. Try again."
        case .unavailable:
            "Memoree could not open its local store."
        }
    }

    /// Whether retrying the same write could plausibly succeed.
    ///
    /// A save failure is transient far more often than not — a locked file, a
    /// full disk, a container momentarily busy — and the photographs are still
    /// in memory, so retrying costs nothing and losing them would cost the
    /// moment.
    var isRetryable: Bool {
        switch self {
        case .saveFailed: return true
        case .unavailable: return false
        }
    }
}

extension StoreError {

    /// Wraps whatever the context threw.
    ///
    /// SwiftData's own errors are fine in a log and useless on a screen, so
    /// they are narrowed here rather than at every call site. The underlying
    /// reason is kept in the associated value because it is the only thing that
    /// makes a bug report actionable.
    static func wrapping(_ error: Error) -> StoreError {
        if let storeError = error as? StoreError { return storeError }
        return .saveFailed(error.localizedDescription)
    }
}
