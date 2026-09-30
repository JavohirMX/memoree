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
        .onDisappear { Task { await model.stop() } }
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
                    .frame(width: 96)
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
                .frame(width: 72, height: 72)
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
        .animation(.default, value: model.canCapture)
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
    private func composite(_ model: CameraViewModel) -> some View {
        ZStack(alignment: .topLeading) {
            if let prominent = model.prominentPhoto,
               let image = UIImage(data: prominent.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Theme.Color.canvas
            }

            if let inset = model.insetReviewPhoto,
               let image = UIImage(data: inset.data) {
                Button {
                    model.swapProminent()
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 108)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.inset)
                                .strokeBorder(Theme.Color.textPrimary, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .padding(Theme.Spacing.m)
                .accessibilityLabel("Swap the two photos")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Post, or reshoot one half.
    ///
    /// Reshooting is a separate control rather than a tap target, because the
    /// tap on the inset is already taken by swapping. Overloading one target
    /// with two meanings would make the common action unpredictable.
    private func reviewActions(_ model: CameraViewModel) -> some View {
        VStack(spacing: Theme.Spacing.m) {
            PrimaryButton(title: "Post") {
                Task { await model.commit() }
            }

            Menu {
                ForEach(CameraPosition.allCases, id: \.self) { position in
                    Button(position == .front ? "Retake front" : "Retake back") {
                        Task { await model.reshoot(position) }
                    }
                }
                Button("Start over", role: .destructive) {
                    Task { await model.startOver() }
                }
            } label: {
                Text("Retake")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            Button("Cancel") { onDismiss() }
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textTertiary)
        }
    }

    // MARK: - Terminal states

    private var saved: some View {
        VStack(spacing: Theme.Spacing.l) {
            Text("Saved")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            Text("Your photos are in your library.")
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
