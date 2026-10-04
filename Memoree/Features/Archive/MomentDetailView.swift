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

    let moment: MomentFacts
    let onDelete: () -> Void

    @State private var images: (large: UIImage?, inset: UIImage?)?
    @State private var isMissing = false

    var body: some View {
        NavigationStack {
            CanvasBackground()

            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    photograph
                    behindTheScenes
                    metadata
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.xl)
            }
        }
        .navigationTitle(moment.day.date.formatted(.dateTime.day().month(.abbreviated)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // **Share, and then delete — never the other way round.** The
                // share button sits where a destructive one usually goes, and the
                // destructive one moved to the trailing *group* below. A trash can
                // and an export arrow are both one tap from a moment the user
                // cannot get back, and putting the irreversible one first is how
                // a mis-tap deletes somebody's day.
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
        .task { await load() }
        .task { await prepareSharePayload() }
    }

    // MARK: - Sharing

    /// The bytes to share, loaded once the photographs are known to exist.
    @State private var sharedPayload: MomentSharePayload?
    @State private var shareFailure: String?

    /// Streams the originals out of Photos so the share sheet has something to
    /// hand over.
    ///
    /// **Originals, streamed at share time rather than held.** `data(for:)` is
    /// called here and the result kept in memory for as long as this screen is
    /// up — not written to disk, and not fetched when the share sheet opens. The
    /// app stores no image bytes (AGENTS.md §2.4), so this is the one place a
    /// photograph is in memory on purpose.
    private func prepareSharePayload() async {
        guard let assets = moment.assets else {
            shareFailure = ShareError.photographsMissing.errorDescription
            return
        }

        // A photograph the user deleted must not produce an empty share sheet.
        // Reported instead of hidden, for the same reason the screen reports it.
        guard await environment.photoLibrary.assetExists(assets.back) else {
            shareFailure = ShareError.photographsMissing.errorDescription
            return
        }

        async let back = environment.photoLibrary.data(for: assets.back)
        async let front = environment.photoLibrary.data(for: assets.front)
        do {
            let (backData, frontData) = try await (back, front)
            sharedPayload = MomentSharePayload(
                day: moment.day.rawValue,
                backData: backData,
                frontData: frontData
            )
            shareFailure = nil
        } catch {
            shareFailure = ShareError.renderFailed.errorDescription
        }
    }

    /// Two rows: both photographs, or one combined picture.
    @ViewBuilder
    private func shareMenu(model: MomentSharePayload?) -> some View {
        if let payload = model {
            Menu {
                // `items:` and plural, and the `preview:` argument is **required** for a
                // custom `Transferable` — the label-only overloads exist only for
                // `[URL]` and `[String]`. Passing an array to `item:` does not
                // typecheck either, because that one wants
                // `Data == CollectionOfOne<I>`.
                //
                // The preview is the moment's day, which is what the user would
                // name it anyway.
                ShareLink(
                    items: payload.photographs,
                    preview: { _ in SharePreview(moment.day.rawValue) },
                    label: {
                        Label("Both photographs", systemImage: "photo.on.rectangle")
                    }
                )
                // The combined image needs two photographs. A moment with one is
                // offered the photographs and nothing else — a "combined" row
                // that produced a rear-only image would be a different thing
                // under the same name.
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
            // **Shown disabled rather than hidden.** A control that appears on
            // first use is one the user has to discover by having already
            // succeeded — and the empty state here is a photograph they deleted.
            Image(systemName: "square.and.arrow.up")
                .accessibilityLabel("Share this moment")
                .accessibilityHint(shareFailure ?? "Preparing the photographs")
        }
    }

    // MARK: - Photograph

    /// The photograph's own aspect, height over width.
    ///
    /// **3:4 as the fallback**, not as an answer: a zero-sized or unreadable
    /// image is a loading state, and the frame still needs a shape while it
    /// resolves. Portrait is what that shape should be, because portrait is what
    /// almost every moment is.
    private func aspect(of image: UIImage) -> CGFloat {
        guard image.size.height > 0, image.size.width > 0 else { return 3.0 / 4.0 }
        return image.size.height / image.size.width
    }

    @ViewBuilder
    private var photograph: some View {
        if let large = images?.large, let inset = images?.inset {
            MomentComposite(
                large: large,
                inset: inset,
                insetWidth: Theme.Size.insetStandard
            )
                // **The frame follows the photograph, not a 3:4 assumption.**
                //
                // `MomentComposite` fills its frame with `scaledToFill`, so a
                // frame that disagrees with the photograph's aspect does not
                // letterbox it — it **crops**, losing the left and right thirds of
                // every sideways moment on the screen whose whole job is looking
                // at one closely. This was a hardcoded 3:4 that was correct while
                // the app could only shoot portrait.
                //
                // `UIImage.size` is already orientation-corrected, so a landscape
                // photograph reports its width as the long edge and the aspect
                // comes out at 0.75 with no EXIF handling here.
                .aspectRatio(aspect(of: large), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(CompositeAccessibility.label)
        } else if isMissing {
            // Reported, not rendered as a black rectangle. An empty frame where a
            // photograph should be reads as a bug; saying the photographs are
            // gone from Photos reads as the truth, which is what it is — the user
            // deleted them, and Memoree never reached back in to prevent it
            // (ADR-008).
            VStack(spacing: Theme.Spacing.m) {
                Image(systemName: "photo")
                    .scaledDisplayFont(Theme.Size.iconStandalone, weight: .regular)
                    .foregroundStyle(Theme.Color.textTertiary)
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
            // Not resolved yet. Flat, honest, and not a spinner — see
            // `ArchiveCell` for why.
            Theme.Color.surface
                .frame(maxWidth: .infinity)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Behind the Scenes

    /// The clip, when this moment has one.
    ///
    /// **Below the photographs, and never replacing them.** The two photographs are
    /// the moment (ADR-013); the clip is context. Putting it above them would make
    /// a five-second video the subject of the screen, which inverts the product.
    ///
    /// **Hidden entirely when there is no clip**, rather than shown with an empty
    /// frame — same reasoning as the retake row: a zero is not information.
    @ViewBuilder
    private var behindTheScenes: some View {
        if moment.hasBTS {
            BTSPlaybackView(assetIdentifier: moment.btsAssetIdentifier)
        }
    }

    // MARK: - Metadata

    /// Facts about the moment, and nothing else.
    ///
    /// **No coordinates.** `Moment` has carried `latitude`/`longitude` since
    /// Phase 1 and nothing has ever written them — there is no location prompt
    /// anywhere in the app, and `makeMomentRecorder` passes no location. So the
    /// fields are permanently `nil` and a coordinate row would be a control
    /// that can only ever read "—". When location is collected, `MomentFacts`
    /// will need to carry it, because a screen cannot hold a `Moment` and
    /// cross an isolation boundary with one.
    private var metadata: some View {
        VStack(spacing: Theme.Spacing.s) {
            MetadataRow(
                label: "Taken",
                value: moment.capturedAt.formatted(date: .omitted, time: .shortened)
            )
            MetadataRow(
                label: "Date",
                value: moment.day.date.formatted(.dateTime.day().month(.wide).year())
            )
            // Hidden at zero, and not rendered as "0". A retake count of zero is
            // not information — it is the absence of the thing being counted, and
            // a row that says so is a row of noise.
            if moment.retakeCount > 0 {
                MetadataRow(
                    label: "Retakes",
                    value: "\(moment.retakeCount)"
                )
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let assets = moment.assets else {
            isMissing = true
            return
        }

        // A scratch model per presentation. The detail view needs exactly one
        // moment's images and none of the grid's state, and threading the grid's
        // view model down through the sheet would couple two screens that share
        // no lifecycle — the grid is torn down when the sheet is dismissed, and
        // the detail is presented over it.
        let loader = ArchiveViewModel(environment: environment)
        if let loaded = await loader.loadDetailImages(for: moment), loaded.large != nil {
            images = loaded
        } else {
            // A `nil` image is ambiguous: a request that has not resolved and an
            // asset the user deleted look the same. Ask before claiming the
            // photographs are gone.
            let exists = await environment.photoLibrary.assetExists(assets.back)
            isMissing = !exists
        }
    }
}
