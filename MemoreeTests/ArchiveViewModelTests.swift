import Foundation
import Testing
import UIKit

@testable import Memoree

/// Phase 6 — the archive.
///
/// Two halves, and the split matters because only one of them has ever been
/// tested:
///
/// - **`ArchiveViewModel`** is pure-ish: rows in, grid state out, no views. It
///   is where the "500 moments must not mean 500 simultaneous Photos requests"
///   claim lives, and where the tombstone-then-recompute behaviour lives.
/// - **The cache** is a service concern, so what is asserted here is that the
///   view model *asks* for the right things — which identifiers, at what size,
///   how many at a time.
///
/// **No test drives the grid itself.** There is no UI test target in this
/// project, and adding one is a larger decision than this phase. So the layout
/// is verified by hand on a device and the scroll-performance claim is verified
/// with the DEBUG seeder, both recorded in the phase notes. What is tested here
/// is everything that would be expensive to notice by eye.
@Suite("Phase 6 — archive")
@MainActor
struct ArchiveViewModelTests {

    private let calendar = Calendar(identifier: .gregorian)
    private typealias FixedScheduler = TestSupport.Scheduler

    // MARK: - Harness

    private struct Harness {
        let environment: AppEnvironment
        let library: InMemoryPhotoLibraryService
        let store: MomentStore
    }

    private func makeHarness(
        now: Date,
        momentStart: Date? = nil
    ) throws -> Harness {
        let library = InMemoryPhotoLibraryService()
        library.setAuthorization(.authorized)

        let start = momentStart
            ?? DayIdentifier(date: now, calendar: calendar).date.addingTimeInterval(14 * 3600)

        let environment = try AppEnvironment(
            container: try Persistence.inMemoryContainer(),
            momentScheduler: FixedScheduler(start: start),
            photoLibrary: library,
            captureService: InMemoryCaptureService()
        )
        return Harness(
            environment: environment,
            library: library,
            store: environment.momentStore
        )
    }

    /// Records `count` consecutive days ending yesterday, each with real
    /// photographs in the in-memory library.
    ///
    /// Yesterday and not today, so the archive is a *history* — a grid whose
    /// newest row is always the one the Today screen is already showing tests
    /// half the problem.
    private func recordHistory(
        _ harness: Harness,
        days: Int,
        endingAt end: Date
    ) async throws {
        var cursor = DayIdentifier(date: end, calendar: calendar)
        for _ in 0..<days {
            cursor = cursor.offset(by: -1, calendar: calendar)
            let start = cursor.date.addingTimeInterval(14 * 3600)
            _ = try await harness.library.saveMomentPair(
                backData: Self.pixelPNG, frontData: Self.pixelPNG, location: nil
            )
            let pair = try #require(harness.library.latestPair)
            try harness.store.record(
                day: cursor,
                interval: MomentInterval(start: start, end: start.addingTimeInterval(120)),
                capturedAt: start.addingTimeInterval(30),
                retakeCount: 0,
                backAssetIdentifier: pair.back,
                frontAssetIdentifier: pair.front
            )
        }
    }

    // MARK: - Reading

    @Test("The grid is newest first, and tombstoned moments are absent")
    func gridIsNewestFirstAndExcludesDeleted() async throws {
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        try await recordHistory(harness, days: 3, endingAt: now)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()

        #expect(model.moments.count == 3)
        let captured = model.moments.map(\.capturedAt)
        #expect(captured == captured.sorted(by: >), "newest first")

        // Tombstone the middle day.
        let middle = model.moments[1]
        try model.delete(middle)
        #expect(model.moments.count == 2)
        #expect(!model.moments.contains { $0.id == middle.id })

        // And it stays gone after a reload, rather than reappearing from a
        // stale read.
        model.load()
        #expect(model.moments.count == 2)
    }

    @Test("A fresh install is empty, not a failure")
    func emptyOnFreshInstall() throws {
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()

        #expect(model.moments.isEmpty)
    }

    // MARK: - Deleting

