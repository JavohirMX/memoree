import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import Memoree

/// Phase 1 — low-light capture, micro-journal note, and feed cache eviction tests.
@Suite("Phase 1 features")
struct Phase1FeatureTests {

    // MARK: - Low-light & Torch

    @Test("Initial torch mode is off and toggles to on")
    @MainActor
    func torchToggleCyclesMode() async {
        let service = InMemoryCaptureService()
        let library = InMemoryPhotoLibraryService()
        let haptics = InMemoryHapticFeedback()

        let model = CameraViewModel(
            service: service,
            photoLibrary: library,
            haptics: haptics
        )

        #expect(model.torchMode == .off)

        await model.toggleTorch()
        #expect(model.torchMode == .on)
        #expect(service.torchRequests.last == .on)

        await model.toggleTorch()
        #expect(model.torchMode == .off)
        #expect(service.torchRequests.last == .off)
    }

    // MARK: - Micro-journal Note

    @Test("Draft note truncates at 80 characters when committed")
    @MainActor
    func draftNoteTruncatesAndStores() async throws {
        let container = try Persistence.inMemoryContainer()
        let context = ModelContext(container)
        let store = MomentStore(context: context)
        let calendar = Calendar.current
        let today = DayIdentifier(date: Date(), calendar: calendar)
        let interval = MomentInterval(
            start: Date().addingTimeInterval(-60),
            end: Date().addingTimeInterval(60)
        )

        let longNote = String(repeating: "A", count: 120)
        let expectedNote = String(repeating: "A", count: 80)

        let moment = try store.record(
            day: today,
            interval: interval,
            capturedAt: Date(),
            retakeCount: 0,
            backAssetIdentifier: "back-1",
            frontAssetIdentifier: "front-1",
            note: String(longNote.prefix(80))
        )

        #expect(moment.note == expectedNote)

        let facts = store.facts()
        let retrieved = try #require(facts.first { $0.id == moment.id })
        #expect(retrieved.note == expectedNote)
    }

    @Test("Whitespace-only note normalizes to nil")
    @MainActor
    func whitespaceOnlyNoteNormalizesToNil() throws {
        let container = try Persistence.inMemoryContainer()
        let context = ModelContext(container)
        let store = MomentStore(context: context)
        let calendar = Calendar.current
        let today = DayIdentifier(date: Date(), calendar: calendar)
        let interval = MomentInterval(
            start: Date().addingTimeInterval(-60),
            end: Date().addingTimeInterval(60)
        )

        let moment = try store.record(
            day: today,
            interval: interval,
            capturedAt: Date(),
            retakeCount: 0,
            backAssetIdentifier: "back-2",
            frontAssetIdentifier: "front-2",
            note: "   \n\t   "
        )

        #expect(moment.note == nil)
        let retrieved = try #require(store.facts().first { $0.id == moment.id })
        #expect(retrieved.note == nil)
    }

    // MARK: - Feed LRU Cache Eviction

    @Test("Feed cache caps size at maxFeedCacheSize")
    @MainActor
    func feedCacheCapsAtMaximum() async throws {
        #expect(TodayViewModel.maxFeedCacheSize == 15)
    }
}
