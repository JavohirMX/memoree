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
    @Environment(\.isReduceMotionEnabled) private var isReduceMotionEnabled

    /// The asset to play, or `nil` when the user deleted it in Photos.
    let assetIdentifier: String?

    @State private var model: BTSPlaybackModel?

    var body: some View {
        playerCard
            .task(id: assetIdentifier) { await prepare() }
            // **Stop on disappear, not on a timer.** The player holds a file handle and
            // a decode pipeline; leaving it running under a dismissed sheet is audio
            // from a screen nobody is looking at.
            .onDisappear { teardown() }
    }

    // MARK: - Player Card

    @ViewBuilder
    private var playerCard: some View {
        if let model, let player = model.player {
            ZStack(alignment: .bottom) {
                VideoPlayer(player: player)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Behind the Scenes clip")

                // Tap anywhere on video to toggle play / pause
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        model.togglePlayback()
                    }

                // Centered play overlay when paused
                if !model.isPlaying {
                    Circle()
                        .fill(Theme.Color.canvas.opacity(0.6))
                        .frame(width: Theme.Size.btsPlayOverlaySize, height: Theme.Size.btsPlayOverlaySize)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(Theme.Typography.screenTitle)
                                .foregroundStyle(Theme.Color.textPrimary)
                                .offset(x: 1)
                        }
                        .transition(.scale.combined(with: .opacity))
                }

                // Controls: explicit play/pause (a11y) + mute; progress display-only.
                VStack(spacing: Theme.Spacing.s) {
                    HStack(spacing: Theme.Spacing.s) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            model.togglePlayback()
                        } label: {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .font(Theme.Typography.metadata.weight(.semibold))
                                .foregroundStyle(Theme.Color.textPrimary)
                                .padding(Theme.Spacing.s)
                                .background(Theme.Color.canvas.opacity(0.6))
                                .clipShape(Circle())
                                .overlay {
                                    Circle().strokeBorder(Theme.Color.divider, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.pressDip)
                        .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                        Spacer()

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            model.toggleMute()
                        } label: {
                            Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(Theme.Typography.metadata.weight(.semibold))
                                .foregroundStyle(Theme.Color.textPrimary)
                                .padding(Theme.Spacing.s)
                                .background(Theme.Color.canvas.opacity(0.6))
                                .clipShape(Circle())
                                .overlay {
                                    Circle().strokeBorder(Theme.Color.divider, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.pressDip)
                        .accessibilityLabel(model.isMuted ? "Unmute video" : "Mute video")
                    }
                    .padding(.horizontal, Theme.Spacing.m)

                    // Minimal horizontal progress bar
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Theme.Color.divider)
                                .frame(height: Theme.Size.btsProgressBarHeight)

                            Capsule()
                                .fill(Theme.Color.textPrimary)
                                .frame(width: max(0, proxy.size.width * CGFloat(model.progress)), height: Theme.Size.btsProgressBarHeight)
                        }
                    }
                    .frame(height: Theme.Size.btsProgressBarHeight)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.bottom, Theme.Spacing.m)
                }
            }
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .background(Theme.Color.canvas)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Color.divider, lineWidth: 1)
            }
            .appAnimation(model.isPlaying) { .easeInOut(duration: 0.2) }
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
            assetIdentifier: assetIdentifier,
            motion: BTSPlaybackMotionPolicy(prefersReducedMotion: isReduceMotionEnabled)
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

/// Whether BTS playback may move on its own.
///
/// Reduce Motion asks for less movement. An autoplaying, looping clip is continuous
/// motion — exactly what the setting declines. Manual play stays available either
/// way; mute stays on by default either way (ADR-039).
struct BTSPlaybackMotionPolicy: Equatable, Sendable {
    let prefersReducedMotion: Bool

    var autoplaysOnLoad: Bool { !prefersReducedMotion }
    var loopsOnEnd: Bool { !prefersReducedMotion }
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
    private let motion: BTSPlaybackMotionPolicy

    /// `nil` until the clip file has been written, and `nil` again after `stop()`.
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    private(set) var isMuted = true
    private(set) var progress: Double = 0.0
    private(set) var failure: String?

    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?

    init(
        library: PhotoLibraryService,
        assetIdentifier: String,
        motion: BTSPlaybackMotionPolicy = BTSPlaybackMotionPolicy(prefersReducedMotion: false)
    ) {
        self.library = library
        self.assetIdentifier = assetIdentifier
        self.motion = motion
    }

    func load() async {
        do {
            let url = try await library.btsClipFile(for: assetIdentifier)
            let created = AVPlayer(url: url)
            created.isMuted = isMuted
            player = created

            let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
            timeObserver = created.addPeriodicTimeObserver(
                forInterval: interval,
                queue: .main
            ) { [weak self] time in
                let duration = created.currentItem?.duration.seconds ?? 0
                let current = time.seconds
                let calcProgress = (duration > 0 && duration.isFinite)
                    ? min(max(current / duration, 0.0), 1.0)
                    : 0.0
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.progress = calcProgress
                    self.isPlaying = created.rate != 0
                }
            }

            if let item = created.currentItem {
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, let player = self.player else { return }
                        player.seek(to: .zero)
                        self.progress = 0.0
                        // **Loop only when Reduce Motion is off.** Under the setting,
                        // the clip stops at the start and waits for a tap (ADR-039).
                        if self.motion.loopsOnEnd {
                            player.play()
                            self.isPlaying = true
                        } else {
                            player.pause()
                            self.isPlaying = false
                        }
                    }
                }
            }

            if motion.autoplaysOnLoad {
                created.play()
                isPlaying = true
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
            if let duration = player.currentItem?.duration.seconds,
               duration > 0, player.currentTime().seconds >= duration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player?.isMuted = isMuted
    }

    func stop() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        progress = 0.0
    }
}
