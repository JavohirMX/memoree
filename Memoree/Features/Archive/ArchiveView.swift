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

    @Environment(AppEnvironment.self) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var model: ArchiveViewModel?
    @State private var viewMode: ArchiveViewMode = .grid
    @State private var targetMonth: MonthKey?
    @State private var isShowingTimelapsePreview = false
    @State private var showExportSuccessAlert = false

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
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let model, !model.moments.isEmpty {
                        Button {
                            isShowingTimelapsePreview = true
                        } label: {
                            Label("Export Timelapse", systemImage: "film")
                                .foregroundStyle(Theme.Color.textPrimary)
                        }
                        .accessibilityLabel("Export Timelapse Flipbook Video")
                    }
                }
            }
        }
        .task {
            let created = ArchiveViewModel(environment: appEnvironment)
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
            VStack(spacing: 0) {
                summaryHeader(model)
                filterPillBar(model)
                Divider()
                    .overlay(Theme.Color.divider)

                if model.filteredMoments.isEmpty {
                    filterEmpty(model)
                } else if viewMode == .grid {
                    ArchiveGrid(
                        moments: model.filteredMoments,
                        images: model.images,
                        missing: model.missing,
                        onOpen: { selected = $0 },
                        onDayVisible: { model.noteVisible(day: $0) },
                        targetMonth: $targetMonth
                    )
                } else {
                    ArchiveCalendarView(
                        moments: model.filteredMoments,
                        images: model.images,
                        missing: model.missing,
                        onOpen: { selected = $0 },
                        onDayVisible: { model.noteVisible(day: $0) },
                        targetMonth: $targetMonth
                    )
                }
            }
            // Two sheets, stacked, and the inner one is the delete confirmation.
            // A confirmation presented *over* the detail would have to dismiss
            // the detail to show it, and dismissing the detail to answer a
            // question about the moment you are looking at is backwards.
            .sheet(item: $selected) { moment in
                MomentDetailView(
                    moment: moment,
                    moments: model.moments,
                    onDelete: { isConfirmingDelete = true }
                )
                .environment(appEnvironment)
            }
            .sheet(isPresented: $isShowingTimelapsePreview) {
                TimelapsePreviewSheet(
                    moments: model.moments,
                    isExporting: model.isExporting,
                    exportError: model.exportError,
                    onExport: {
                        Task {
                            let success = await model.exportFlipbook()
                            if success {
                                isShowingTimelapsePreview = false
                                showExportSuccessAlert = true
                            }
                        }
                    }
                )
            }
            .alert("Timelapse Saved", isPresented: $showExportSuccessAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your stop-motion timelapse flipbook video has been saved to your Photos library.")
            }
        }
    }

    // MARK: - Summary Header & Filter Pills

    private func summaryHeader(_ model: ArchiveViewModel) -> some View {
        let count = model.filteredMoments.count
        let countString = "\(count) \(count == 1 ? "moment" : "moments")"
        let spanString = dateSpan(for: model.filteredMoments)
        let sections = ArchiveSection.grouping(model.filteredMoments)

        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(countString)
                        .font(Theme.Typography.screenTitle)
                        .foregroundStyle(Theme.Color.textPrimary)

                    if sections.count > 1 {
                        monthJumpMenu(sections: sections)
                    }
                }
                if let spanString {
                    Text(spanString)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.m)
            viewModePicker
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.top, Theme.Spacing.s)
        .padding(.bottom, Theme.Spacing.s)
    }

    private func monthJumpMenu(sections: [ArchiveSection]) -> some View {
        Menu {
            ForEach(sections) { section in
                Button {
                    targetMonth = section.id
                } label: {
                    HStack {
                        Text(section.title)
                        Spacer()
                        Text(section.countDescription)
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "calendar")
                    .font(Theme.Typography.retakePill)
                Text("Jump")
                    .font(Theme.Typography.retakePill)
                Image(systemName: "chevron.down")
                    .font(Theme.Typography.retakePill)
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Color.surface)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Theme.Color.divider, lineWidth: 1)
            }
        }
    }

    private func filterPillBar(_ model: ArchiveViewModel) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            ForEach(ArchiveFilter.allCases) { filter in
                let isSelected = model.selectedFilter == filter
                let count = model.count(for: filter)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        model.selectedFilter = filter
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if let icon = filter.iconName {
                            Image(systemName: icon)
                                .font(Theme.Typography.retakePill)
                        }
                        Text(filter.title)
                            .font(Theme.Typography.retakePill)
                        Text("\(count)")
                            .font(Theme.Typography.retakePill)
                            .foregroundStyle(isSelected ? Theme.Color.textPrimary : Theme.Color.textTertiary)
                    }
                    .foregroundStyle(isSelected ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(isSelected ? Theme.Color.divider : Theme.Color.surface)
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(isSelected ? Theme.Color.textSecondary : Theme.Color.divider, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.m)
    }

    private func filterEmpty(_ model: ArchiveViewModel) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: model.selectedFilter.iconName ?? "photo.stack")
                .scaledDisplayFont(Theme.Size.iconStandalone, weight: .regular)
                .foregroundStyle(Theme.Color.textTertiary)
                .accessibilityHidden(true)
            Text(filterEmptyTitle(for: model.selectedFilter))
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)
            Text(filterEmptyMessage(for: model.selectedFilter))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func filterEmptyTitle(for filter: ArchiveFilter) -> String {
        switch filter {
        case .all: return "No Moments"
        case .bts: return "No Videos"
        case .notes: return "No Notes"
        }
    }

    private func filterEmptyMessage(for filter: ArchiveFilter) -> String {
        switch filter {
        case .all: return "No moments have been captured yet."
        case .bts: return "None of your captured moments include Behind-the-Scenes video."
        case .notes: return "None of your captured moments include micro-journal notes."
        }
    }

    private func dateSpan(for moments: [MomentFacts]) -> String? {
        guard let newest = moments.first?.capturedAt,
              let oldest = moments.last?.capturedAt else { return nil }
        let start = oldest.formatted(.dateTime.month(.abbreviated).year())
        let end = newest.formatted(.dateTime.month(.abbreviated).year())
        return start == end ? start : "\(start) – \(end)"
    }

    private var viewModePicker: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewMode = .grid
                }
            } label: {
                Image(systemName: "square.grid.3x3")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(viewMode == .grid ? Theme.Color.textPrimary : Theme.Color.textTertiary)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.s)
                    .background(viewMode == .grid ? Theme.Color.divider : Color.clear)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Grid view")

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewMode = .calendar
                }
            } label: {
                Image(systemName: "calendar")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(viewMode == .calendar ? Theme.Color.textPrimary : Theme.Color.textTertiary)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.s)
                    .background(viewMode == .calendar ? Theme.Color.divider : Color.clear)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Calendar view")
        }
        .padding(Theme.Spacing.xs)
        .background(Theme.Color.surface)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Theme.Color.divider, lineWidth: 1)
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
            Image(systemName: "photo.stack")
                .scaledDisplayFont(Theme.Size.iconStandalone, weight: .regular)
                .foregroundStyle(Theme.Color.textTertiary)
                .accessibilityHidden(true)
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

