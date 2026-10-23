import SwiftUI

/// The Today screen.
///
/// The whole app in one view: streak, what is true right now, and the shutter.
/// There is no feed, no discovery and no engagement — what remains after the
/// social layer is removed is this.
///
/// Copy follows one rule: state the facts, do not plead. Nothing here mentions
/// the streak having failed, because nothing on screen is allowed to know
/// whether it did (ADR-023). The streak is a number that changed, or did not.
struct TodayView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: TodayViewModel?
    @State private var isShowingCamera = false
    @State private var isShowingSettings = false
    @State private var isShowingArchive = false
    @State private var isShowingStats = false
    @State private var selectedMomentForDetail: MomentFacts?
    /// The memory the trash asked about — the one on screen after a swipe.
    @State private var pendingDelete: MomentFacts?
    @State private var isConfirmingDelete = false
    @State private var isShowingDeleteError = false
    @State private var flippedMoments: Set<UUID> = []
    @State private var playingBTSMoment: MomentFacts?
    @State private var isShowingSameDayFlipbook = false
    @State private var showSameDayFlipbookSavedAlert = false

    var body: some View {
        // The lifecycle modifiers hang off the outermost container, never off
        // `content(model)`. Attaching them inside meant the task that *creates*
        // the model only ran once the model already existed — so it never ran,
        // and the screen stayed black. No unit test caught it; a screenshot did.
        ZStack {
            CanvasBackground()

            if let model {
                content(model)
            }
        }
        .task {
            let created = TodayViewModel(environment: environment)
            self.model = created
            created.startTicking()
            await created.reload()
        }
        .onDisappear { self.model?.stopTicking() }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraHostView { isShowingCamera = false }
                .environment(environment)
        }
        .fullScreenCover(isPresented: $isShowingSettings) {
            SettingsView()
                .environment(environment)
        }
        .fullScreenCover(isPresented: $isShowingStats) {
            StatsView()
                .environment(environment)
        }
        .sheet(isPresented: $isShowingArchive) {
            ArchiveView()
                .environment(environment)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $isShowingSameDayFlipbook) {
            if let model {
                TimelapsePreviewSheet(
                    moments: model.sameDayAcrossYearsMoments,
                    title: "This day across years",
                    subtitle: "A stop-motion of this calendar day from every year you captured it. Saved to Photos.",
                    isExporting: model.isExportingSameDayFlipbook,
                    exportError: model.sameDayFlipbookExportError,
                    onExport: {
                        Task {
                            let success = await model.exportSameDayFlipbook()
                            if success {
                                isShowingSameDayFlipbook = false
                                showSameDayFlipbookSavedAlert = true
                            }
                        }
                    }
                )
            }
        }
        .alert("Saved to Photos", isPresented: $showSameDayFlipbookSavedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The flipbook is in your library.")
        }
        .sheet(item: $selectedMomentForDetail) { moment in
            MomentDetailView(
                moment: moment,
                // Full feed, newest first — not todayMoments. A yesterday card's
                // id is absent from today-only, and the detail pager used to fall
                // through to moments[0] (today's latest) when that happened.
                moments: model?.feedMoments ?? [moment],
                onDelete: { visible in
                    pendingDelete = visible
                    isConfirmingDelete = true
                }
            )
            .environment(environment)
            .presentationDetents([.large])
        }
        .confirmationDialog(
            Self.deleteTitle,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Remove from archive", role: .destructive) { deletePendingMoment() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.deleteMessage)
        }
        .alert(
            "Couldn’t remove from archive",
            isPresented: $isShowingDeleteError
        ) {
            Button("OK", role: .cancel) {
                model?.clearDeleteError()
            }
        } message: {
            Text(model?.deleteError ?? "Please try again.")
        }
        .onChange(of: model?.deleteError) { _, newValue in
            isShowingDeleteError = newValue != nil
        }
        .sheet(item: $playingBTSMoment) { moment in
            NavigationStack {
                VStack(spacing: Theme.Spacing.l) {
                    Spacer()
                    BTSPlaybackView(assetIdentifier: moment.btsAssetIdentifier)
                        .padding(.horizontal, Theme.Spacing.l)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CanvasBackground())
                .navigationTitle("Behind the Scenes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        BackButton {
                            playingBTSMoment = nil
                        }
                    }
                }
            }
            .environment(environment)
            .presentationDetents([.large])
        }
        .onAppear {
            #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                guard let flag = arguments.firstIndex(of: "-MemoreeOpen"),
                      arguments.indices.contains(flag + 1)
                else { return }

                switch arguments[flag + 1] {
                case "archive": isShowingArchive = true
                case "settings": isShowingSettings = true
                case "stats": isShowingStats = true
                case "camera": isShowingCamera = true
                default: break
                }
            #endif
        }
        // Reload when the camera closes, not when this view appears.
        .onChange(of: isShowingCamera) { _, isShowing in
            guard !isShowing else { return }
            Task { await self.model?.reload() }
        }
        .onChange(of: environment.isSavingMomentInBackground) { _, isSaving in
            if !isSaving {
                Task { await self.model?.reload() }
            }
        }
        .task {
            presentCameraIfRequested()
        }
        .onChange(of: environment.pendingCameraRequest) { _, _ in
            presentCameraIfRequested()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            environment.absorbCameraHandoff()
            environment.refreshWidgetSnapshot()
            presentCameraIfRequested()
        }
    }

    /// Opens the camera if a reminder was tapped, and clears the request.
    private func presentCameraIfRequested() {
        guard environment.pendingCameraRequest else { return }
        environment.consumeCameraRequest()
        isShowingCamera = true
    }

    /// Opens the moment detail view.
    private func openDetail(for moment: MomentFacts? = nil) {
        selectedMomentForDetail = moment ?? model?.todayMoment
    }

    /// Opens the archive grid.
    private func openArchive() {
        isShowingArchive = true
    }

    private static let deleteTitle = "Remove from archive?"

    private static let deleteMessage = """
        Your streak will be recalculated without it.

        The two photos stay in your library. Memoree never deletes from Photos.
        """

    /// Tombstones the memory on screen after confirmation — same path as Archive.
    private func deletePendingMoment() {
        guard let model, let pendingDelete else { return }
        model.delete(pendingDelete)
        if model.deleteError == nil {
            selectedMomentForDetail = nil
            self.pendingDelete = nil
        }
    }

    // MARK: - Background Saving Status

    @ViewBuilder
    private var savingStatusPill: some View {
        if environment.isSavingMomentInBackground {
            HStack(spacing: Theme.Spacing.s) {
                ProgressView()
                    .tint(Theme.Color.textPrimary)
                    .scaleEffect(0.8)

                Text("Saving to Photos library…")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Color.surface)
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(Theme.Color.divider, lineWidth: 1)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if let error = environment.backgroundSaveError {
            Button {
                withAppAnimation(.easeInOut(duration: 0.25)) {
                    environment.clearBackgroundSaveError()
                }
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.destructive)

                    Text(error)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .multilineTextAlignment(.leading)

                    Image(systemName: "xmark")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Theme.Color.surface)
                .clipShape(Capsule())
                .overlay {
                    Capsule().strokeBorder(Theme.Color.divider, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(error)
            .accessibilityHint("Dismisses the save error")
            .padding(.vertical, Theme.Spacing.xs)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ model: TodayViewModel) -> some View {
        if verticalSizeClass == .compact {
            landscapeContent(model)
        } else {
            portraitContent(model)
        }
    }

    @ViewBuilder
    private func portraitContent(_ model: TodayViewModel) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header(model)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.top, Theme.Spacing.l)
                    .padding(.bottom, Theme.Spacing.s)
                    .background(Theme.Color.canvas)
                    .overlay(alignment: .bottom) {
                        Theme.Color.divider
                            .frame(height: 1)
                            .accessibilityHidden(true)
                    }

                savingStatusPill

                if model.feedMoments.isEmpty {
                    emptyState(model)
                } else {
                    feed(model)
                }
            }

            floatingShutterButton(model)
                .padding(.bottom, Theme.Spacing.l)
        }
    }

    @ViewBuilder
    private func landscapeContent(_ model: TodayViewModel) -> some View {
        HStack(spacing: Theme.Spacing.l) {
            VStack(spacing: Theme.Spacing.m) {
                header(model)
                savingStatusPill
                Spacer()

                footer(model)
                Spacer()
                floatingShutterButton(model)
            }
            .frame(width: Theme.Size.todayLandscapeSidebarWidth)

            if model.feedMoments.isEmpty {
                emptyState(model)
                    .frame(maxWidth: .infinity)
            } else {
                feed(model)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.s)
    }

    @ViewBuilder
    private func emptyState(_ model: TodayViewModel) -> some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            SettingsCard {
                VStack(spacing: Theme.Spacing.m) {
                    Image(systemName: "camera")
                        .scaledDisplayFont(Theme.Size.iconStandalone, weight: .light)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .padding(.top, Theme.Spacing.s)

                    primaryState(model)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.m)
            }

            Spacer()

            footer(model)
                .padding(.bottom, Theme.Size.feedBottomClearance)
        }
        .padding(.horizontal, Theme.Spacing.xl)
    }

    @ViewBuilder
    private func feed(_ model: TodayViewModel) -> some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.xl) {
                if !model.flashbackMoments.isEmpty {
                    flashbackSection(model)
                }

                ForEach(model.chronologicalFeedDayGroups) { group in
                    feedDaySection(group, in: model)
                }

                footer(model)
                    .padding(.bottom, Theme.Spacing.m)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Size.feedBottomClearance)
        }
    }

    /// One calendar day in the home feed — date once, then the day's cards.
    @ViewBuilder
    private func feedDaySection(_ group: FeedDayGroup, in model: TodayViewModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text(group.title(now: model.now))
                .font(Theme.Typography.metadata.weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, Theme.Spacing.xs)
                .accessibilityAddTraits(.isHeader)

            ForEach(group.moments) { moment in
                feedCard(for: moment, in: model, showsDayInHeader: false)
            }
        }
    }

    @ViewBuilder
    private func flashbackSection(_ model: TodayViewModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)

                Text("ON THIS DAY")
                    .font(Theme.Typography.metadata.weight(.semibold))
                    .foregroundStyle(Theme.Color.textSecondary)

                if let first = model.flashbackMoments.first {
                    Text("· \(model.flashbackDescription(for: first))")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textTertiary)
                }
            }
            .padding(.horizontal, Theme.Spacing.xs)

            ForEach(model.flashbackMoments) { moment in
                feedCard(for: moment, in: model)
            }

            if model.canExportSameDayFlipbook {
                sameDayFlipbookButton
            }

            Theme.Color.divider
                .frame(height: 1)
                .padding(.vertical, Theme.Spacing.xs)
                .accessibilityHidden(true)
        }
    }

    /// Quiet entry to the same-day-across-years flipbook (ADR-038).
    ///
    /// Outline, not filled white — Capture remains the only solid primary verb
    /// on this screen (ADR-026). Hidden entirely when fewer than two years
    /// match; no placeholder copy when the export is not available.
    private var sameDayFlipbookButton: some View {
        Button {
            isShowingSameDayFlipbook = true
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "film")
                    .font(Theme.Typography.metadata)
                Text("This day across years")
                    .font(Theme.Typography.metadata.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Theme.Typography.retakePill)
            }
            .foregroundStyle(Theme.Color.textSecondary)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.m)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.tapTargetComfortable)
            .background(Theme.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Color.divider, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Export this day across years flipbook")
        .padding(.top, Theme.Spacing.xs)
    }

    @ViewBuilder
    private func feedCard(
        for moment: MomentFacts,
        in model: TodayViewModel,
        showsDayInHeader: Bool = true
    ) -> some View {
        let timeString = showsDayInHeader
            ? model.relativeHeader(for: moment)
            : model.feedCardTime(for: moment)

        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if moment.retakeCount > 0 {
                HStack {
                    Spacer()
                    Text("\(moment.retakeCount) \(moment.retakeCount == 1 ? "retake" : "retakes")")
                        .font(Theme.Typography.retakePill)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.horizontal, Theme.Spacing.s)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.Color.surface)
                        .clipShape(Capsule())
                }
            }

            let isFlipped = flippedMoments.contains(moment.id)
            let pair = model.feedImagesMap[moment.id] ?? model.todayImagesMap[moment.id]

            if let pair {
                let large = isFlipped ? pair.inset : pair.large
                let inset = isFlipped ? pair.large : pair.inset

                MomentComposite(
                    large: large,
                    inset: inset,
                    insetWidth: Theme.Size.insetStandard,
                    onTapInset: {
                        toggleFlip(for: moment.id)
                    },
                    onTapLarge: {
                        openDetail(for: moment)
                    },
                    onPlayBTS: moment.hasBTS ? {
                        playingBTSMoment = moment
                    } : nil,
                    timestamp: timeString
                )
                .aspectRatio(aspect(of: large), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Color.divider, lineWidth: 1)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    if moment.hasBTS {
                        Button {
                            playingBTSMoment = moment
                        } label: {
                            Label("Play Behind the Scenes", systemImage: "play.circle")
                        }
                    }
                    Button {
                        openDetail(for: moment)
                    } label: {
                        Label("View in Archive", systemImage: "photo.stack")
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(CompositeAccessibility.label)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens moment detail. Tap inset photo to flip camera angles.")
                .accessibilityAction {
                    openDetail(for: moment)
                }
            } else if model.feedMissingMap.contains(moment.id) || model.todayMissingMap.contains(moment.id) {
                Button {
                    openDetail(for: moment)
                } label: {
                    VStack(spacing: Theme.Spacing.m) {
                        Image(systemName: "photo")
                            .scaledDisplayFont(Theme.Size.iconStandalone, weight: .light)
                            .foregroundStyle(Theme.Color.textSecondary)
                        Text("Photos no longer in your library.")
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.Color.textSecondary)
                            .multilineTextAlignment(.center)
                        Text(timeString)
                            .font(Theme.Typography.retakePill)
                            .foregroundStyle(Theme.Color.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .background(Theme.Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                }
                .buttonStyle(.pressDip)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Photos no longer in your library")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens this moment in your archive")
            } else {
                Theme.Color.surface
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .accessibilityHidden(true)
                    .task {
                        await model.loadImage(for: moment)
                    }
            }

            if let note = moment.note, !note.isEmpty {
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    Image(systemName: "quote.opening")
                        .font(Theme.Typography.retakePill)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .padding(.top, Theme.Spacing.xxs)
                    Text(note)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textPrimary)
                }
                .padding(Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            }
        }
        .task {
            await model.loadImage(for: moment)
        }
    }

    private func toggleFlip(for id: UUID) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAppAnimation(.easeInOut(duration: 0.25)) {
            if flippedMoments.contains(id) {
                flippedMoments.remove(id)
            } else {
                flippedMoments.insert(id)
            }
        }
    }

    private func floatingShutterButton(_ model: TodayViewModel) -> some View {
        Button {
            isShowingCamera = true
        } label: {
            Circle()
                .strokeBorder(Theme.Color.textPrimary, lineWidth: 3)
                .frame(width: Theme.Size.shutter, height: Theme.Size.shutter)
                .background(Circle().fill(Theme.Color.surface.opacity(0.85)))
                .overlay {
                    Circle()
                        .fill(Theme.Color.textPrimary)
                        .padding(Theme.Size.shutterInnerInset)
                }
                .shadow(color: Theme.Color.canvas.opacity(0.6), radius: 8, y: 4)
        }
        .buttonStyle(.pressDip)
        .accessibilityLabel(model.shutterTitle)
    }

    private func aspect(of image: UIImage) -> CGFloat {
        guard image.size.height > 0, image.size.width > 0 else {
            return 3.0 / 4.0
        }
        return image.size.width / image.size.height
    }

    // MARK: - Header

    private func header(_ model: TodayViewModel) -> some View {
        HStack(alignment: .center) {
            Button {
                isShowingStats = true
            } label: {
                StreakDisplay(
                    streak: model.streak,
                    longest: model.longestStreak,
                    isCapturedToday: model.isCapturedToday
                )
            }
            .buttonStyle(.pressDip)
            .accessibilityLabel(
                model.streak == 0
                    ? "No current streak"
                    : "Streak of \(model.streakDescription)"
            )
            .accessibilityHint("Opens your statistics")

            Spacer()

            LiquidGlassGroup {
                HStack(spacing: Theme.Spacing.s) {
                    Button {
                        isShowingArchive = true
                    } label: {
                        Image(systemName: "square.grid.3x3")
                            .scaledDisplayFont(Theme.Size.headerIcon, weight: .semibold)
                            .foregroundStyle(model.summary.totalMoments == 0 ? Theme.Color.textTertiary : Theme.Color.textPrimary)
                    }
                    .liquidGlassCircle()
                    .disabled(model.summary.totalMoments == 0)
                    .opacity(model.summary.totalMoments == 0 ? 0.35 : 1)
                    .accessibilityLabel("Archive")
                    .accessibilityHint(model.summary.totalMoments == 0
                        ? "No moments yet"
                        : "Shows every moment you have captured")

                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .scaledDisplayFont(Theme.Size.headerIcon, weight: .semibold)
                            .foregroundStyle(Theme.Color.textPrimary)
                    }
                    .liquidGlassCircle()
                    .accessibilityLabel("Settings")
                    .accessibilityHint("Opens app settings")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Primary state

    @ViewBuilder
    private func primaryState(_ model: TodayViewModel) -> some View {
        switch model.state {
        case .scheduled:
            VStack(spacing: Theme.Spacing.s) {
                Text(model.showsMomentTime
                    ? "Next moment at \(model.momentClockTime)"
                    : "Memoree will ask you once today")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(model.showsMomentTime
                    ? "Nothing to do until then — but you can capture whenever you like."
                    : "Your phone will remind you. Nothing to do until then.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

        case .open:
            VStack(spacing: Theme.Spacing.s) {
                Text("It's time")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("Capture today's moment — the scene, and you.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

        case .captured:
            EmptyView()

        case .windowPassed:
            VStack(spacing: Theme.Spacing.s) {
                Text("Today's moment has passed")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.Color.textPrimary)
                Text("You can still photograph whenever you like.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Action

    private func action(_ model: TodayViewModel) -> some View {
        PrimaryButton(title: model.shutterTitle) {
            isShowingCamera = true
        }
        .accessibilityHint(model.state.isCaptured
            ? "Captures another moment for today"
            : "Opens the camera")
    }

    // MARK: - Footer

    private func footer(_ model: TodayViewModel) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            if model.showsMomentTime, model.timeUntilMoment != nil {
                MetadataRow(
                    label: "Moment today",
                    value: model.momentClockTime
                )
            }
            if !model.notificationsAuthorized {
                MetadataRow(
                    label: "Reminders",
                    value: "off",
                    valueColor: Theme.Color.accent
                )
            }
            if model.summary.totalMoments > 0 {
                MetadataRow(
                    label: "Captured",
                    value: "\(model.summary.totalMoments)"
                )
            }
            if let albumFailure = model.albumFailure {
                Text(albumFailure)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(
            model.summary.totalMoments > 0
                || !model.notificationsAuthorized
                || model.albumFailure != nil
                ? 1 : 0
        )
    }
}