    @Test("Deleting a moment recomputes the streak")
    func deleteRecomputesTheStreak() async throws {
        // The reason delete is not just a tombstone write. `StreakCalculator`
        // reads `facts()`, which filters on `deletedAt`, so a tombstoned day
        // stops counting the moment the row is written — and if that were not
        // true the number on the Today screen would be a lie with no way for
        // anyone to notice (ADR-008: the photographs stay, the entry does not).
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        try await recordHistory(harness, days: 3, endingAt: now)

        let before = harness.store.summary(today: DayIdentifier(date: now, calendar: calendar))
        #expect(before.daysCaptured == 3)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()
        try model.delete(model.moments[0])

        let after = harness.store.summary(today: DayIdentifier(date: now, calendar: calendar))
        #expect(after.daysCaptured == 2)
        // A gap in the middle breaks the walk, so the streak cannot be 2.
        #expect(after.currentStreak == 0)
    }

    @Test("Deleting removes the row from the grid and its image from the cache")
    func deleteEvictsTheImage() async throws {
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        try await recordHistory(harness, days: 1, endingAt: now)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()
        await model.loadInitialImages()

        let moment = try #require(model.moments.first)
        #expect(model.images[moment.id] != nil, "precondition: the image loaded")

        try model.delete(moment)

        #expect(model.images[moment.id] == nil, "a deleted moment must not hold its image")
        #expect(!model.missing.contains(moment.id))
    }

    // MARK: - The request budget

