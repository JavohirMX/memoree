import SwiftUI
import UIKit

/// The camera screen.
///
/// One camera live at a time, and the user shoots each in turn (ADR-021). The
/// photograph already taken sits in a small square while the other camera is
/// live, and once both exist the review composite lets you tap the small one to
/// swap which is large.
///
/// Copy follows the Today screen's rule: state the facts, do not plead.
struct CameraView: View {

    /// Injected by `CameraHostView`, which can read the environment. A `@State`
    /// Injected by `CameraHostView`, which can read the environment. A `@State`
    /// initialiser cannot, which is why this is not created here.
    @Environment(CameraViewModel.self) private var model
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var isSaving = false
    @State private var isShutterFlashing = false
    @State private var shutterFlashOpacity: Double = 0

    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        // Lifecycle hangs off the outermost container, never off a branch that
        // renders conditionally. Attaching it inside means the task that
        // *creates* state only runs once the state already exists — so it never
        // runs. That bug black-screened the Today screen in Phase 5 and no unit
        // test caught it; a screenshot did.
        ZStack {
            Theme.Color.canvas.ignoresSafeArea()
            content(model)
        }
        .task { await model.start() }
        .onDisappear {
            holdTheScreenAwake(false)
            Task { await model.stop() }
        }
        .onAppear {
            holdTheScreenAwake(true)
        }
        .task(id: model.phase) {
            if model.phase == .saved {
                onDismiss()
            }
        }
    }

    // MARK: - Keeping the screen awake

    /// Keeps the display on while the camera is up.
    ///
    /// **A capture app that lets the screen lock is broken**, and the failure is
    /// silent and unrecoverable: the user composes a shot, the display dims, the
    /// device locks, iOS tears the capture session down, and the photograph they
    /// were taking is gone — with no error, because there is no error to report
    /// when the app was suspended. It is also the only reason the twenty-moment
    /// device check could report a dead capture daemon
    /// (`FigCaptureSessionRemote: connectionDied`): a test host is a normal app
    /// and locks on the normal schedule, so a long run locks the phone, and the
    /// camera goes with it.
    ///
    /// Scoped to this screen's appearance rather than the app's, because the
    /// guarantee that is wanted is "the screen stays on *while composing*", not
    /// "Memoree never lets the phone sleep". Holding it on the Today screen
    /// would drain a battery to display a streak.
    ///
    /// The inverse is restored on `onDisappear` rather than left to a later
    /// screen, so a failed capture that pops back to Today does not leave the
    /// display pinned on.
    private func holdTheScreenAwake(_ isHeld: Bool) {
        UIApplication.shared.isIdleTimerDisabled = isHeld
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ model: CameraViewModel) -> some View {
        switch model.phase {
        case .permissionDenied:
            noCameraAccess
        case .failed(let message, let isRetryable):
            failure(message: message, isRetryable: isRetryable, model: model)
        case .saved:
            saved
        case .review:
            review(model)
        case .working where model.isCommitting:
            review(model)
        case .idle, .starting, .working, .shooting:
            live(model)
        }
    }

    /// The live preview, the inset, and the shutter.
    @ViewBuilder
    private func live(_ model: CameraViewModel) -> some View {
        if verticalSizeClass == .compact {
            landscapeLive(model)
        } else {
            portraitLive(model)
        }
    }

    private func portraitLive(_ model: CameraViewModel) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            previewWithInset(model)
                .overlay(alignment: .topLeading) {
                    backButton
                        .padding(Theme.Spacing.m)
                }
                .overlay(alignment: .bottom) {
                    zoomRow(model)
                        .padding(.bottom, Theme.Spacing.m)
                }

            if !model.progressDescription.isEmpty {
                Text(model.progressDescription)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.bottom, Theme.Spacing.s)
            } else if model.captured.count == 1 {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "camera.rotate")
                        .font(Theme.Typography.retakePill)
                    Text("2 of 2 • \(model.livePositionDescription)")
                        .font(Theme.Typography.retakePill)
                }
                .foregroundStyle(Theme.Color.textSecondary)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Theme.Color.surface)
                .clipShape(Capsule())
                .transition(.opacity)
            }

            captureControlsRow(model)
        }
    }

    private func landscapeLive(_ model: CameraViewModel) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            previewWithInset(model)
                .overlay(alignment: .topLeading) {
                    backButton
                        .padding(Theme.Spacing.m)
                }
                .padding(.leading, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.xs)

            VStack(spacing: Theme.Spacing.m) {
                Spacer()

                if !model.progressDescription.isEmpty {
                    Text(model.progressDescription)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                }

                zoomRow(model)

                captureControlsRow(model)

                Spacer()
            }
            .padding(.trailing, Theme.Spacing.m)
        }
    }

    // MARK: - Leaving

    /// The camera's way out: a top-left close button, styled like native iOS 27 Liquid Glass.
    @ViewBuilder
    private var backButton: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: onDismiss) {
                Image(systemName: "xmark")
                    .scaledDisplayFont(Theme.Size.headerIcon, weight: .semibold)
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .liquidGlassCircle()
            .accessibilityLabel("Close")
            .accessibilityHint("Closes the camera. Discards in-progress capture")
        } else {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .scaledDisplayFont(Theme.Size.headerIcon, weight: .semibold)
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            .liquidGlassCircle()
            .accessibilityLabel("Close")
            .accessibilityHint("Closes the camera. Discards in-progress capture")
        }
    }

    // MARK: - Tap to focus

    /// Where the last tap landed, in view coordinates, or `nil` when there is no
    /// ring on screen.
    @State private var focusPoint: CGPoint?

    /// Whether the ring is still bright. It appears on the tap and fades a beat
    /// later, which is the stock camera's confirmation that the tap was taken.
    @State private var isFocusRingVisible = false

    /// The task that fades the ring, cancelled by the next tap.
    ///
    /// Held so a second tap can cancel the first tap's fade. Without this, two
    /// quick taps leave two tasks racing to hide the ring, and the ring vanishes
    /// on whichever schedule finishes first rather than the second one.
    @State private var focusFadeTask: Task<Void, Never>?

    /// Handles a tap on the preview.
    ///
    /// **The ring is white, not yellow.** The stock camera draws its focus ring in
    /// yellow, and ADR-025 gives this app's one amber a single reserved job: a
    /// permission the user declined and can only fix in system Settings. A focus
    /// ring on every tap would spend that colour on something decorative and make
    /// it meaningless — which is precisely what ADR-025 exists to prevent. White
    /// reads just as clearly over a camera preview and stays inside the design
    /// system.
    private func focus(_ model: CameraViewModel, at location: CGPoint) {
        focusFadeTask?.cancel()
        withAppAnimation(.none) {
            focusPoint = location
            isFocusRingVisible = true
        }
        Task { await model.focus(at: location) }

        focusFadeTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAppAnimation(.easeOut(duration: 0.35)) { isFocusRingVisible = false }
            }
            // Kept on screen at low opacity rather than removed, because a ring
            // that vanishes and reappears on each tap is jumpier than one that
            // dims — and a second tap on the same spot shows the focus is still
            // there.
        }
    }

    /// The focus ring: a square, like the stock camera's, at the last tap.
    @ViewBuilder
    private var focusRing: some View {
        if let focusPoint {
            RoundedRectangle(cornerRadius: Theme.Spacing.xs)
                .strokeBorder(Theme.Color.textPrimary, lineWidth: 1)
                .frame(width: Theme.Size.focusRing, height: Theme.Size.focusRing)
                .opacity(isFocusRingVisible ? 1 : 0.4)
                .position(focusPoint)
                // One element, one label: a ring is decoration that confirms an
                // action, and VoiceOver announcing "image" six times is noise.
                .accessibilityHidden(true)
        }
    }

    /// The live camera, with the photograph already taken in the top-left
    /// square when there is one.
    ///
    /// The inset is **not** tappable here. The large view has to stay live —
    /// it is what the user is composing with — and promoting the inset would
    /// cover the camera they are about to shoot. Tapping to swap is the review
    /// behaviour, where both slots are photographs.
    ///
    /// **3:4 viewport, not full-bleed.** The saved still is 3:4. Filling the
    /// whole (taller) phone screen with `.resizeAspectFill` crops the left and
    /// right of that frame — so ultra-wide looked tight in preview and wide in
    /// the photo. Matching the review/composite aspect keeps WYSIWYG.
    private func previewWithInset(_ model: CameraViewModel) -> some View {
        ZStack {
            Theme.Color.canvas

            ZStack(alignment: .topLeading) {
                if let layer = model.previewLayer {
                    CameraPreview(layer: layer)
                        // **Tap to focus, and it is a `.simultaneousGesture` rather than
                        // the inset's own tap.** The inset is non-interactive here on
                        // purpose (see the documentation below), so there is nothing to
                        // conflict with — but `simultaneous` is what keeps a future
                        // gesture on the preview from silently swallowing this one.
                        .simultaneousGesture(
                            SpatialTapGesture().onEnded { value in focus(model, at: value.location) }
                        )
                        // The view is the only thing that knows the preview's size,
                        // and `focus(at:)` needs it to normalise a tap.
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                            model.previewSize = size
                        }
                } else {
                    Theme.Color.canvas
                }

                focusRing

                if isShutterFlashing {
                    Theme.Color.textPrimary
                        .opacity(shutterFlashOpacity)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let inset = model.insetPhoto,
                   let image = UIImage(data: inset.data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Theme.Size.insetStandard, height: Theme.Size.insetStandard)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.inset)
                                .strokeBorder(Theme.Color.textPrimary, lineWidth: 1)
                        }
                        .padding(Theme.Spacing.m)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
            .appAnimation(model.insetPhoto?.data) { .spring(response: 0.35, dampingFraction: 0.8) }
            .overlay {
                if model.torchMode == .on, model.livePosition == .front {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .strokeBorder(Theme.Color.textPrimary.opacity(0.8), lineWidth: 4)
                        .padding(Theme.Spacing.xs)
                        .allowsHitTesting(false)
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            // Full Y-flip covers the session freeze; dim + blur stay on until
            // the new camera is ready, then clear on unfold. Swap starts as
            // soon as the cover turns on (no animation sleep before it).
            .opacity(model.isCameraSwitching ? 0.45 : 1)
            .blur(radius: model.isCameraSwitching ? 8 : 0)
            .scaleEffect(model.isCameraSwitching ? 0.98 : 1)
            .rotation3DEffect(
                .degrees(model.cameraSwitchDegrees),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.65
            )
            .appAnimation(model.isCameraSwitching) {
                .easeInOut(duration: 0.2)
            }
            .padding(.horizontal, Theme.Spacing.m)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The 0.5× / 1× / 2× zoom capsule, styled like native iOS camera.
    private func zoomRow(_ model: CameraViewModel) -> some View {
        let offered = CameraZoom.offered(on: model.livePosition)
        return HStack(spacing: Theme.Spacing.xs) {
            ForEach(offered, id: \.self) { zoom in
                zoomButton(zoom, model)
            }
        }
        .padding(Theme.Spacing.xs)
        .background(Capsule().fill(Theme.Color.canvas.opacity(0.65)))
    }

    /// A zoom button inside the native camera zoom pill.
    ///
    /// Drawn at `Theme.Size.zoomButton` (34pt, stock camera); hit region is
    /// `Theme.Size.tapTarget` (44pt) via `expandedCircularHitTarget`.
    private func zoomButton(_ zoom: CameraZoom, _ model: CameraViewModel) -> some View {
        let isSelected = model.zoom == zoom
        let isAvailable = zoom.isAvailable(on: model.livePosition)

        return Button {
            Task { await model.chooseZoom(zoom) }
        } label: {
            Text(zoom.label)
                .font(Theme.Typography.zoomLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(isSelected ? Theme.Color.onAccent : Theme.Color.textPrimary)
                .frame(width: Theme.Size.zoomButton, height: Theme.Size.zoomButton)
                .background {
                    if isSelected {
                        Circle().fill(Theme.Color.textPrimary)
                    }
                }
                .opacity(isAvailable ? 1 : 0.4)
                .expandedCircularHitTarget()
        }
        .buttonStyle(.pressDip)
        .disabled(!isAvailable)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(isAvailable ? "" : "Not available on the front camera")
    }

    private func captureControlsRow(_ model: CameraViewModel) -> some View {
        HStack {
            // Torch toggle on the leading side
            torchButton(model)

            Spacer()

            shutterButton(model)

            Spacer()

            // Working camera flip button on the side
            cameraFlipButton(model)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.s)
    }

    private func torchButton(_ model: CameraViewModel) -> some View {
        Button {
            Task { await model.toggleTorch() }
        } label: {
            Image(systemName: model.torchMode == .on ? "bolt.fill" : "bolt.slash")
                .scaledDisplayFont(Theme.Size.headerIcon, weight: .regular)
                .foregroundStyle(model.torchMode == .on ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                .background(Circle().fill(model.torchMode == .on ? Theme.Color.divider : Theme.Color.surface.opacity(0.8)))
                .contentShape(Circle())
        }
        .buttonStyle(.pressDip)
        .disabled(!model.canToggleTorch)
        .opacity(model.canToggleTorch ? 1 : 0.4)
        .accessibilityLabel(model.torchMode == .on ? "Turn torch off" : "Turn torch on")
    }

    private func cameraFlipButton(_ model: CameraViewModel) -> some View {
        Button {
            Task { await model.flipCamera() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .scaledDisplayFont(Theme.Size.headerIcon, weight: .regular)
                .foregroundStyle(model.canFlipCamera ? Theme.Color.textPrimary : Theme.Color.textTertiary)
                .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                .background(Circle().fill(Theme.Color.surface.opacity(0.8)))
                .contentShape(Circle())
        }
        .buttonStyle(.pressDip)
        .disabled(!model.canFlipCamera)
        .opacity(model.canFlipCamera ? 1 : 0.4)
        .accessibilityLabel("Switch camera")
        .accessibilityHint(model.livePositionDescription)
    }

    private func triggerShutterFlash() {
        isShutterFlashing = true
        shutterFlashOpacity = 0.85
        withAppAnimation(.easeOut(duration: 0.1)) {
            shutterFlashOpacity = 0
        }
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            await MainActor.run {
                isShutterFlashing = false
            }
        }
    }

    private func shutterButton(_ model: CameraViewModel) -> some View {
        Button {
            triggerShutterFlash()
            Task { await model.shutterPressed() }
        } label: {
            Circle()
                .strokeBorder(Theme.Color.textPrimary, lineWidth: 3)
                .frame(width: Theme.Size.shutter, height: Theme.Size.shutter)
                .overlay {
                    Circle()
                        .fill(Theme.Color.textPrimary)
                        .padding(Theme.Size.shutterInnerInset)
                }
        }
        // **The shutter dips on press** — see `PressDipStyle` for why this is the
        // only feedback a press gets. `.plain` would not hold state through the
        // press, and the previous attempt used an `@State` flag that nothing ever
        // set, so it compiled and did nothing.
        .buttonStyle(.pressDip)
        .disabled(!model.canCapture)
        .opacity(model.canCapture ? 1 : 0.4)
        .accessibilityLabel("Take a photo")
        .appAnimation(model.canCapture)
    }

    // MARK: - Review

    /// Calculates the aspect ratio of the prominent photo, falling back to 3:4 portrait.
    private func compositeAspectRatio(_ model: CameraViewModel) -> CGFloat {
        if let photo = model.prominentPhoto,
           let image = UIImage(data: photo.data),
           image.size.height > 0 {
            return image.size.width / image.size.height
        }
        return 3.0 / 4.0
    }

    /// Both photographs exist. One large, one in a small square, tappable to
    /// swap.
    @ViewBuilder
    private func review(_ model: CameraViewModel) -> some View {
        if verticalSizeClass == .compact {
            landscapeReview(model)
        } else {
            portraitReview(model)
        }
    }

    private func portraitReview(_ model: CameraViewModel) -> some View {
        VStack(spacing: 0) {
            composite(model)
                .aspectRatio(compositeAspectRatio(model), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .padding(.horizontal, Theme.Spacing.m)
                .frame(maxHeight: Theme.Size.cameraReviewMaxHeight)

            Spacer(minLength: Theme.Spacing.s)

            noteInput(model)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.m)

            if model.retakeCount > 0 {
                Text("\(model.retakeCount) \(model.retakeCount == 1 ? "retake" : "retakes")")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.bottom, Theme.Spacing.m)
            }

            reviewActions(model)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xl)
        }
    }

    private func landscapeReview(_ model: CameraViewModel) -> some View {
        HStack(spacing: Theme.Spacing.l) {
            composite(model)
                .aspectRatio(compositeAspectRatio(model), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .padding(.leading, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.xs)

            ScrollView {
                VStack(spacing: Theme.Spacing.m) {
                    noteInput(model)

                    if model.retakeCount > 0 {
                        Text("\(model.retakeCount) \(model.retakeCount == 1 ? "retake" : "retakes")")
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.Color.textSecondary)
                    }

                    reviewActions(model)
                }
                .padding(.trailing, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
            }
        }
    }

    private func noteInput(_ model: CameraViewModel) -> some View {
        @Bindable var bindableModel = model
        return HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "pencil.line")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textTertiary)

            TextField(
                "Add a note...",
                text: Binding(
                    get: { bindableModel.draftNote },
                    set: { bindableModel.draftNote = String($0.prefix(CameraViewModel.noteCharacterLimit)) }
                ),
                prompt: Text("Add a note...").foregroundStyle(Theme.Color.textSecondary)
            )
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Color.textPrimary)
            .tint(Theme.Color.textPrimary)
            .submitLabel(.done)

            if !model.draftNote.isEmpty {
                Text("\(model.draftNote.count)/\(CameraViewModel.noteCharacterLimit)")
                    .font(Theme.Typography.retakePill)
                    .foregroundStyle(
                        model.draftNote.count >= CameraViewModel.noteCharacterLimit
                            ? Theme.Color.textSecondary
                            : Theme.Color.textTertiary
                    )
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(Theme.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.inset)
                .strokeBorder(Theme.Color.divider, lineWidth: 1)
        }
    }

    /// BeReal's composite geometry: one photograph large, the other inset
    /// top-left at a 14pt radius. Tapping the inset promotes it.
    ///
    /// The geometry itself lives in `MomentComposite` because the Today screen
    /// draws the same thing, and two copies of a composite is how one of them
    /// ends up with a different inset width.
    private func composite(_ model: CameraViewModel) -> some View {
        MomentComposite(
            large: model.prominentPhoto.flatMap { UIImage(data: $0.data) },
            inset: model.insetReviewPhoto.flatMap { UIImage(data: $0.data) },
            insetWidth: Theme.Size.insetCamera,
            onTapInset: { model.swapProminent() },
            onDoubleTapLarge: { model.swapProminent() },
            onFlip: { model.swapProminent() }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CompositeAccessibility.label)
        .accessibilityHint("Double tap or press flip to swap which photo is large")
        .accessibilityAddTraits(.isButton)
    }

    /// Post, or reshoot one half.
    ///
    /// Reshooting is a separate control rather than a tap target, because the
    /// tap on the inset is already taken by swapping. Overloading one target
    /// with two meanings would make the common action unpredictable.
    private func reviewActions(_ model: CameraViewModel) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            PrimaryButton(title: isSaving ? "Saved" : (model.isCommitting ? "Saving…" : "Save")) {
                isSaving = true
                model.triggerCommitHaptic()
                if let environment {
                    environment.beginBackgroundSave {
                        await model.commit()
                    }
                    onDismiss()
                } else {
                    Task {
                        await model.commit()
                    }
                }
            }
            .disabled(isSaving || model.isCommitting)

            if !isSaving && !model.isCommitting {
                Menu {
                    ForEach(CameraPosition.allCases, id: \.self) { position in
                        Button(position == .front ? "Reshoot front" : "Reshoot back") {
                            Task { await model.reshoot(position) }
                        }
                    }
                    // **Destructive, and separated.** It sits below the two routine
                    // reshoots in its own `Divider`-separated group, because "throw
                    // both photographs away" and "shoot that half again" are not the
                    // same kind of decision and one tap should not be ambiguous about
                    // which it will be.
                    Section {
                        Button("Start over", role: .destructive) {
                            Task { await model.startOver() }
                        }
                    }
                } label: {
                    Text("Reshoot")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.Size.tapTarget)
                        .contentShape(.rect)
                }

                Button("Cancel") { onDismiss() }
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: Theme.Size.tapTarget)
                    .contentShape(.rect)
            }
        }
    }

    // MARK: - Terminal states

    private var saved: some View {
        VStack(spacing: Theme.Spacing.l) {
            Text("Saved")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            // Both facts, because both are true and the user has just done two
            // things. Saying only "in your library" undersells the second, and
            // saying only "archived" hides the one they can go and check.
            Text("The moment is in your archive, and both photos are in your library.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)

            PrimaryButton(title: "Done") { onDismiss() }
                .padding(.top, Theme.Spacing.m)
        }
        .padding(Theme.Spacing.xl)
    }

    /// Named `noCameraAccess` rather than `permissionDenied`: the latter is an
    /// enum case of `CameraViewModel.Phase`, and a member sharing that name
    /// shadows it at the use site.
    private var noCameraAccess: some View {
        VStack(spacing: Theme.Spacing.l) {
            Text("No camera access")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            Text("""
                Memoree cannot capture without the camera. You can turn it on in \
                Settings. Your archive and streaks are unaffected.
                """)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: Theme.Spacing.m) {
                PrimaryButton(title: "Back") { onDismiss() }

                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(minHeight: Theme.Size.tapTarget)
                .contentShape(.rect)
                .accessibilityHint("Opens system Settings to enable camera access")
            }
            .padding(.top, Theme.Spacing.m)
        }
        .padding(Theme.Spacing.xl)
    }

    private func failure(message: String, isRetryable: Bool, model: CameraViewModel) -> some View {
        VStack(spacing: Theme.Spacing.l) {
            Text("The camera did not work")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            Text(message)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: Theme.Spacing.m) {
                if isRetryable {
                    PrimaryButton(title: "Try again") {
                        Task { await model.retry() }
                    }
                }

                Button("Back") { onDismiss() }
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(minHeight: Theme.Size.tapTarget)
                    .contentShape(.rect)
            }
            .padding(.top, Theme.Spacing.m)
        }
        .padding(Theme.Spacing.xl)
    }
}
