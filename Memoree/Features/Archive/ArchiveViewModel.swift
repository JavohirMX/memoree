import Foundation
import Observation
import UIKit

/// Drives the archive.
///
/// Reads `[MomentFacts]` and nothing else. Every value a cell needs — the day,
/// the timestamp, the retake count, and the two asset identifiers — is already
/// on that snapshot, because Phase 5 built it for exactly this consumer and
/// added the identifiers to it then. The archive inherits that rather than
/// re-querying SwiftData and re-implementing the mapping.
///
/// Holds `UIImage` rather than a Photos asset. The alternative is holding
/// `PHAsset`, which is not `Sendable` and would make this type either
/// main-actor-pinned for no reason or `unsafe` for a real one. A decoded
/// thumbnail is a value type, and the memory is bounded by
/// `ArchiveThumbnailCache`.
@MainActor
@Observable
final class ArchiveViewModel {

    /// Every live moment, newest first.
    private(set) var moments: [MomentFacts] = []

    /// Current filter applied to the archive.
    var selectedFilter: ArchiveFilter = .all

    /// Moments filtered according to `selectedFilter`.
    var filteredMoments: [MomentFacts] {
        switch selectedFilter {
        case .all:
            return moments
        case .bts:
            return moments.filter(\.hasBTS)
        case .notes:
            return moments.filter {
                guard let note = $0.note else { return false }
                return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    /// Count of moments matching a specific filter.
    func count(for filter: ArchiveFilter) -> Int {
        switch filter {
        case .all:
            return moments.count
        case .bts:
            return moments.filter(\.hasBTS).count
        case .notes:
            return moments.filter {
                guard let note = $0.note else { return false }
                return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
        }
    }

    /// Decoded thumbnails, keyed by moment.
    private(set) var images: [UUID: UIImage] = [:]

    /// Moments whose photographs are no longer in Photos.
    private(set) var missing: Set<UUID> = []

    private let environment: AppEnvironment

    /// Identifiers already resolved to a terminal outcome (decoded image, or
    /// confirmed missing / no assets), so a cell that reappears does not
    /// re-request.
    ///
    /// **Not** set on a transient nil. Photos can hand back nil while the asset
    /// still exists; marking requested then leaves the cell permanently blank.
    /// Without the set at all, scrolling a 500-item grid back and forth issues
    /// 500 requests per pass for images the service already has decoded.
    private var requested: Set<UUID> = []

    /// Moment IDs currently being fetched, so overlapping prefetch windows do
    /// not stampede the same cell while a transient miss is still in flight.
    private var loading: Set<UUID> = []

    /// How many image requests are in flight.
    ///
    /// Capped, and the cap is the point. A grid that appears with 500 rows will
    /// happily ask for 500 images at once, and each one is a Photos fetch plus a
    /// decode — enough to exhaust the memory the camera will want five minutes
    /// later. Twelve is roughly four screens' worth, which is more than the
    /// prefetch lead and far less than the whole archive.
    private var inFlight = 0
    private static let maximumInFlight = 12

    /// How far ahead of a newly-visible cell to warm, and how far behind.
    ///
    /// Ahead-first because the user is scrolling forward, and behind because
    /// they may scroll back faster than a request completes. Twenty-four ahead
    /// is roughly eight rows — enough lead to cover the distance covered while a
    /// Photos fetch is in flight, and not so much that opening the archive
    /// competes with the camera for memory.
    private static let prefetchAhead = 24
    private static let prefetchBehind = 4

    /// The in-progress prefetch, cancelled when a new cell appears.
    private var prefetchTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - Loading

    func load() {
        moments = environment.momentStore.facts()
    }

    /// Loads the images for the moments nearest the top, in the background.
    ///
    /// Called on appear. `await`ed rather than fired so the caller controls when
    /// work starts, and structured so cancelling the task cancels the loads with
    /// it.
    func loadInitialImages() async {
        let batch = Array(moments.prefix(Self.maximumInFlight * 2))
        await loadImages(for: batch)
        // The decoded-image cache makes the *second* draw of a cell free; this is
        // what makes the *first* one cheap. Two calls, because they are two
        // different caches and doing only the first produces a grid that looks
        // like it works and shows grey rectangles when scrolled quickly.
        await warmPhotoKitCache(for: batch)
    }

    /// A cell scrolled into view.
    ///
    /// Fires a prefetch, cancelling any the previous cell started. The
    /// cancellation is the point: a fast scroll produces a cell appearance per
    /// row, and without it thirty overlapping prefetch tasks would each walk the
    /// same slice of the archive.
    func noteVisible(day: DayIdentifier) {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            await self?.prefetch(around: day)
        }
    }

    /// Warms Photos' own cache for a day and the twenty-four after it.
    ///
    /// Ahead rather than symmetric, because the user is scrolling forward, and
    /// four behind because they may scroll back faster than a request completes.
    private func warmPhotoKitCache(for batch: [MomentFacts]) async {
        let identifiers = batch.compactMap(\.assets?.back)
        guard !identifiers.isEmpty else { return }
        await environment.photoLibrary.prefetchThumbnails(
            identifiers, targetSize: Self.thumbnailTargetSize
        )
    }

    /// Loads images for whatever the user is about to scroll to.
    func prefetch(around anchor: DayIdentifier) async {
        let ordered = moments
        guard let index = ordered.firstIndex(where: { $0.day == anchor }) else { return }

        let lower = max(0, index - Self.prefetchBehind)
        let upper = min(ordered.count, index + Self.prefetchAhead)
        guard lower < upper else { return }

        let slice = Array(ordered[lower..<upper])
        await loadImages(for: slice)
        await warmPhotoKitCache(for: slice)
    }

    /// Fetches one moment's photographs, if they are not already held.
    ///
    /// Marks `requested` only after a success or a confirmed miss — a transient
    /// nil leaves the id free so the next scroll past the cell can try again.
    /// When both assets are confirmed gone, tombstones the metadata row
    /// (never the Photos assets — ADR-008).
    private func loadImages(for batch: [MomentFacts]) async {
        for moment in batch {
            guard inFlight < Self.maximumInFlight else { return }
            guard !requested.contains(moment.id) else { continue }
            guard !loading.contains(moment.id) else { continue }
            guard let assets = moment.assets else {
                // No photographs on record. Not an error and not a missing
                // asset — the write path cannot produce a half-pair, so this
                // means the moment predates the identifiers or the row was
                // written before the pair was attached. Nothing to fetch.
                requested.insert(moment.id)
                continue
            }

            loading.insert(moment.id)
            inFlight += 1
            defer {
                loading.remove(moment.id)
                inFlight -= 1
            }

            let backImage = await environment.photoLibrary.image(
                for: assets.back, targetSize: Self.thumbnailTargetSize
            )

            // The grid shows the rear photograph; the front is only needed by
            // the detail view. Requesting both here would double the number of
            // Photos fetches for an image most cells never draw.
            if let backImage {
                images[moment.id] = backImage
                requested.insert(moment.id)
                continue
            }

            // `nil` is ambiguous — a transient miss and a deleted asset look
            // the same. Ask both sides: the rear drives the cell, and both
            // must be gone before we tombstone (AGENTS.md §8).
            let backExists = await environment.photoLibrary.assetExists(assets.back)
            let frontExists = await environment.photoLibrary.assetExists(assets.front)

            if !backExists && !frontExists {
                if tombstoneOrphan(moment) {
                    // Gone from the grid; nothing left to show or re-request.
                } else {
                    missing.insert(moment.id)
                    requested.insert(moment.id)
                }
            } else if !backExists {
                missing.insert(moment.id)
                requested.insert(moment.id)
            }
            // else: assets still present — leave `requested` alone so a later
            // pass can retry the transient nil.
        }
    }

    /// Soft-deletes an orphan whose Photos assets are both gone.
    ///
    /// Metadata only — Memoree never deletes from the user's library
    /// (ADR-008 / AGENTS.md §8). Returns whether the store write succeeded.
    @discardableResult
    private func tombstoneOrphan(_ moment: MomentFacts) -> Bool {
        guard let row = environment.momentStore.allMoments
            .first(where: { $0.id == moment.id })
        else { return false }
        do {
            try environment.momentStore.delete(row)
        } catch {
            return false
        }

        moments.removeAll { $0.id == moment.id }
        images.removeValue(forKey: moment.id)
        missing.remove(moment.id)
        requested.remove(moment.id)
        loading.remove(moment.id)
        return true
    }

    /// Loads both photographs of one moment, for the detail view.
    ///
    /// Separate from `loadImages` because the sizes are different: a detail view
    /// asks for a screen-sized image and a cell asks for a third of one, and
    /// sharing a cache between them would hand the detail view a thumbnail or
    /// fill the cache with full-resolution decodes.
    func loadDetailImages(for moment: MomentFacts) async -> (large: UIImage?, inset: UIImage?)? {
        guard let assets = moment.assets else { return nil }

        let size = Self.detailTargetSize
        async let large = environment.photoLibrary.image(for: assets.back, targetSize: size)
        async let inset = environment.photoLibrary.image(for: assets.front, targetSize: size)
        let (largeImage, insetImage) = await (large, inset)

        guard let largeImage else { return nil }
        return (large: largeImage, inset: insetImage)
    }

    // MARK: - Detail

    /// Tombstones a moment and takes it out of the grid.
    ///
    /// **Does not touch Photos.** Memoree holds add-only authorisation and
    /// physically cannot delete an asset it created (ADR-008), so the earlier
    /// pair from a re-capture is in the user's camera roll permanently. The
    /// confirmation dialog says so *before* the tap, not after — this is the
    /// cost of the ownership thesis and the user is entitled to know it while
    /// they can still back out.
    func delete(_ moment: MomentFacts) throws {
        guard let row = environment.momentStore.allMoments
            .first(where: { $0.id == moment.id })
        else { return }

        try environment.momentStore.delete(row)

        moments.removeAll { $0.id == moment.id }
        images[moment.id] = nil
        missing.remove(moment.id)
        requested.remove(moment.id)
    }

    // MARK: - Export

    private(set) var isExporting = false
    private(set) var exportError: String?

    /// Exports all moments in the archive as a timelapse flipbook video saved directly to Photos.
    func exportFlipbook() async -> Bool {
        guard !moments.isEmpty, !isExporting else { return false }
        isExporting = true
        exportError = nil
        defer { isExporting = false }

        // Chronological order for timelapse
        let sortedMoments = moments.sorted { $0.capturedAt < $1.capturedAt }
        do {
            _ = try await environment.photoLibrary.exportFlipbookVideo(
                for: sortedMoments,
                framesPerSecond: 2
            )
            return true
        } catch {
            exportError = error.localizedDescription
            return false
        }
    }

    // MARK: - Cache lifecycle

    /// Hands the decoded images back.
    ///
    /// Called on disappear. A grid's worth of decoded thumbnails is memory the
    /// camera is about to want, and the camera is the screen in this app that
    /// cannot afford to be slow.
    func releaseImageCache() async {
        await environment.photoLibrary.purgeImageCache()
        images.removeAll()
    }

    /// The size a cell's image is requested at.
    ///
    /// The cell is a third of the screen, so this asks for a third of the screen
    /// rather than the full width — a grid that requests full-size images and
    /// scales them down is a grid that decodes 500 full-resolution photographs.
    /// One point of slack, because a decode at exactly the display size can come
    /// back marginally soft on a 3x screen.
    static var thumbnailTargetSize: CGSize {
        let scale = UIScreen.main.scale
        let width = UIScreen.main.bounds.width / 3
        return CGSize(width: (width * scale).rounded(), height: (width * scale * 4.0 / 3.0).rounded())
    }

    /// The size the detail view asks for.
    ///
    /// Bounded rather than "the original", because a 3–5 MB HEIC decoded at
    /// full resolution for a 1080pt screen buys nothing a user can see and costs
    /// memory the camera will want next. One screen's worth at 2x.
    static var detailTargetSize: CGSize {
        let scale = UIScreen.main.scale
        let side = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        return CGSize(width: (side * scale).rounded(), height: (side * scale).rounded())
    }
}

/// Archive filter options for viewing moments.
enum ArchiveFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case bts = "Video"
    case notes = "Notes"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .bts: return "Video"
        case .notes: return "Notes"
        }
    }

    var iconName: String? {
        switch self {
        case .all: return nil
        case .bts: return "video.fill"
        case .notes: return "text.bubble.fill"
        }
    }
}
