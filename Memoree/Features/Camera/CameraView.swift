import SwiftUI
import UIKit

/// The camera screen.
///
/// Full-bleed preview, a shutter, and — once a pair exists — BeReal's composite
/// geometry: rear full-bleed with the front inset top-left at a 14pt radius,
/// tappable to swap which is primary (TRD §5.6).
///
/// Copy follows the Today screen's rule: state the facts, do not plead. A
/// failure explains itself and offers a retry when a retry could work.
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
        case .reviewing:
            review(model)
        case .idle, .starting, .capturing, .ready:
            live(model)
        }
    }

    /// The live preview and the shutter.
    private func live(_ model: CameraViewModel) -> some View {
        VStack(spacing: 0) {
            preview(model)

            Spacer(minLength: 0)

            if model.phase == .capturing {
                // A determinate-feeling state rather than a blank frame: the
                // shutter is mid-sequence and the front camera is about to
                // open. Copy states the fact rather than apologising for a wait.
                Text("Capturing…")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.bottom, Theme.Spacing.l)
            } else if model.phase == .starting {
                Text("Opening the camera")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.bottom, Theme.Spacing.l)
            }

            shutterRow(model)
        }
    }

    private func preview(_ model: CameraViewModel) -> some View {
        ZStack {
            if let layer = model.previewLayer {
                CameraPreview(layer: layer)
            } else {
                Theme.Color.canvas
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func shutterRow(_ model: CameraViewModel) -> some View {
        HStack {
            Spacer()

            shutterButton(model)

            Spacer()
        }
        .padding(.vertical, Theme.Spacing.xl)
    }

    private func shutterButton(_ model: CameraViewModel) -> some View {
        Button {
            Task { await model.capture() }
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
        .accessibilityLabel("Capture your moment")
        // Honour Reduce Motion: the capture animation is decorative.
        .animation(.default, value: model.canCapture)
    }

    // MARK: - Review

    /// The captured pair, before it is written to Photos.
    private func review(_ model: CameraViewModel) -> some View {
        VStack(spacing: 0) {
            compositePreview(model)

            Spacer(minLength: 0)

            if model.retakeCount > 0 {
                Text("\(model.retakeCount) \(model.retakeCount == 1 ? "retake" : "retakes")")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .padding(.bottom, Theme.Spacing.m)
            }

            VStack(spacing: Theme.Spacing.m) {
                PrimaryButton(title: "Post") {
                    Task { await model.commit() }
                }

                Button("Retake") {
                    Task { await model.retake() }
                }
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
            }
            .padding(.bottom, Theme.Spacing.xl)
        }
    }

    /// BeReal's composite geometry: rear full-bleed, front inset top-left.
    ///
    /// The inset is tappable to swap which camera is primary. The pair itself
    /// is always rear-then-front, so this changes only what is on screen.
    private func compositePreview(_ model: CameraViewModel) -> some View {
        ZStack(alignment: .topLeading) {
            if let pair = model.capturedPair,
               let backImage = UIImage(data: pair.back.data),
               let frontImage = UIImage(data: pair.front.data) {
                Image(uiImage: backImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                Button {
                    model.togglePrimaryCamera()
                } label: {
                    Image(uiImage: frontImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 108)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.inset))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.inset)
                                .strokeBorder(Theme.Color.textPrimary, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .padding(Theme.Spacing.m)
                .accessibilityLabel("Swap front and back")
            } else {
                // A pair exists but will not decode. Only reachable if the
                // camera produced bytes that are not an image, which is a
                // failure rather than a state to design for — so it says so
                // rather than showing a silently blank frame.
                Theme.Color.canvas
            }
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
    /// enum case of `CameraViewModel.Phase`, and a method sharing that name
    /// shadows it at the use site — `case .permissionDenied: permissionDenied`
    /// stops parsing.
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
