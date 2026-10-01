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
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Remove from archive")
                .accessibilityHint("Removes this moment from Memoree. The photographs stay in your Photos library.")
            }
        }
        .task { await load() }
    }

    // MARK: - Photograph

    @ViewBuilder
    private var photograph: some View {
        if let large = images?.large, let inset = images?.inset {
            MomentComposite(large: large, inset: inset, insetWidth: 96)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
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
                    .font(.system(size: 32))
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
