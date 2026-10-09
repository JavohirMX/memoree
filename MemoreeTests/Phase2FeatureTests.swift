import Foundation
import SwiftData
import Testing

@testable import Memoree

/// Phase 2 — Flashbacks ("On This Day") and App Intents test suite.
@Suite("Phase 2 features")
struct Phase2FeatureTests {

    @Test("Flashback queries matching month and day from prior years")
    @MainActor
    func flashbackQueriesPriorYears() throws {
        let container = try Persistence.inMemoryContainer()
        let context = ModelContext(container)
        let store = MomentStore(context: context)
        let calendar = Calendar.current

        var dateComponents2024 = DateComponents()
        dateComponents2024.year = 2024
        dateComponents2024.month = 10
        dateComponents2024.day = 8
        dateComponents2024.hour = 14
        let date2024 = try #require(calendar.date(from: dateComponents2024))
        let day2024 = DayIdentifier(date: date2024, calendar: calendar)

        var dateComponents2025 = DateComponents()
        dateComponents2025.year = 2025
        dateComponents2025.month = 10
        dateComponents2025.day = 8
        dateComponents2025.hour = 15
        let date2025 = try #require(calendar.date(from: dateComponents2025))
        let day2025 = DayIdentifier(date: date2025, calendar: calendar)

        var dateComponents2026 = DateComponents()
        dateComponents2026.year = 2026
        dateComponents2026.month = 10
        dateComponents2026.day = 8
        dateComponents2026.hour = 16
        let date2026 = try #require(calendar.date(from: dateComponents2026))
        let day2026 = DayIdentifier(date: date2026, calendar: calendar)

        // Different day
        var dateComponentsOther = DateComponents()
        dateComponentsOther.year = 2024
        dateComponentsOther.month = 10
        dateComponentsOther.day = 9
        dateComponentsOther.hour = 12
        let dateOther = try #require(calendar.date(from: dateComponentsOther))
        let dayOther = DayIdentifier(date: dateOther, calendar: calendar)

        let interval = MomentInterval(start: Date(), end: Date().addingTimeInterval(120))

        try store.record(day: day2024, interval: interval, capturedAt: date2024, retakeCount: 0, backAssetIdentifier: "b-24", frontAssetIdentifier: "f-24")
        try store.record(day: day2025, interval: interval, capturedAt: date2025, retakeCount: 0, backAssetIdentifier: "b-25", frontAssetIdentifier: "f-25")
        try store.record(day: day2026, interval: interval, capturedAt: date2026, retakeCount: 0, backAssetIdentifier: "b-26", frontAssetIdentifier: "f-26")
        try store.record(day: dayOther, interval: interval, capturedAt: dateOther, retakeCount: 0, backAssetIdentifier: "b-other", frontAssetIdentifier: "f-other")

        // Querying for 2026-10-08: should find 2024 and 2025, but not 2026 (current year) or dateOther
        let flashbacks = store.flashbackMoments(for: date2026)
        #expect(flashbacks.count == 2)
        #expect(flashbacks.map(\.day.rawValue) == ["2024-10-08", "2025-10-08"])
    }

    @Test("AppIntent requests camera on shared environment")
    @MainActor
    func captureIntentRequestsCamera() async throws {
        let env = try AppEnvironment(
            photoLibrary: InMemoryPhotoLibraryService(),
            captureService: InMemoryCaptureService(),
            haptics: InMemoryHapticFeedback()
        )
        #expect(AppEnvironment.shared === env)
        #expect(env.pendingCameraRequest == false)

        let intent = CaptureMomentIntent()
        _ = try await intent.perform()

        #expect(env.pendingCameraRequest == true)
        env.consumeCameraRequest()
        #expect(env.pendingCameraRequest == false)
    }

    @Test("Flipbook export calls library service")
    @MainActor
    func flipbookExportInvokesService() async throws {
        let photoLibrary = InMemoryPhotoLibraryService()
        photoLibrary.setAuthorization(.authorized)
        let env = try AppEnvironment(
            photoLibrary: photoLibrary,
            captureService: InMemoryCaptureService(),
            haptics: InMemoryHapticFeedback()
        )

        let store = env.momentStore
        let day = DayIdentifier(date: Date())
        let interval = MomentInterval(start: Date(), end: Date().addingTimeInterval(120))
        try store.record(day: day, interval: interval, capturedAt: Date(), retakeCount: 0, backAssetIdentifier: "back-1", frontAssetIdentifier: "front-1")

        let model = ArchiveViewModel(environment: env)
        model.load()
        #expect(model.moments.count >= 1)

        let success = await model.exportFlipbook()
        #expect(success == true)
        #expect(model.exportError == nil)
    }
}
