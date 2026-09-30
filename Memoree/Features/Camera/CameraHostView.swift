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
                photoLibrary: environment.photoLibrary
            )
            self.model = created
        }
    }
}
