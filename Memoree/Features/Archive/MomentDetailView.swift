import SwiftUI

/// One moment, full screen.
///
/// **The composite, not the single photograph.** This is the one place both
/// halves are the subject rather than one being an inset, and it is where
/// BeReal's front-inside-back geometry earns its keep: the scene is the
/// photograph and you are in it. The grid deliberately shows only the rear
/// (`ArchiveCell`), because 500 composites is 500 faces in a grid of scenes.
///
/// **No late marker.** An off-window moment looks exactly like an on-time one
/// here, and cannot do otherwise — `MomentFacts` does carry `isOnTime`, and
/// nothing on this screen reads it (ADR-023). The timestamp below is a fact
/// about when the shutter fired, not a judgement about whether it counted.
struct MomentDetailView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// The moment the user tapped. Kept even when it is absent from `moments`,
    /// so a feed that only handed today's captures cannot be redirected to
    /// today's latest by a missing-id fallback.
    private let openedMoment: MomentFacts
    let moments: [MomentFacts]
    /// The memory currently on screen — after a swipe, that may not be the one
    /// the sheet was opened with.
    let onDelete: (MomentFacts) -> Void

    @State private var selectedMomentID: UUID
    /// Until the pager reports the opened id once, ignore other page ids —
    /// a first-layout report of index 0 would otherwise retitle the screen to
    /// today's newest memory before the scroll settles on the tap.
    @State private var hasAcceptedPagerSelection = false
    /// Front-large state keyed by moment, so a swap on one page does not flip a
    /// neighbour that was already loaded into the pager.
    @State private var frontLargeIDs: Set<UUID> = []
    @State private var momentCornerMap: [UUID: InsetCorner] = [:]
    @State private var imagesCache: [UUID: (large: UIImage?, inset: UIImage?)] = [:]
    @State private var missingCache: Set<UUID> = []
    @State private var fullScreenPair: (primary: UIImage, secondary: UIImage)?
    /// When set, the inline BTS card yields the player to `FullScreenBTSViewer`.
    @State private var fullScreenBTSIdentifier: String?

    init(
        moment: MomentFacts,
        moments: [MomentFacts] = [],
        onDelete: @escaping (MomentFacts) -> Void
    ) {
        self.openedMoment = moment
        self.moments = moments.isEmpty ? [moment] : moments
        self._selectedMomentID = State(initialValue: moment.id)
        self.onDelete = onDelete
    }

    var moment: MomentFacts {
        MomentDetailSelection.resolve(
            opened: openedMoment,
            moments: moments,
            selectedID: selectedMomentID
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CanvasBackground()

                if moments.count > 1 {
                    pager
                } else {
                    card(for: moment)
                }
            }
            .navigationTitle(moment.day.date.formatted(.dateTime.day().month(.abbreviated)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    shareMenu(model: sharedPayload)
                        .disabled(sharedPayload == nil)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        onDelete(moment)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Remove from archive")
                    .accessibilityHint(
                        "Removes this moment from Memoree. The photographs stay in "
                            + "your Photos library."
                    )
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { fullScreenPair != nil },
            set: { if !$0 { fullScreenPair = nil } }
        )) {
            if let pair = fullScreenPair {
                FullScreenImageViewer(pair: pair) {
                    fullScreenPair = nil
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { fullScreenBTSIdentifier != nil },
            set: { if !$0 { fullScreenBTSIdentifier = nil } }
        )) {
            FullScreenBTSViewer(assetIdentifier: fullScreenBTSIdentifier) {
                fullScreenBTSIdentifier = nil
            }
            .environment(environment)
        }
        .task(id: selectedMomentID) {
            // Fresh page → rear large. Flip state does not travel with a swipe.
            frontLargeIDs.removeAll()
            // Dismiss BTS fullscreen if the pager moved underneath it.
            fullScreenBTSIdentifier = nil
            await load(for: moment)
            await prepareSharePayload(for: moment)
        }
    }

    // MARK: - Pager

    /// Horizontal paging that opens on the tapped id.
    ///
    /// A page-style `TabView` ignored the initial selection and landed on index
    /// 0 — newest-first, that is today's latest. `scrollPosition` honours the
    /// binding, and the set-side guard drops a first-layout page-0 report.
    private var pager: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(moments) { item in
                    card(for: item)
                        .containerRelativeFrame(.horizontal)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: pagerSelection)
        .task {
            // Re-assert after the first layout pass so a page-0 flash cannot stick.
            selectedMomentID = openedMoment.id
            hasAcceptedPagerSelection = false
        }
    }

    private var pagerSelection: Binding<UUID?> {
        Binding(
            get: { selectedMomentID },
            set: { newValue in
                guard let newValue else { return }
                if !hasAcceptedPagerSelection {
                    if newValue != openedMoment.id {
                        return
                    }
                    hasAcceptedPagerSelection = true
                }
                selectedMomentID = newValue
            }
        )
    }

    // MARK: - Card

    @ViewBuilder
    private func card(for item: MomentFacts) -> some View {
        if verticalSizeClass == .compact {
            HStack(alignment: .top, spacing: Theme.Spacing.l) {
                photograph(for: item)
                    .frame(maxHeight: Theme.Size.detailLandscapeMaxHeight)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        caption(for: item)
                        noteBlock(for: item)
                        retakesLine(for: item)
                        behindTheScenes(for: item)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.l)
            .task {
                await load(for: item)
            }
        } else {
            // Photograph is the page — no vertical scroll fighting the pager.
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                photograph(for: item)
                caption(for: item)
                noteBlock(for: item)
                retakesLine(for: item)
                behindTheScenes(for: item)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.l)
            .task {
                await load(for: item)
            }
        }
    }

    // MARK: - Caption & note

    /// Time and full date on one line. The nav title already carries the short
    /// date; a separate "Date" row was the same fact twice.
    private func caption(for item: MomentFacts) -> some View {
        let time = item.capturedAt.formatted(date: .omitted, time: .shortened)
        let date = item.day.date.formatted(.dateTime.day().month(.wide).year())
        return Text("\(time) · \(date)")
            .font(Theme.Typography.metadata)
            .foregroundStyle(Theme.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Taken \(time) on \(date)")
    }

    @ViewBuilder
    private func noteBlock(for item: MomentFacts) -> some View {
        if let note = item.note, !note.isEmpty {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: "quote.opening")
                    .font(Theme.Typography.retakePill)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .padding(.top, Theme.Spacing.xxs)
                    .accessibilityHidden(true)
                Text(note)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Note: \(note)")
        }
    }

    @ViewBuilder
    private func retakesLine(for item: MomentFacts) -> some View {
        if item.retakeCount > 0 {
            Text("\(item.retakeCount) \(item.retakeCount == 1 ? "retake" : "retakes")")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    // MARK: - Sharing

    @State private var sharedPayload: MomentSharePayload?
    @State private var shareFailure: String?

    private func prepareSharePayload(for current: MomentFacts) async {
        sharedPayload = nil
        guard let assets = current.assets else {
            shareFailure = ShareError.photographsMissing.errorDescription
            return
        }

        guard await environment.photoLibrary.assetExists(assets.back) else {
            shareFailure = ShareError.photographsMissing.errorDescription
            return
        }

        async let back = environment.photoLibrary.data(for: assets.back)
        async let front = environment.photoLibrary.data(for: assets.front)
        do {
            let (backData, frontData) = try await (back, front)
            sharedPayload = MomentSharePayload(
                day: current.day.rawValue,
                backData: backData,
                frontData: frontData
            )
            shareFailure = nil
        } catch {
            shareFailure = ShareError.renderFailed.errorDescription
        }
    }

    @ViewBuilder
    private func shareMenu(model: MomentSharePayload?) -> some View {
        if let payload = model {
            Menu {
                ShareLink(
                    items: payload.photographs,
                    preview: { _ in SharePreview(moment.day.rawValue) },
                    label: {
                        Label("Both photographs", systemImage: "photo.on.rectangle")
                    }
                )
                if let combined = payload.combinedImage() {
                    ShareLink(
                        item: combined,
                        preview: SharePreview(moment.day.rawValue),
                        label: {
                            Label("One combined picture", systemImage: "rectangle.on.rectangle")
                        }
                    )
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityLabel("Share this moment")
            .accessibilityHint(
                "Offers the photographs on their own, or one combined picture"
            )
        } else {
            Image(systemName: "square.and.arrow.up")
                .accessibilityLabel("Share this moment")
                .accessibilityHint(shareFailure ?? "Preparing the photographs")
        }
    }

    // MARK: - Photograph

    private func aspect(of image: UIImage) -> CGFloat {
        guard image.size.height > 0, image.size.width > 0 else { return 3.0 / 4.0 }
        return image.size.width / image.size.height
    }

    @ViewBuilder
    private func photograph(for item: MomentFacts) -> some View {
        let cached = imagesCache[item.id]
        let isMissing = missingCache.contains(item.id)
        let isFrontLarge = frontLargeIDs.contains(item.id)
        let largeImage = isFrontLarge ? cached?.inset : cached?.large
        let insetImage = isFrontLarge ? cached?.large : cached?.inset

        if let large = largeImage, let inset = insetImage {
            MomentComposite(
                large: large,
                inset: inset,
                insetWidth: Theme.Size.insetStandard,
                initialCorner: momentCornerMap[item.id] ?? .topLeading,
                onCornerChanged: { newCorner in
                    momentCornerMap[item.id] = newCorner
                },
                onTapInset: {
                    withAppAnimation(.easeInOut(duration: 0.25)) {
                        if frontLargeIDs.contains(item.id) {
                            frontLargeIDs.remove(item.id)
                        } else {
                            frontLargeIDs.insert(item.id)
                        }
                    }
                },
                onTapLarge: {
                    fullScreenPair = (large, inset)
                }
            )
            .aspectRatio(aspect(of: large), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CompositeAccessibility.label)
        } else if isMissing {
            VStack(spacing: Theme.Spacing.m) {
                Image(systemName: "photo")
                    .scaledDisplayFont(Theme.Size.iconStandalone, weight: .regular)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .accessibilityHidden(true)
                Text("These photos are no longer in your library. The moment is still in your archive.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .background(Theme.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        } else {
            Theme.Color.surface
                .frame(maxWidth: .infinity)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Behind the Scenes

    @ViewBuilder
    private func behindTheScenes(for item: MomentFacts) -> some View {
        if item.hasBTS {
            // While fullscreen owns the player, keep the card's footprint so the
            // layout does not jump — and so two decoders never share one clip file.
            if let id = item.btsAssetIdentifier, fullScreenBTSIdentifier == id {
                Theme.Color.surface
                    .frame(maxWidth: .infinity)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .accessibilityHidden(true)
            } else {
                BTSPlaybackView(
                    assetIdentifier: item.btsAssetIdentifier,
                    onExpand: item.btsAssetIdentifier.map { id in
                        { fullScreenBTSIdentifier = id }
                    }
                )
            }
        }
    }

    // MARK: - Loading

    private func load(for current: MomentFacts) async {
        guard imagesCache[current.id] == nil, !missingCache.contains(current.id) else { return }
        guard let assets = current.assets else {
            missingCache.insert(current.id)
            return
        }

        let loader = ArchiveViewModel(environment: environment)
        if let loaded = await loader.loadDetailImages(for: current), loaded.large != nil {
            imagesCache[current.id] = loaded
        } else {
            let exists = await environment.photoLibrary.assetExists(assets.back)
            if !exists {
                missingCache.insert(current.id)
            }
        }
    }
}
