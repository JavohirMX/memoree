import SwiftUI

/// The archive: every moment you have captured, newest first.
///
/// A sheet over the Today screen rather than a tab, because the Today screen is
/// the app's only screen and the shutter is its whole point. A tab bar would
/// imply three equal destinations, and two of them are places you visit.
///
/// **Where the photographs come from.** They are streamed out of the user's own
/// Photos library by identifier (TRD §6.5, ADR-007). Memoree stores no image
/// bytes at all, so this grid is a view of the camera roll and nothing more —
/// delete the app and every photograph here is still there, which is the whole
/// thesis (AGENTS.md §2.4).
struct ArchiveView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var model: ArchiveViewModel?

    /// The moment being opened, held by the view rather than the view model.
    ///
    /// It is the `sheet(item:)` binding, and that binding needs somewhere to
    /// write `nil` when the sheet is dismissed. Keeping it in `@State` on the
    /// view is what lets SwiftUI own the dismissal — the view model would have
    /// to be told about it, and then there would be two places that know whether
    /// the detail is open.
    @State private var selected: MomentFacts?
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationStack {
            // Lifecycle on the outermost container, never on a branch that
            // renders conditionally. Attaching `.task` to `content(model)` means
            // it only runs once the model exists — so it never runs, and the
            // screen stays black. That bug black-screened the Today screen in
            // Phase 5 and no unit test caught it.
            ZStack {
                CanvasBackground()

                if let model {
                    content(model)
                }
            }
            .navigationTitle("Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            let created = ArchiveViewModel(environment: environment)
            model = created
            created.load()
            await created.loadInitialImages()
        }
        // The cache is released on the way out, not on the way in. A grid's
        // worth of decoded thumbnails is memory the camera wants within the hour
        // (ADR-008 does not let us re-read them cheaply later — they would have
        // to come from Photos again).
        .onDisappear {
            guard let model else { return }
            Task { await model.releaseImageCache() }
        }
        .confirmationDialog(
            Self.deleteTitle,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Remove from archive", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Stated before the tap, not after. Memoree holds add-only
            // authorisation and physically cannot delete an asset it wrote
            // (ADR-008), so a "delete" that leaves the photographs behind will
            // otherwise read as a bug rather than as the design (AGENTS.md §6).
            Text(Self.deleteMessage)
        }
    }

    private static let deleteTitle = "Remove from archive?"

    private static let deleteMessage = """
        Your streak will be recalculated without it.

        The two photos stay in your library. Memoree never deletes from Photos.
        """

    // MARK: - Content

    @ViewBuilder
    private func content(_ model: ArchiveViewModel) -> some View {
        if model.moments.isEmpty {
            empty
        } else {
            ArchiveGrid(
                moments: model.moments,
                images: model.images,
                missing: model.missing,
                onOpen: { selected = $0 },
                onDayVisible: { model.noteVisible(day: $0) }
            )
            // Two sheets, stacked, and the inner one is the delete confirmation.
            // A confirmation presented *over* the detail would have to dismiss
            // the detail to show it, and dismissing the detail to answer a
            // question about the moment you are looking at is backwards.
            .sheet(item: $selected) { moment in
                MomentDetailView(moment: moment, onDelete: { isConfirmingDelete = true })
                    .environment(environment)
            }
        }
    }

    /// Nothing captured yet.
    ///
    /// Reached only on a fresh install, because the archive button is disabled
    /// with no moments — so this is the first thing a new user sees if they find
    /// their way here anyway, and it says what the app is for rather than
    /// apologising for being empty.
    private var empty: some View {
        VStack(spacing: Theme.Spacing.l) {
            Text("Nothing yet")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Text("""
                Every photograph you take appears here, newest first. They \
                live in your Photos library — this is just a way of looking at \
                them.
                """)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func deleteSelected() {
        guard let model, let selected else { return }
        do {
            try model.delete(selected)
            // The detail is showing a moment that no longer exists, so it goes
            // too. Left open it would show a photograph with no way back to the
            // grid, which is the dead end AGENTS.md §6 is about.
            self.selected = nil
        } catch {
            // A failed tombstone leaves the moment in the grid, which is the
            // honest outcome: it is still in the archive because it is still
            // there. No alert, because there is no recovery the user could
            // choose differently — retrying is the only move, and the store
            // will be asked again on the next launch.
        }
    }
}
