import SwiftUI

/// Builds the camera screen's view model from the environment.
///
/// `CameraView` takes its model as state, and a `@State` initialiser cannot
/// read the environment — so the model is created here, one level up, where the
/// environment *is* available. This is the same shape `TodayView` uses, and for
/// the same reason: the model must be created by a container that exists before
/// the model does, or the task that creates it never runs.
struct CameraHostView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var model: CameraViewModel?

    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Theme.Color.canvas.ignoresSafeArea()

            if let model {
                CameraView(onDismiss: onDismiss)
                    .environment(model)
            }
        }
        .task {
            guard model == nil else { return }
            let created = CameraViewModel(
                service: environment.captureService,
                photoLibrary: environment.photoLibrary,
                haptics: environment.haptics,
                record: environment.makeMomentRecorder(),
                // Read per commit rather than captured once, so the Settings
                // toggle applies to a moment captured before it was flipped as
                // well as one captured after.
                //
                // **No `MainActor.run` hop.** There used to be one, and its comment
                // explained at length that `MomentStore` is `@MainActor` and its
                // SwiftData models are not `Sendable`. True — and irrelevant,
                // because the hop was only ever needed to satisfy the `@Sendable`
                // that was wrongly written on this closure type. `CameraViewModel`
                // is `@MainActor` and calls this from the main actor, so the read
                // is already isolated and there is nothing crossing anything.
                // The hop now only obscured that.
                shouldFileIntoAlbum: {
                    environment.momentStore.settings().saveToAlbum
                },
                // Reported to the environment rather than only to the camera
                // screen, because that screen is gone by the time anyone could
                // act on it. Today reads it back once on its next reload.
                reportAlbumFailure: { environment.noteAlbumFailure($0) }
            )
            self.model = created
        }
    }
}
