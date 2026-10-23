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
    let onDelete: () -> Void

    @State private var selectedMomentID: UUID
    /// Until the pager reports the opened id once, ignore other page ids —
    /// a first-layout report of index 0 would otherwise retitle the screen to
    /// today's newest memory before the scroll settles on the tap.
    @State private var hasAcceptedPagerSelection = false
    @State private var isFrontLarge = false
    @State private var imagesCache: [UUID: (large: UIImage?, inset: UIImage?)] = [:]
    @State private var missingCache: Set<UUID> = []
    @State private var fullScreenPair: (primary: UIImage, secondary: UIImage)?

    init(
        moment: MomentFacts,
        moments: [MomentFacts] = [],
        onDelete: @escaping () -> Void
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
                    Button(role: .destructive, action: onDelete) {
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
        .task(id: selectedMomentID) {
            isFrontLarge = false
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
        ScrollView {
            if verticalSizeClass == .compact {
                HStack(alignment: .top, spacing: Theme.Spacing.l) {
                    photograph(for: item)
                        .frame(maxHeight: Theme.Size.detailLandscapeMaxHeight)

                    VStack(spacing: Theme.Spacing.m) {
                        behindTheScenes(for: item)
                        metadata(for: item)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.l)
            } else {
                VStack(spacing: Theme.Spacing.xl) {
                    photograph(for: item)
                    behindTheScenes(for: item)
                    metadata(for: item)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.xl)
            }
        }
        .task {
            await load(for: item)
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
        let largeImage = isFrontLarge ? cached?.inset : cached?.large
        let insetImage = isFrontLarge ? cached?.large : cached?.inset

        if let large = largeImage, let inset = insetImage {
            MomentComposite(
                large: large,
                inset: inset,
                insetWidth: Theme.Size.insetStandard,
                onTapInset: {
                    withAppAnimation(.easeInOut(duration: 0.25)) {
                        isFrontLarge.toggle()
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
            BTSPlaybackView(assetIdentifier: item.btsAssetIdentifier)
        }
    }

    // MARK: - Metadata

    private func metadata(for item: MomentFacts) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            MetadataRow(
                label: "Taken",
                value: item.capturedAt.formatted(date: .omitted, time: .shortened)
            )
            MetadataRow(
                label: "Date",
                value: item.day.date.formatted(.dateTime.day().month(.wide).year())
            )
            if let note = item.note, !note.isEmpty {
                MetadataRow(
                    label: "Note",
                    value: note
                )
            }
            if item.retakeCount > 0 {
                MetadataRow(
                    label: "Retakes",
                    value: "\(item.retakeCount)"
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