    @Test("Opening the archive asks for a bounded number of images, not all of them")
    func openingRequestsABoundedBatch() async throws {
        // The claim in the plan is "500 moments scroll smoothly", and the thing
        // that would break it is a grid that requests 500 images at once. Each
        // request is a Photos fetch plus a decode, so this asserts the cap
        // rather than trusting the constant.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        try await recordHistory(harness, days: 40, endingAt: now)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()
        await model.loadInitialImages()

        #expect(model.moments.count == 40)
        #expect(!model.images.isEmpty, "precondition: something loaded")
        // Two screens' worth, and definitely not forty.
        #expect(model.images.count <= 24,
                "asked for \(model.images.count) images on open")
    }

    @Test("A moment already loaded is not asked for twice")
    func alreadyLoadedIsNotRequestedAgain() async throws {
        // Scrolling back and forth is the ordinary case in a grid, and without
        // this the second pass over 500 cells issues 500 requests for images the
        // service already has decoded. The `requested` set is the cheap half of
        // the cache and it is the half that is easy to leave out.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        try await recordHistory(harness, days: 6, endingAt: now)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()

        await model.loadInitialImages()
        let first = model.images
        await model.loadInitialImages()

        #expect(model.images == first, "a second pass loaded something new")
    }

    @Test("Prefetching looks ahead from the topmost visible day")
    func prefetchLooksAhead() async throws {
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        try await recordHistory(harness, days: 30, endingAt: now)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()

        // The newest day is the top of the grid.
        let newest = try #require(model.moments.first?.day)
        await model.prefetch(around: newest)

        #expect(!model.images.isEmpty)
        // Only the ones near the top, not the whole archive.
        #expect(model.images.count < model.moments.count)
    }

    @Test("Prefetching an unknown day is harmless")
    func prefetchUnknownDay() async throws {
        // A stale identifier — a day deleted a moment ago, or a focus request
        // that outlived its target — must not trap or spin. There is no row to
        // anchor on, so the correct answer is to do nothing.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        try await recordHistory(harness, days: 3, endingAt: now)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()

        let absent = DayIdentifier(date: now, calendar: calendar)
            .offset(by: -90, calendar: calendar)
        await model.prefetch(around: absent)

        #expect(model.images.isEmpty)
    }

    @Test("The library is told to prefetch, not just asked for images")
    func prefetchReachesTheLibrary() async throws {
        // The view model holding decoded images is not the same as Photos' own
        // cache being warm. `prefetchThumbnails` is what makes the *first* draw
        // of a cell cheap, and it is easy to write a grid that never calls it —
        // which looks like a grid that works right up until it is scrolled
        // quickly, at which point it shows grey rectangles.
        //
        // This test exists because the call was genuinely missing the first
        // time it was written. `loadImages` fetched each image, so the grid
        // looked correct in every test and in a screenshot of the first screen.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        try await recordHistory(harness, days: 4, endingAt: now)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()
        await model.loadInitialImages()

        let first = try #require(
            harness.library.prefetchedBatches.first,
            "loading the archive must warm Photos' cache, not only fetch images"
        )
        #expect(first.count > 0)
        #expect(harness.library.prefetchedBatches.allSatisfy { !$0.isEmpty },
                "an empty warm is a wasted round trip")
    }

    @Test("Scrolling to a new cell warms what is coming")
    func scrollingWarmsAhead() async throws {
        // The behaviour the previous test could not see: prefetching is not only
        // on open, it follows the user. Warming the top of a 40-item archive and
        // then never again produces a grid that is fast at the top and slow
        // everywhere else.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        try await recordHistory(harness, days: 40, endingAt: now)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()
        await model.loadInitialImages()
        let batchesAfterOpen = harness.library.prefetchedBatches.count

        // The 20th-newest day, roughly where a user has scrolled to.
        let anchor = model.moments[19].day
        await model.prefetch(around: anchor)

        #expect(harness.library.prefetchedBatches.count > batchesAfterOpen,
                "scrolling did not warm anything")
    }

    // MARK: - Missing photographs

    @Test("Photographs deleted from Photos are reported, not shown as blank")
    func missingPhotographsAreReported() async throws {
        // The user deleted them. Memoree never reached back in to prevent that
        // and never will (ADR-008), so the honest outcome is a cell that says
        // so — an empty black rectangle reads as a broken photograph, which is
        // the opposite of what happened.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        try await recordHistory(harness, days: 2, endingAt: now)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()

        let target = try #require(model.moments.first)
        let back = try #require(target.assets?.back)
        harness.library.markMissing(back)

        await model.loadInitialImages()

        #expect(model.images[target.id] == nil)
        #expect(model.missing.contains(target.id))
    }

    @Test("A moment with no photographs on record is neither loaded nor called missing")
    func noPhotographsIsNotMissing() async throws {
        // A distinct state from "deleted from Photos", and conflating them would
        // tell the user their photographs are gone when they never existed in
        // this row. The write path cannot produce a half-pair (both assets land
        // in one `performChanges` block), so this is a row written before the
        // identifiers were attached — rare, and not the user's fault.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)

        let day = DayIdentifier(date: now, calendar: calendar).offset(by: -1, calendar: calendar)
        let start = day.date.addingTimeInterval(14 * 3600)
        try harness.store.record(
            day: day,
            interval: MomentInterval(start: start, end: start.addingTimeInterval(120)),
            capturedAt: start.addingTimeInterval(30),
            retakeCount: 0,
            backAssetIdentifier: nil,
            frontAssetIdentifier: nil
        )

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()
        await model.loadInitialImages()

        #expect(model.moments.count == 1)
        #expect(model.images.isEmpty)
        #expect(model.missing.isEmpty, "no photographs on record is not the same as deleted")
    }

    // MARK: - Cache lifecycle

    @Test("Dismissing the archive hands its images back")
    func releasingTheCachePurgesIt() async throws {
        // A grid's worth of decoded thumbnails is memory the camera wants within
        // the hour, and the camera is the screen in this app that cannot afford
        // to be slow. Asserted because a `purgeImageCache` that was never
        // called is invisible until someone runs out of memory.
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)
        try await recordHistory(harness, days: 5, endingAt: now)

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()
        await model.loadInitialImages()
        #expect(!model.images.isEmpty)

        await model.releaseImageCache()

        #expect(model.images.isEmpty, "the view model dropped its references")
        #expect(harness.library.imageCachePurgeCount == 1,
                "and told the service to drop its decoded tier")
    }

    // MARK: - Sizing

    @Test("A thumbnail is asked for at cell size, not full screen")
    func thumbnailSizeIsCellSized() {
        // A grid that requests full-size images and scales them down decodes 500
        // full-resolution photographs. This is the arithmetic that prevents it,
        // and it is worth a test because the number is derived from the screen
        // and therefore changes with the device.
        let size = ArchiveViewModel.thumbnailTargetSize
        let screenWidth = UIScreen.main.bounds.width * UIScreen.main.scale

        #expect(size.width < screenWidth, "a cell is a third of the screen")
        #expect(size.width > screenWidth / 4, "and not so small it looks soft")
        // 3:4 portrait, the geometry the whole app is built on.
        let ratio = size.height / size.width
        #expect(abs(ratio - 4.0 / 3.0) < 0.01, "3:4, was \(ratio)")
    }

    @Test("The detail view asks for a larger image than a cell does")
    func detailIsLargerThanACell() {
        // Two sizes, and deliberately not one: sharing a cache between them
        // would hand the detail view a thumbnail or fill the cache with
        // full-resolution decodes.
        let cell = ArchiveViewModel.thumbnailTargetSize
        let detail = ArchiveViewModel.detailTargetSize

        #expect(detail.width > cell.width)
        #expect(detail.height > cell.height)
    }

    // MARK: - Fixtures

    private static let pixelPNG = PixelFixture.png

    /// Precondition, and worth asserting on its own: without a decodable
    /// fixture, every `missing` assertion above would pass vacuously.
    @Test("The image fixture decodes")
    func fixtureDecodes() throws {
        #expect(UIImage(data: Self.pixelPNG) != nil,
                "otherwise every missing-photograph test passes for the wrong reason")
    }

    // MARK: - Filtering

    @Test("Filters moments by all, bts video, and micro-journal notes")
    func filterMoments() async throws {
        let now = try #require(DayIdentifier(string: "2026-10-01", calendar: calendar)).date
        let harness = try makeHarness(now: now)

        let d1 = DayIdentifier(date: now, calendar: calendar).offset(by: -1, calendar: calendar)
        let s1 = d1.date.addingTimeInterval(14 * 3600)
        try harness.store.record(
            day: d1,
            interval: MomentInterval(start: s1, end: s1.addingTimeInterval(120)),
            capturedAt: s1.addingTimeInterval(30),
            retakeCount: 0,
            backAssetIdentifier: "b1",
            frontAssetIdentifier: "f1",
            hasBTS: true,
            btsAssetIdentifier: "video1",
            note: nil
        )

        let d2 = DayIdentifier(date: now, calendar: calendar).offset(by: -2, calendar: calendar)
        let s2 = d2.date.addingTimeInterval(14 * 3600)
        try harness.store.record(
            day: d2,
            interval: MomentInterval(start: s2, end: s2.addingTimeInterval(120)),
            capturedAt: s2.addingTimeInterval(30),
            retakeCount: 0,
            backAssetIdentifier: "b2",
            frontAssetIdentifier: "f2",
            hasBTS: false,
            btsAssetIdentifier: nil,
            note: "Coffee in the morning"
        )

        let d3 = DayIdentifier(date: now, calendar: calendar).offset(by: -3, calendar: calendar)
        let s3 = d3.date.addingTimeInterval(14 * 3600)
        try harness.store.record(
            day: d3,
            interval: MomentInterval(start: s3, end: s3.addingTimeInterval(120)),
            capturedAt: s3.addingTimeInterval(30),
            retakeCount: 0,
            backAssetIdentifier: "b3",
            frontAssetIdentifier: "f3",
            hasBTS: true,
            btsAssetIdentifier: "video3",
            note: "Sunset walk"
        )

        let model = ArchiveViewModel(environment: harness.environment)
        model.load()

        #expect(model.moments.count == 3)
        #expect(model.count(for: .all) == 3)
        #expect(model.count(for: .bts) == 2)
        #expect(model.count(for: .notes) == 2)

        model.selectedFilter = .all
        #expect(model.filteredMoments.count == 3)

        model.selectedFilter = .bts
        #expect(model.filteredMoments.count == 2)
        #expect(model.filteredMoments.allSatisfy { $0.hasBTS })

        model.selectedFilter = .notes
        #expect(model.filteredMoments.count == 2)
        #expect(model.filteredMoments.allSatisfy { $0.note != nil })
    }
}
