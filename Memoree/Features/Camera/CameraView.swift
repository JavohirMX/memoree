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
    /// initialiser cannot, which is why this is not created here.
    @Environment(CameraViewModel.self) private var model

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
                try? await Task.sleep(nanoseconds: 1_200_000_000)
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
    private func live(_ model: CameraViewModel) -> some View {
        VStack(spacing: 0) {
            previewWithInset(model)
                .overlay(alignment: .topLeading) {
                    backButton
                        .padding(Theme.Spacing.m)
                }

            Spacer(minLength: 0)

            if !model.progressDescription.isEmpty {
                Text(model.progressDescription)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.bottom, Theme.Spacing.l)
            }

            shutterRow(model)
        }
    }

    // MARK: - Leaving

    /// The camera's way out: a top-left back arrow button.
    private var backButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "chevron.left")
                .scaledDisplayFont(Theme.Size.headerIcon, weight: .semibold)
                .foregroundStyle(Theme.Color.textPrimary)
                .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                .background(Circle().fill(Theme.Color.canvas.opacity(0.6)))
                .overlay {
                    Circle().strokeBorder(Theme.Color.textSecondary.opacity(0.3), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .accessibilityHint("Closes the camera. Discards in-progress capture")
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
        withAnimation(.none) {
            focusPoint = location
            isFocusRingVisible = true
        }
        Task { await model.focus(at: location) }

        focusFadeTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.35)) { isFocusRingVisible = false }
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
    private func previewWithInset(_ model: CameraViewModel) -> some View {
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
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// The 0.5× / 1× / 2× row, under the shutter.
    ///
    /// ## Why under the shutter and not above it
    ///
    /// A row of buttons competes with the shutter for attention, and the shutter
    /// is the only action that matters. Underneath, the zoom is the second thing
    /// you reach for and the first thing you stop thinking about.
    ///
    /// ## Why it shows all three even on the front camera
    ///
    /// **0.5× is disabled on the front, not hidden.** The front has one lens, so
    /// there is nothing to reach — but a row whose *count* changes when you swap
    /// cameras makes the control look broken rather than constrained, and the
    /// reason is right there in grey next to it. The row keeps its shape and the
    /// camera swap does not move anything on screen.
    private func zoomRow(_ model: CameraViewModel) -> some View {
        // **Filtered, not disabled.** The front has no telephoto, so 2x there is
        // a digital crop of one cheek and the stock camera omits it too. Showing a
        // permanently disabled button is clutter that changes nothing, and the row
        // simply reads "0.5x 1x" on the front.
        //
        // The row does change length when the camera changes, which is the honest
        // consequence and not an oversight.
        let offered = CameraZoom.offered(on: model.livePosition)
        return HStack(spacing: Theme.Spacing.s) {
            ForEach(offered, id: \.self) { zoom in
                zoomButton(zoom, model)
            }
        }
    }

    /// A zoom button, styled as a **circle** rather than a full-width capsule.
    ///
    /// ## Why a circle, and why not full width
    ///
    /// The stock camera draws each magnification as a small circle and fills only
    /// the selected one. Three equal capsules stretched across the width read as
    /// three buttons competing with the shutter above them, and the selection is a
    /// large filled slab rather than a small filled dot — which is the difference
    /// between "a zoom control" and "three more things on this screen".
    ///
    /// ## The tap target is not the circle
    ///
    /// **A 34pt circle with a 44pt target around it.** The circle is what you see;
    /// the frame is what you hit. Shrinking the visible dot to the minimum touch
    /// size would make the row dominate the shutter, which is the one control this
    /// screen exists to offer.
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
                    } else {
                        Circle().strokeBorder(Theme.Color.textPrimary, lineWidth: 1)
                    }
                }
                .opacity(isAvailable ? 1 : 0.35)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        // The visible circle inside a minimum target, not the other way round.
        .frame(minWidth: Theme.Size.tapTarget, minHeight: Theme.Size.tapTarget)
        .contentShape(.rect)
        // **Selected is a trait on the button**, so VoiceOver says which of three
        // identical labels is in force.
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(isAvailable ? "" : "Not available on the front camera")
    }

    private func shutterRow(_ model: CameraViewModel) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            zoomRow(model)

            HStack {
                // Leading balance spacer to keep shutter centered
                Color.clear
                    .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)

                Spacer()

                shutterButton(model)

                Spacer()

                // Working camera flip button on the side
                cameraFlipButton(model)
            }
            .padding(.horizontal, Theme.Spacing.xl)
        }
        .padding(.vertical, Theme.Spacing.m)
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
        }
        .buttonStyle(.plain)
        .disabled(!model.canFlipCamera)
        .opacity(model.canFlipCamera ? 1 : 0.4)
        .accessibilityLabel("Switch camera")
        .accessibilityHint(model.livePositionDescription)
    }

    private func shutterButton(_ model: CameraViewModel) -> some View {
        Button {
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

    /// Both photographs exist. One large, one in a small square, tappable to
    /// swap.
    private func review(_ model: CameraViewModel) -> some View {
        VStack(spacing: 0) {
            composite(model)

            Spacer(minLength: 0)

            if model.retakeCount > 0 {
                Text("\(model.retakeCount) \(model.retakeCount == 1 ? "retake" : "retakes")")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.bottom, Theme.Spacing.m)
            }

            reviewActions(model)
                .padding(.bottom, Theme.Spacing.xl)
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
            onTapInset: { model.swapProminent() }
        )
        // Interactive here and only here: this is the one caller where a double tap
        // swaps the two photographs. The archive and Today versions must not
        // announce as buttons, so the hint and the trait come from the same place
        // as the label — see `CompositeAccessibility`.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CompositeAccessibility.label)
        .accessibilityHint("Double tap to swap which photo is large")
        .accessibilityAddTraits(.isButton)
    }

    /// Post, or reshoot one half.
    ///
    /// Reshooting is a separate control rather than a tap target, because the
    /// tap on the inset is already taken by swapping. Overloading one target
    /// with two meanings would make the common action unpredictable.
    private func reviewActions(_ model: CameraViewModel) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            PrimaryButton(title: model.isCommitting ? "Saving…" : "Save") {
                Task { await model.commit() }
            }
            .disabled(model.isCommitting)

            if !model.isCommitting {
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
