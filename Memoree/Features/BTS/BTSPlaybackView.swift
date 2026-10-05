import AVFoundation
import AVKit
import SwiftUI

/// Plays a moment's Behind-the-Scenes clip.
///
/// ## The one AVFoundation and AVKit import in `Features/`, and why it is here
/// (ADR-029)
///
/// Every other file in this layer holds SwiftUI and the service protocols, and the
/// rule in `AGENTS.md` §3 that says so has held without exception — nothing under
/// `Features/` imported either framework before this. `VideoPlayer` is AVKit's,
/// which the ADR covers alongside AVFoundation because they arrive together and a
/// rule listing one without the other is a rule that gets re-litigated. Playback is
/// what broke it, and the options were three:
///
/// 1. **Put the player here.** A view is presentation; `AVPlayer` is presentation.
///    The *view model* in this file still never names AVFoundation, which is the
///    half of the rule that was never about presentation.
/// 2. **Put it in `DesignSystem`.** That layer imports nothing internal, so it
///    satisfies the rule as written — and it is the wrong home for a control only
///    one feature uses. A layer whose rule is never broken is a layer nobody has to
///    think about.
/// 3. **Do not have playback.** The clip lands in Photos and the user opens it
///    there. This is the option the app effectively had, and it is not a decision:
///    a control that writes a video nobody can open from inside the app is half a
///    feature, and "a video that will not play" was the failure most likely to ship.
///
/// So: one file, two imports, one row in `AGENTS.md` §3's exception table. The
/// rule was worth keeping and this is what keeping it cost, written down where the
/// next reader will find it.
///
/// ## Why the bytes come from a file
///
/// `PhotoLibraryService.btsClipFile(for:)` hands back a `URL` rather than an
/// `AVAsset`. That is not incidental: an `AVAsset` on a service protocol drags
/// AVFoundation into every consumer, is not `Sendable`, and its `url` for a library
/// asset is an implementation detail rather than a promise. See the protocol.
struct BTSPlaybackView: View {

    @Environment(AppEnvironment.self) private var environment

    /// The asset to play, or `nil` when the user deleted it in Photos.
    let assetIdentifier: String?