/// The viewing modes for the archive.
enum ArchiveViewMode: String, CaseIterable, Identifiable {
    case grid
    case calendar

    var id: String { rawValue }
}

/// Confirmation and information sheet before exporting a timelapse flipbook video.
///
/// Shared by Archive (full library) and Today's same-day-across-years export
/// (ADR-038). Both paths call `PhotoLibraryService.exportFlipbookVideo`.
struct TimelapsePreviewSheet: View {
    let moments: [MomentFacts]
    var title: String = "Timelapse Flipbook"
    var subtitle: String = "Create a stop-motion video of your entire archive in chronological order and save it directly to Photos."
    let isExporting: Bool
    let exportError: String?
    let onExport: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var durationSeconds: Double {
        Double(moments.count) / 2.0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CanvasBackground()

                VStack(spacing: Theme.Spacing.l) {
                    VStack(spacing: Theme.Spacing.s) {
                        Image(systemName: "film.stack")
                            .scaledDisplayFont(Theme.Size.iconStandalone, weight: .regular)
                            .foregroundStyle(Theme.Color.textPrimary)
                            .padding(.top, Theme.Spacing.l)

                        Text(title)
                            .font(Theme.Typography.screenTitle)
                            .foregroundStyle(Theme.Color.textPrimary)

                        Text(subtitle)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.Spacing.l)
                    }

                    // Specs Card
                    VStack(spacing: Theme.Spacing.m) {
                        specRow(icon: "photo.stack", label: "Moments", value: "\(moments.count) captures")
                        Divider().overlay(Theme.Color.divider)
                        specRow(icon: "speedometer", label: "Frame Rate", value: "2 fps")
                        Divider().overlay(Theme.Color.divider)
                        specRow(icon: "clock", label: "Estimated Duration", value: String(format: "%.1f s", durationSeconds))
                        Divider().overlay(Theme.Color.divider)
                        specRow(icon: "square.and.arrow.down", label: "Destination", value: "Photos Library")
                    }
                    .padding(Theme.Spacing.m)
                    .background(Theme.Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.card)
                            .strokeBorder(Theme.Color.divider, lineWidth: 1)
                    }
                    .padding(.horizontal, Theme.Spacing.l)

                    if let exportError {
                        Text(exportError)
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.Color.destructive)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.Spacing.l)
                    }

                    Spacer()

                    if isExporting {
                        HStack(spacing: Theme.Spacing.m) {
                            ProgressView()
                                .tint(Theme.Color.textPrimary)
                            Text("Exporting to Photos...")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.Size.tapTargetComfortable)
                        .background(Theme.Color.surface)
                        .clipShape(Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(Theme.Color.divider, lineWidth: 1)
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.bottom, Theme.Spacing.l)
                    } else {
                        PrimaryButton(title: "Export to Photos") {
                            onExport()
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.bottom, Theme.Spacing.l)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isExporting)
                }
            }
        }
    }

    private func specRow(icon: String, label: String, value: String) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(value)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textPrimary)
        }
    }
}
