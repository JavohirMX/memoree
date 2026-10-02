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

    /// Read for their *changes*, which is the trigger for re-reporting rotation.
    ///
    /// Every rotation between the four orientations on iPhone flips at least one
    /// of these, and there is no SwiftUI environment key for interface
    /// orientation — so this is the signal that says "go and read it again".
    /// Neither is used for anything else.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
        // **Rotation is reported from the view, not the service.** `Services/`
        // must not reach for a view layer to learn how the phone is being held
        // (`AGENTS.md` §3), so the view observes, the view model reports, and the
        // service only ever sees its own `DeviceOrientation`.
        //
        // Three reports rather than one `onChange`: on appear, and on either size
        // class changing. An `onChange` on an orientation value only fires when
        // the value *changes*, so a camera opened already sideways was never
        // reported at all — which is the other half of why landscape did not save.
        .onChange(of: verticalSizeClass) { _, _ in reportCurrentOrientation(model) }
        .onChange(of: horizontalSizeClass) { _, _ in reportCurrentOrientation(model) }
    }

    // MARK: - Rotation

    /// Reports the current orientation to the camera, whenever it might have changed.
    ///
    /// ## Why this reads the window scene and not `UIDevice`
    ///
    /// **`UIDevice.current.orientation` is `.unknown` unless
    /// `beginGeneratingDeviceOrientationNotifications()` has already been called**,
    /// and even after it, the value arrives a runloop turn later. The first
    /// version of this read it from `.task`, whose ordering against `.onAppear` is
    /// not guaranteed — so the camera opened with `.unknown`, `rotation(for:)`
    /// returned `nil`, and **no rotation was applied at all**. Landscape
    /// photographs saved sideways, which is how it was found.
    ///
    /// `UIWindowScene.interfaceOrientation` has neither problem: it is available
    /// immediately, it is never `.unknown`, and it is exactly the question being
    /// asked — which way is the screen.
    ///
    /// It also gets **face-up and face-down right for free**: laying the phone on a
    /// table does not change the interface orientation, so the last good rotation
    /// simply stands, which is what `CaptureOrientation` wants for those cases.
    ///
    /// ## Why size classes
    ///
    /// There is no SwiftUI `EnvironmentKey` for interface orientation, so something
    /// has to re-read it. A size-class change is the reliable trigger on iPhone:
    /// every rotation between the four orientations flips `verticalSizeClass` or
    /// `horizontalSizeClass`. Combined with an initial read on appear, that covers
    /// "opened in landscape" as well as "rotated while open" — and the first
    /// version covered neither.
    private func reportCurrentOrientation(_ model: CameraViewModel) {
        Task { await model.reportOrientation(Self.interfaceOrientation()) }
    }

    /// The window scene's interface orientation, as the app's own enum.
    ///
    /// **Falls back to portrait**, because every orientation that matters has a
    /// defined rotation and a nil here would leave the camera on whatever it had.
    /// `UIDevice` is not consulted at all — see the note above.
    static func interfaceOrientation() -> DeviceOrientation {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        switch scene?.interfaceOrientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        case .none: return .portrait
        @unknown default: return .portrait
        }
    }

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
        case .idle, .starting, .working, .shooting:
            live(model)
        }
    }

    /// The live preview, the inset, and the shutter.
    private func live(_ model: CameraViewModel) -> some View {
        VStack(spacing: 0) {
            previewWithInset(model)
                // **The way out, which used to be the swipe gesture.**
                //
                // The camera was a full-screen cover with a shutter at the bottom
                // and nothing else, so the only route back was an edge swipe the
                // app never claimed and iOS only honours from the very edge. There
                // was no visible control, and a review state that *did* have a
                // visible "Cancel" — so the exit appeared only once you had
                // already committed to taking a photograph, which is the worst
                // moment to discover whether you can leave.
                .overlay(alignment: .topTrailing) {
                    cancelButton
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

    /// The camera's way out.
    ///
    /// **A labelled capsule, not a bare glyph.** A lone `chevron.down` in the
    /// top corner is the platform idiom and it is also easy to miss — especially
    /// here, where the preview behind it can be any colour and a white glyph on
    /// white is invisible. The black fill solves that: the control has the same
    /// appearance over a bright sky and over a dark room.
    ///
    /// It borrows `PrimaryButton(.outlined)`'s shape on purpose — 1pt white
    /// border, black interior — so it reads as part of the app rather than as
    /// iOS chrome that happened to be on top. It is smaller than a primary
    /// control and never filled, because the shutter is the thing this screen
    /// wants.
    ///
    /// **It discards whatever has been shot.** One photograph in the inset and
    /// nothing recorded yet means cancelling loses it, which is the intended
    /// reading: `onDismiss` writes no moment, so a half-finished capture leaves
    /// no trace rather than a moment with one photograph in it.
    private var cancelButton: some View {
        Button(action: onDismiss) {
            Label("Cancel", systemImage: "chevron.down")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textPrimary)
                .padding(.horizontal, Theme.Spacing.m)
                .frame(minHeight: Theme.Size.tapTarget)
                .background(Theme.Color.canvas)
                .clipShape(Capsule())
                .overlay {
                    Capsule().strokeBorder(Theme.Color.textPrimary, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Closes the camera. Anything you have shot is discarded")
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
            } else {
                Theme.Color.canvas
            }

            if let inset = model.insetPhoto,
               let image = UIImage(data: inset.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Theme.Size.insetStandard)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.inset)
                            .strokeBorder(Theme.Color.textPrimary, lineWidth: 1)
                    }
                    .padding(Theme.Spacing.m)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func shutterRow(_ model: CameraViewModel) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            HStack {
                Spacer()

                shutterButton(model)

                Spacer()
            }

            // Which camera they are composing with. Stated as a fact, because
            // the order is random per moment (ADR-021) and there is no other
            // way to know which is live.
            Text(model.livePositionDescription)
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(.vertical, Theme.Spacing.xl)
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
                        .padding(6)
                }
        }
        .buttonStyle(.plain)
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
            PrimaryButton(title: "Save") {
                Task { await model.commit() }
            }

            // **Both controls get an explicit 44pt floor.**
            //
            // Their heights were coming from their fonts: a `.subheadline` label
            // with no frame is ~20pt tall and a `.footnote` one is ~17pt, against
            // Apple's 44pt minimum. On a screen held one-handed in the dark, at the
            // exact moment a user is deciding whether to keep or discard a
            // photograph, that is the worst place in the app for a 17pt target.
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
                .foregroundStyle(Theme.Color.textTertiary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.Size.tapTarget)
                .contentShape(.rect)
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

            // No retry offered: retrying cannot change a permission the user
            // declined, and a button that always fails is a dead end
            // (AGENTS.md §6).
            PrimaryButton(title: "Back") { onDismiss() }
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
            }
            .padding(.top, Theme.Spacing.m)
        }
        .padding(Theme.Spacing.xl)
    }
}