    @State private var model: BTSPlaybackModel?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            player
            controls
        }
        .task(id: assetIdentifier) { await prepare() }
        // **Stop on disappear, not on a timer.** The player holds a file handle and
        // a decode pipeline; leaving it running under a dismissed sheet is audio
        // from a screen nobody is looking at.
        .onDisappear { teardown() }
    }

    // MARK: - Player

    @ViewBuilder
    private var player: some View {
        if let model, let player = model.player {
            VideoPlayer(player: player)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .background(Theme.Color.canvas)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .accessibilityLabel("Behind the Scenes clip")
        } else if model?.failure != nil {
            // **Said, not shown as a black rectangle.** A frame that will not play
            // looks like a rendering bug; the truth is that the clip is gone from
            // Photos, which the user did and can undo (ADR-008).
            VStack(spacing: Theme.Spacing.m) {
                Image(systemName: "video.slash")
                    .scaledDisplayFont(Theme.Size.iconStandalone, weight: .regular)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .accessibilityHidden(true)
                Text(model?.failure ?? "The clip is unavailable.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .background(Theme.Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        } else {
            // Not resolved yet. Flat, like every other loading state here — see
            // `MomentDetailView.photograph` for why this is not a spinner.
            Theme.Color.surface
                .frame(maxWidth: .infinity)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Controls

    /// Play/pause and mute, and nothing else.
    ///
    /// **No scrubber, no volume, no full screen.** The clip is at most fifteen
    /// seconds and it plays once; a full transport would be a video app wearing
    /// this app's name, which is the objection `BTSTrim.maximumClipDuration` was
    /// written with.
    ///
    /// **Mute is on by default and the control is offered anyway.** A clip with
    /// sound plays silently until asked, because Memoree is a thing you open in a
    /// queue, on a train, in a lecture. The control is not hidden behind the
    /// default; it is right there.
    @ViewBuilder
    private var controls: some View {
        if let model, model.player != nil {
            HStack(spacing: Theme.Spacing.m) {
                Button {
                    model.togglePlayback()
                } label: {
                    // **Text, not a symbol.** "Play"/"Pause" as words is unambiguous
                    // in every language, needs no accessibility override, and costs
                    // nothing on a screen with one control on it.
                    Text(model.isPlaying ? "Pause" : "Play")
                        .font(Theme.Typography.metadata)
                        .frame(minWidth: Theme.Size.tapTarget, minHeight: Theme.Size.tapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Color.textPrimary)

                Button {
                    model.toggleMute()
                } label: {
                    Text(model.isMuted ? "Unmute" : "Mute")
                        .font(Theme.Typography.metadata)
                        .frame(minWidth: Theme.Size.tapTarget, minHeight: Theme.Size.tapTarget)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Color.textSecondary)

                Spacer()
            }
        }
    }

    // MARK: - Lifecycle

    private func prepare() async {
        teardown()
        guard let assetIdentifier else {
            // The moment says it has a clip and carries no identifier — the state
            // where the row and the library disagree. Nothing to play, and nothing
            // to say about it.
            return
        }
        let created = BTSPlaybackModel(
            library: environment.photoLibrary,
            assetIdentifier: assetIdentifier
        )
        model = created
        await created.load()
    }

    private func teardown() {
        model?.stop()
        model = nil
        environment.photoLibrary.purgeBTSPlaybackFiles()
    }
}

/// A player's state, kept out of the view.
///
/// ## Why this is a model and not a dozen `@State` properties in the view
///
/// `AVPlayer` is a reference to a decode pipeline and a file handle. It must be
/// created once, kept, and released exactly once — and `@State` is for values,
/// where writing the same thing twice is harmless. A player written into `@State`
/// is a player whose teardown depends on SwiftUI's opinion.
///
/// It is also where the mute decision lives, because **mute has to survive a
/// redraw and it must not be a guess.** A clip that starts audible because the
/// view re-rendered before the player was ready is the failure mode.
@MainActor
@Observable
final class BTSPlaybackModel {

    private let library: PhotoLibraryService
    private let assetIdentifier: String

    /// `nil` until the clip file has been written, and `nil` again after `stop()`.
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var isMuted = true
    private(set) var failure: String?

    /// Observes playback so the button label can say Pause rather than Play while
    /// the clip is running.
    ///
    /// **A `timeObserver` and not `AVPlayerItem.status` polling**, because the thing
    /// the label needs is "is it playing", and the item's status never changes
    /// between playing and finished — it only ever goes ready, failed, or unknown.
    /// A periodic observer is also what reports the end of the clip, which is what
    /// puts `isPlaying` back to `false` on its own.
    private var timeObserver: Any?

    init(library: PhotoLibraryService, assetIdentifier: String) {
        self.library = library
        self.assetIdentifier = assetIdentifier
    }

    func load() async {
        do {
            let url = try await library.btsClipFile(for: assetIdentifier)
            let created = AVPlayer(url: url)
            // **`isMuted` applied to the player, not to the view.** A `VideoPlayer`
            // with a mute overlay looks muted until the overlay draws, which is
            // after the first frame of audio has already been played.
            created.isMuted = isMuted
            player = created

            // **`addPeriodicTimeObserver`, and the interval is a frame rather than a
            // fraction of the clip.** Five seconds of clip at 0.05s intervals is
            // 100 callbacks for a boolean that changes twice; at 0.25s it is 20 and
            // the label is still well inside human reaction time.
            //
            // **`queue: .main`, named explicitly.** The observer delivers on the
            // queue it is given, and the default is not stated anywhere I could
            // rely on — so this passes the main queue on purpose and hops to
            // `@MainActor` inside, rather than relying on a default and hoping. A
            // boolean read by a SwiftUI button that is written off the main thread
            // is a data race with the worst possible symptom: a label that does not
            // update.
            let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
            timeObserver = created.addPeriodicTimeObserver(
                forInterval: interval,
                queue: .main
            ) { [weak self] time in
                let duration = created.currentItem?.duration.seconds ?? 0
                let finished = duration.isFinite && duration > 0
                    && time.seconds >= duration - 0.05
                Task { @MainActor [weak self] in
                    self?.isPlaying = !finished && created.rate != 0
                }
            }
        } catch {
            failure = error is LibraryError
                ? "This clip is no longer in your library."
                : "This clip could not be played."
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // **From the beginning, deliberately.** The clip is a few seconds of a
            // moment already in the past; resuming from three-quarters through
            // shows the user the last second of it and calls that playback.
            player.seek(to: .zero)
            player.play()
            isPlaying = true
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    /// Releases the player and its observer.
    ///
    /// **The observer has to go first.** `addPeriodicTimeObserver` retains its
    /// closure, the closure captures the player, and removing the observer is the
    /// only thing that breaks the cycle — a model that dropped only its own
    /// reference would leak a decode pipeline per playback for the life of the
    /// process.
    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
    }
}
