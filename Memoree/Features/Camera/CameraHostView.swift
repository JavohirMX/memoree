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
                // **`nil` when BTS is off or there is no real session**, and both
                // are ordinary. See `AppEnvironment.btsRecorder`.
                btsRecorder: environment.btsRecorder,
                // A closure rather than a value, so a length changed in Settings
                // while the camera is open applies to the moment being composed.
                clipDuration: {
                    environment.momentStore.settings().btsDuration
                },
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
                // **Two separate settings, and the difference is the point.**
                // `btsEnabled` is whether to record at all — no microphone, no
                // output, no temporary file. `saveBTS` is whether to write the
                // finished clip to Photos. Someone who wants the clip trimmed but
                // not in their library wants the first without the second, and one
                // toggle cannot express that.
                shouldSaveBTS: {
                    let settings = environment.momentStore.settings()
                    return settings.btsEnabled && settings.saveBTS
                },
                // Reported to the environment rather than only to the camera
                // screen, because that screen is gone by the time anyone could
                // act on it. Today reads it back once on its next reload.
                reportBTSFailure: { environment.noteBTSFailure($0) },
                reportAlbumFailure: { environment.noteAlbumFailure($0) }
            )
            self.model = created
        }
    }
}
