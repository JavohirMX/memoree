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
                // **`MainActor.run` rather than a bare `await`.** `MomentStore` is
                // `@MainActor` and returns a SwiftData model, which is not
                // `Sendable` — so `await environment.momentStore.settings()` hops
                // to the main actor and then tries to hand an `AppSettings` back
                // across, which Swift 6 refuses. Reading the `Bool` *inside* the hop
                // means only a `Bool` crosses, which is the whole reason this is a
                // `Bool` and not a settings object.
                shouldFileIntoAlbum: {
                    await MainActor.run {
                        environment.momentStore.settings().saveToAlbum
                    }
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
