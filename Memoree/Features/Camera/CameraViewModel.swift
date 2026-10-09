import Foundation
import QuartzCore
import SwiftUI

/// Drives the camera screen.
///
/// The `@MainActor` observable adapter between the capture service and the
/// view. The service publishes no SwiftUI state and knows no UI exists; this
/// type observes it and exposes something a view can render (AGENTS.md §3, §5).
///
/// Deliberately does **not** import AVFoundation. `CameraPosition` and
/// `CapturedPhoto` are Memoree's own types, and the preview arrives as a
/// `CALayer` (ADR-018).
///
/// ## The sequence is the user's
///
/// One shutter press, one photograph. The **second** press is what switches the
/// camera, and it is a user-visible event with a live preview on the other side
/// of it (ADR-021). An earlier version did the whole thing in one call, taking
/// both photographs without asking — which also made "reshoot just this one"
/// inexpressible.
@MainActor
@Observable
final class CameraViewModel {

    /// What the camera screen is doing.
    enum Phase: Equatable {
        /// Session not started, or permission not yet resolved.
        case idle
        /// Session starting.
        case starting
        /// Live preview, shutter armed. At least one half is outstanding.
        case shooting
        /// A capture or a camera switch is in flight. The shutter is disabled.
        case working
        /// Both photographs exist. Tapping the small one swaps which is large.
        case review
        /// The pair was written to Photos. Terminal for this presentation.
        case saved
        /// A recoverable failure. Carries the message and whether to retry.
        case failed(message: String, isRetryable: Bool)
        /// Permission was denied. A terminal state, but not an error — the
        /// archive and settings remain fully usable.
        case permissionDenied
    }

    // MARK: - Observable state

    private(set) var phase: Phase = .idle

    /// The photographs taken so far, keyed by camera.
    private(set) var captured: [CameraPosition: CapturedPhoto] = [:]

    /// Which camera is live right now.
    private(set) var livePosition: CameraPosition = .back

    /// Which camera opened this moment. Random, and held for the session.
    private(set) var firstPosition: CameraPosition = .back

    /// Which photograph is drawn large in the review composite.
    ///
    /// Starts as the *second* one taken, which is the photograph the user was
    /// looking at when they finished. Tapping the small one swaps them.
    private(set) var prominentPosition: CameraPosition?

    /// How many shutter presses have been made, across the whole moment.
    ///
    /// BeReal shows friends this number. With no feed it is a private statistic
    /// rather than a social signal — a high count means a busy or awkward
    /// moment, which is arguably more interesting (ADR-011).
    private(set) var retakeCount = 0

    /// The live preview surface, installed by `CameraPreview` (ADR-018).
    private(set) var previewLayer: CALayer?

    // MARK: - Dependencies

    private let service: CapturePhotoService

    /// Behind the Scenes, when the feature is on.
    ///
    /// **`nil` when BTS is off, and that is not a degraded mode** — it is the
    /// default, and `AppSettings` has defaulted `btsEnabled` to false since Phase 2
    /// specifically so no control in the app could describe a feature that did not
    /// exist.
    private let btsRecorder: BTSRecorder?
    private let haptics: HapticFeedback

    /// Whether the user wants each moment filed into the `Memoree` album.
    ///
    /// A closure and not a `Bool`, so the setting is read at *commit* time rather
    /// than at construction — a moment captured with the toggle off and committed
    /// after it was turned on should be filed, and the reverse should not. Held
    /// as `nil` when the screen was built without one, which is what the camera
    /// tests do and what makes "no album preference" expressible at all.
    /// **Not `@Sendable`.** This class is `@MainActor` and these closures are
    /// only ever invoked from it, so there is nothing to send them to — and
    /// writing `@Sendable` on them was actively wrong in the other direction:
    /// a `@Sendable` closure is non-isolated, so `CameraHostView` could not
    /// build one that touched the `@MainActor` `AppEnvironment`, and the only
    /// way past the warning was a `MainActor.run` hop for a value that was
    /// already on the main actor. It cost a warning on every build and made the
    /// code read as though it were crossing an isolation boundary when it never
    /// crossed one.
    private let shouldFileIntoAlbum: (() async -> Bool)?

    /// Where an album failure goes.
    ///
    /// Not `@Sendable` for the same reason as above.
    private let reportAlbumFailure: ((String) -> Void)?

    /// Set when the photographs were saved but the album add did not happen.
    ///
    /// Surfaced by the review screen and on the Today footer rather than swallowed.
    /// The photographs are safe either way; the user asked for something that did
    /// not occur and deserves to be told.
    private(set) var albumFailure: String?
    private let photoLibrary: PhotoLibraryService

    /// Persists an accepted pair as a moment.
    ///
    /// `nil` means the camera screen stops at the library write — which is what
    /// SwiftUI previews and any test not exercising the full loop want. It is a
    /// legal state rather than a failure: a moment in Photos with no archive
    /// row is exactly what a half-finished commit looks like, and the recovery
    /// path below already knows how to describe one.
    private let record: MomentRecorder?

    /// Injected in tests so the camera order can be made deterministic.
    /// Production randomises it per moment.
    private let chooseFirstCamera: () -> CameraPosition

    /// The clock.
    ///
    /// Injected because a moment's time is a load-bearing fact — it decides
    /// lateness, and therefore whether the streak grows (ADR-009) — and a test
    /// that reaches for `Date()` is asserting on when it happened to run.
    private let now: @Sendable () -> Date

    // MARK: - Commit state

    /// The identifiers the pair was written under, once it has been.
    ///
    /// Memoised, and the reason `retry()` does not write to Photos twice. A
    /// moment is two steps — write the assets, then record the row — and only
    /// the second can fail after the first has succeeded. Forgetting that would
    /// leave a duplicate pair in the user's camera roll every time the archive
    /// write hiccupped.
    private var writtenAssets: SavedAssetPair?

    /// Whether the current failure came from a commit rather than a capture.
    ///
    /// Without this, `retry()` cannot tell the two apart: a failed *write* and
    /// a failed *capture* both leave `writtenAssets` nil and the pair intact,
    /// and answering "re-arm the shutter" for a failed commit sends the user
    /// back to the camera with photographs already on disk. One boolean, and
    /// the retry rule stops needing case analysis.
    private(set) var isCommitting = false

    /// When the most recent photograph was taken.
    ///
    /// The moment is complete when the last outstanding half is shot, so this
    /// is the capture that closed it — and after a reshoot, the reshoot, which
    /// is when the pair was most recently whole. See `CommittedCapture.capturedAt`.
    private var lastCaptureAt: Date?

    // MARK: - Init

    init(
        service: CapturePhotoService,
        photoLibrary: PhotoLibraryService,
        haptics: HapticFeedback = InMemoryHapticFeedback(),
        /// `nil` disables BTS entirely — no recording is opened, no microphone is
        /// requested, and no temporary file is written. **Not a defaulted-to-present
        /// dependency**, because a default would mean every existing call site
        /// silently started writing video.
        btsRecorder: BTSRecorder? = nil,
        /// How long a clip to keep, **read at commit** rather than captured here.
        ///
        /// A closure for the same reason `shouldSaveBTS` is one: the length is a
        /// setting the user can change while composing, and it used to be read once
        /// at construction — so a moment captured after a change in Settings still
        /// got the old length, while the album and save toggles immediately beside
        /// it honoured the new value. Two settings that changed together and took
        /// effect at different times is worse than either being wrong alone.
        ///
        /// **Clamped on every read**, because this returns a persisted `Double` and
        /// a corrupt store should degrade rather than crash — the same reasoning as
        /// `TimeWindow.validated`.
        clipDuration: @escaping () -> TimeInterval = { BTSTrim.defaultClipDuration },
        record: MomentRecorder? = nil,
        shouldFileIntoAlbum: (() async -> Bool)? = nil,
        shouldSaveBTS: (() -> Bool)? = nil,
        reportBTSFailure: ((String) -> Void)? = nil,
        /// Where to report a failed album add. Separate from
        /// `shouldFileIntoAlbum` so a test can assert the album behaviour without
        /// also needing somewhere to put the failure.
        reportAlbumFailure: ((String) -> Void)? = nil,
        chooseFirstCamera: (() -> CameraPosition)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.photoLibrary = photoLibrary
        self.haptics = haptics
        self.btsRecorder = btsRecorder
        self.clipDuration = clipDuration
        self.record = record
        self.shouldFileIntoAlbum = shouldFileIntoAlbum
        self.shouldSaveBTS = shouldSaveBTS
        self.reportAlbumFailure = reportAlbumFailure
        self.reportBTSFailure = reportBTSFailure
        self.previewLayer = service.previewLayer
        self.chooseFirstCamera = chooseFirstCamera ?? {
            CameraPosition.allCases.randomElement() ?? .back
        }
        self.now = now
    }

    // MARK: - Lifecycle

    /// Starts the session on a randomly chosen camera.
    ///
    /// **Awaits until the camera is actually live.** An earlier version spawned
    /// a `Task` and returned immediately, which meant `phase` was still `.idle`
    /// when the caller came back — so anything that pressed the shutter straight
    /// after starting was pressing a button on a camera that was not open yet.
    /// Detached setup work is only correct when nothing needs to know when it
    /// finished, and here something always does.
    func start() async {
        guard phase == .idle else { return }
        // Spins the Taptic Engine up front. A generator created at the moment of
        // the tap has to warm itself, and the delay is perceptible between the
        // finger leaving the glass and the sensation arriving — which reads as
        // the phone being slow rather than as feedback.
        (haptics as? SystemHapticFeedback)?.prepare()
        let opening = chooseFirstCamera()
        firstPosition = opening
        livePosition = opening
        // Nothing about orientation happens here, and that is the point.
        //
        // Rotation used to be reported *into* the camera from this layer. It no
        // longer is: `AVCaptureDevice`'s rotation coordinator watches the
        // device's physical orientation and corrects for it, which is the only
        // approach that survives the rotation lock — and asking the UI for a held
        // orientation is why every sideways photograph used to save as a portrait
        // one.
        await requestMovieOutputIfBTSEnabled()
        await runSession(openingOn: opening)

        // **The recording opens after the session is live, never before.** It
        // writes into the movie output, which does not exist until the session has
        // been configured.
        await startBTSIfEnabled()
    }

    // MARK: - Behind the Scenes

    /// Asks the session for a movie output, if BTS is on.
    ///
    /// ## This has to happen before `startSession`, and nothing on screen says so
    ///
    /// `CaptureSessionController` attaches a movie output only to sessions
    /// configured *after* `wantsMovieOutput` is set. A request that arrives later
    /// configures nothing, and re-attaching one to a live session means a second
    /// `beginConfiguration` cycle on the subsystem this project has measured as
    /// fragile.
    ///
    /// **The resulting failure is completely invisible**: the recorder finds no
    /// output, throws `outputUnavailable`, and that is swallowed per ADR-013 — so
    /// the app would show BTS as on and record nothing, forever, with nothing to
    /// report. `BTSFlowTests` asserts the ordering against `InMemoryCaptureService`
    /// because it is not observable anywhere else.
    ///
    /// **Separate from `startBTSIfEnabled` rather than at the top of it**, because
    /// this one has a precondition that one does not: it must be called before the
    /// session exists, and a method that also records is a method that cannot be
    /// called in the right order from anywhere sensible.
    private func requestMovieOutputIfBTSEnabled() async {
        guard btsRecorder != nil else { return }
        await service.enableMovieOutput()
    }

    /// Opens a recording, if BTS is on and the microphone permits it.
    ///
    /// ## Every failure here is swallowed, and that is the design
    ///
    /// `ADR-013`: a denied microphone yields a silent clip, and a BTS failure must
    /// never cost the user the two photographs that are the actual product. So this
    /// method cannot throw, cannot set a failure phase, and cannot surface a
    /// message — a user who declined the microphone should get photographs and no
    /// interruption, not photographs and a dialog about a clip they cannot have.
    ///
    /// **The one thing that is reported is nothing at all**: `isRecording` stays
    /// false and the commit finds no clip, which is indistinguishable from a
    /// recording too short to keep. Both are ordinary outcomes.
    private func startBTSIfEnabled() async {
        guard let btsRecorder else { return }

        // **Ask only when the feature is on and the answer is not already known.**
        // A microphone prompt at camera-open for a user who is about to decline it
        // is the wrong trade, and `AVCaptureDevice` already knows the answer after
        // the first time.
        if btsRecorder.microphoneStatus() == .notDetermined {
            _ = await btsRecorder.requestMicrophoneAuthorization()
        }

        do {
            try await btsRecorder.startRecording()
        } catch {
            // Nothing. See the method's documentation.
        }
    }

    /// Closes the recording and trims it to what the user asked for.
    ///
    /// **Returns `nil` for every ordinary absence** — BTS off, never started, too
    /// short to keep — and the caller treats `nil` as "the moment has no clip",
    /// which is exactly right.
    private func finishBTS(clipDuration: TimeInterval) async -> CommittedBTS? {
        guard let btsRecorder, btsRecorder.isRecording else { return nil }

        do {
            let recording = try await btsRecorder.stopRecording()

            // **`trim` returning `nil` is not a failure** — `BTSTrim` returns it for
            // a recording shorter than its floor, which is a user who fired two
            // shutter presses in half a second. The recording is discarded either
            // way, because the untrimmed bytes have no further use.
            //
            // **`defer`, so the untrimmed source is released on every branch.** It
            // used to be released on each branch individually, which is exactly the
            // shape that grows a fourth branch later and leaks.
            defer { btsRecorder.discard(recording) }

            guard let bytes = try await btsRecorder.trim(recording, toSeconds: clipDuration) else {
                return nil
            }
            return CommittedBTS(data: bytes, hasAudio: recording.hasAudio)

        } catch {
            reportBTSFailure?("Behind the Scenes failed: \(error.localizedDescription)")
            btsRecorder.abandon()
            return nil
        }
    }

    /// Abandons any open recording and removes its bytes.
    ///
    /// **Called on every path that throws the pair away** — a re-take, a start
    /// over, a cancelled capture. A recording left running would keep writing until
    /// the session stopped, and `LiveBTSRecorder` holds its file in the temporary
    /// directory for the system to purge eventually, which is not the same as not
    /// writing it.
    ///
    /// **One call, and no `try?`/`if let` around a `stopRecording`.** That shape was
    /// here first and it is what wedged the recorder: when the stop threw, the
    /// recording's path was never handed back, so the bytes could not be released
    /// *and* `isRecording` stayed true. `BTSRecorder.abandon` exists to make the
    /// branch unnecessary — see its documentation.
    private func abandonBTS() {
        guard let btsRecorder, btsRecorder.isRecording else { return }
        btsRecorder.abandon()
    }

    /// Pauses recording the current camera segment prior to camera switch.
    private func pauseBTSForSwitch() async {
        guard let btsRecorder, btsRecorder.isRecording else { return }
        await btsRecorder.pauseRecording()
    }

    /// Resumes recording the second camera segment after camera switch.
    private func resumeBTSAfterSwitch() async {
        guard let btsRecorder, btsRecorder.isRecording else { return }
        do {
            try await btsRecorder.resumeRecording()
        } catch {
            // Swallowed per ADR-013: BTS failure never costs the moment.
        }
    }

    /// Pauses recording when entering review so user review time is not recorded.
    private func pauseBTSForReview() async {
        guard let btsRecorder, btsRecorder.isRecording else { return }
        await btsRecorder.pauseRecording()
    }

    // MARK: - Focus

    /// Moves focus and exposure to a point the user tapped on the preview.
    ///
    /// **The view's coordinates are converted by the service**, not here: turning a
    /// view point into a sensor point needs the preview layer's own mapping, and
    /// `Features/` cannot import AVFoundation to do it (`AGENTS.md` §3).
    ///
    /// Clamped rather than trusted: a tap landing outside the preview — which a
    /// drag can produce — would otherwise ask the sensor to focus somewhere it
    /// cannot see, and AVFoundation throws for that.
    func focus(at point: CGPoint) async {
        let size = previewSize
        guard size.width > 0, size.height > 0 else { return }
        await service.focus(atNormalizedPoint: CGPoint(
            x: min(max(point.x / size.width, 0), 1),
            y: min(max(point.y / size.height, 0), 1)
        ))
    }

    /// The preview's size, so the view's points can be normalised.
    ///
    /// **Set by the view**, the only thing that knows it. Zero until the first
    /// layout, and `focus(at:)` returns without doing anything then — a tap cannot
    /// arrive before the preview has been laid out.
    @MainActor var previewSize: CGSize = .zero

    // MARK: - Zoom

    /// The zoom in force, mirrored into the view model so the buttons can show it.
    ///
    /// **Starts at 1x** because that is what the device reports before anyone
    /// chooses, and because it is the framing the app was designed at (ADR-019).
    private(set) var zoom: CameraZoom = .wide

    /// Applies a zoom the user chose.
    ///
    /// **A refusal leaves the choice alone rather than falling back to 1x.** If the
    /// front camera refuses 0.5x, silently switching to 1x would leave the button
    /// showing 0.5x selected while the camera is at 1x, which is a control lying
    /// about the state of the world.
    ///
    /// - Returns: whether the choice was accepted.
    @discardableResult
    func chooseZoom(_ zoom: CameraZoom) async -> Bool {
        do {
            try await service.applyZoom(zoom)
            self.zoom = zoom
            return true
        } catch {
            return false
        }
    }

    func stop() async {
        // **Abandon before the session stops, not after.** Stopping the session
        // also stops the movie output, so a recording left open at this point
        // writes nothing more — but its file stays in the temporary directory and,
        // worse, `isRecording` stays `true`, so the next `startBTSIfEnabled`
        // throws `alreadyRecording` and the next moment silently loses its clip.
        // That is a bug about the *next* moment caused by the user leaving *this*
        // one, which is the hardest kind to notice.
        abandonBTS()
        await service.stopSession()
        phase = .idle
    }

    private func runSession(openingOn position: CameraPosition) async {
        phase = .starting

        // Request if undetermined, then re-read. Requesting unconditionally
        // would re-prompt a user who already answered, which the system handles
        // by silently returning the old decision — correct, but it skips the
        // branch that distinguishes "not yet asked" from "said no".
        if service.authorizationStatus() == .notDetermined {
            _ = await service.requestAuthorization()
        }

        let status = service.authorizationStatus()
        guard status == .authorized else {
            phase = (status == .restricted) ? .failed(
                message: CaptureError.restricted.errorDescription ?? "",
                isRetryable: false
            ) : .permissionDenied
            return
        }

        do {
            try await service.startSession(on: position)
            previewLayer = service.previewLayer
            phase = .shooting
        } catch {
            phase = Self.phase(for: error)
        }
    }

    // MARK: - The shutter

    /// One press. Captures this camera, or — if it is already captured — moves
    /// to the other one.
    ///
    /// The second press doing the switch is the whole point (ADR-021). The user
    /// sees the other camera come up, composes, and presses again.
    func shutterPressed() async {
        guard phase == .shooting else { return }
        phase = .working

        do {
            if captured[livePosition] == nil {
                // First press on this camera: photograph it.
                let photo = try await service.captureCurrentPhoto()
                captured[livePosition] = photo
                lastCaptureAt = now()
                haptics.shutter()

                if captured.count == CameraPosition.allCases.count {
                    await pauseBTSForReview()
                    enterReview()
                } else {
                    // Second press: bring up the camera they have not shot.
                    let next = CameraPosition.allCases.first { $0 != livePosition } ?? .front
                    phase = .working
                    await pauseBTSForSwitch()
                    try await service.switchCamera(to: next)
                    livePosition = next
                    phase = .shooting
                    await resumeBTSAfterSwitch()
                    // **No haptic for the switch.** One press photographs *and*
                    // swaps, so buzzing here would tell the user two things
                    // happened when they pressed once. A haptic describes what
                    // the user did; the swap is a consequence the user did not
                    // choose separately. There is a `HapticFeedback.cameraSwitched`
                    // and it has no call site, and that is the correct state —
                    // if the mechanic ever becomes a *separate* switch the user
                    // performs, it gets its own buzz then.
                }
            } else {
                // Pressing again on a camera already shot is not a capture; it
                // is a no-op rather than a silent over-write. Reshooting is an
                // explicit action from the review screen.
                phase = .shooting
            }
        } catch {
            phase = Self.phase(for: error)
        }
    }

    /// Whether the user can manually flip which camera to shoot first.
    var canFlipCamera: Bool {
        phase == .shooting && captured.isEmpty
    }

    /// Manually toggles between the front and back cameras before capturing.
    func flipCamera() async {
        guard canFlipCamera else { return }
        let target = livePosition.opposite
        phase = .working
        abandonBTS()
        do {
            try await service.switchCamera(to: target)
            livePosition = target
            firstPosition = target
            phase = .shooting
            await startBTSIfEnabled()
            haptics.cameraSwitched()
        } catch {
            phase = Self.phase(for: error)
        }
    }

    // MARK: - Low-light & Torch

    /// Current torch mode chosen by the user.
    private(set) var torchMode: TorchMode = .off

    /// Whether the torch can be toggled in the current phase.
    var canToggleTorch: Bool {
        phase == .shooting || phase == .idle || phase == .starting
    }

    /// Toggles the torch on or off.
    func toggleTorch() async {
        guard canToggleTorch else { return }
        let next: TorchMode = (torchMode == .off) ? .on : .off
        torchMode = next
        do {
            try await service.setTorchMode(next)
        } catch {
            torchMode = .off
        }
    }

    // MARK: - Micro-Journal Note

    /// User's micro-journal note entered on the review screen (max 80 chars).
    var draftNote: String = ""

    // MARK: - Review

    /// Promotes the small photograph to the large one, and vice versa.
    func swapProminent() {
        guard phase == .review, captured.count == 2 else { return }
        let other = CameraPosition.allCases.first { $0 != (prominentPosition ?? livePosition) }
        guard let other, captured[other] != nil else { return }
        prominentPosition = other
    }

    /// Reopens one camera so a single half can be reshot.
    ///
    /// The other photograph is kept — that is the entire point of being able to
    /// do this. Only the chosen half is discarded.
    ///
    /// Any write already made is forgotten, because the pair it covered no
    /// longer exists. Nothing is deleted from Photos to compensate (ADR-008);
    /// those assets simply become orphans the user owns, which the re-capture
    /// notice on the Today screen states up front.
    func reshoot(_ position: CameraPosition) async {
        guard let kept = captured[position.opposite] else { return }
        phase = .working
        retakeCount += 1
        // **Awaited, not detached** — see `abandonCapture`.
        await abandonCapture()

        do {
            try await service.switchCamera(to: position)
            livePosition = position
            captured = [position.opposite: kept]
            prominentPosition = nil
            // **The recording is re-established, not just closed.** See
            // `resumeShootingAfterDiscard` — this is where a moment silently lost
            // its clip the first time.
            await resumeShootingAfterDiscard()
        } catch {
            phase = Self.phase(for: error)
        }
    }

    /// Discards both photographs and starts the moment again.
    func startOver() async {
        phase = .working
        captured = [:]
        prominentPosition = nil
        draftNote = ""
        // **Awaited, not detached** — see `abandonCapture`.
        await abandonCapture()
        let opening = chooseFirstCamera()
        firstPosition = opening
        livePosition = opening

        do {
            try await service.switchCamera(to: opening)
            // **The recording is re-established, not just closed.** See
            // `resumeShootingAfterDiscard`.
            await resumeShootingAfterDiscard()
        } catch {
            phase = Self.phase(for: error)
        }
    }

    /// Writes the reviewed pair to Photos and records it as a moment.
    ///
    /// **Two steps, in this order, and the order is the decision.**
    ///
    /// Photos first, then the archive row. The alternative — record, then write
    /// — looks tidier because it means the moment exists before the riskier
    /// operation, but it has a much worse failure. A crash between the two
    /// leaves an archive entry whose images do not exist, which renders as
    /// "missing from Photos" and tells the user a moment was saved when nothing
    /// was. This order's failure leaves two photographs in a library the user
    /// owns, made by an add-only permission that could never delete them anyway
    /// (ADR-008). One is inert; the other lies.
    ///
    /// Only the second step can fail after the first succeeds, which is what
    /// `writtenAssets` remembers and what `retry()` acts on.
    func commit() async {
        guard let pair = capturedPair, phase == .review else { return }
        isCommitting = true
        phase = .working
        await performCommit(pair)
    }

    /// The commit itself, shared with `retry()` so the two cannot drift.
    ///
    /// Re-entrant by design: `writtenAssets` is only non-`nil` once the library
    /// write has succeeded, so re-running after a *record* failure skips
    /// straight past it rather than writing a second pair.
    private func performCommit(_ pair: CapturedPair) async {
        // **The clip is finished first, and nothing else can fail because of it.**
        //
        // `ADR-022` is "Photos first, record second, and never repeat a step that
        // succeeded", and this is on the right side of that line: trimming is pure
        // work on a temporary file, it needs nothing from the library, and it
        // cannot be lost by a retry because it is recomputed from a recording that
        // `finishBTS` has not yet discarded. Doing it before the Photos write means
        // the ordering is preserved and the clip costs the moment nothing.
        let clip = await finishBTS(clipDuration: BTSTrim.validatedClipDuration(clipDuration()))
        committedBTS = clip

        do {
            if writtenAssets == nil {
                // No location passed. The write path and EXIF injector support
                // it, but there is no `CLLocationManager` in the app; that
                // decision is deferred to Phase 10 rather than faked here
                // (ADR-016, Q1).
                writtenAssets = try await photoLibrary.saveMomentPair(
                    backData: pair.back.data,
                    frontData: pair.front.data,
                    location: nil
                )
            }
            await writeBTSIfAsked()
            try await recordMoment(pair)
            isCommitting = false
            phase = .saved
            // The only *notification* haptic in the app, and the only one that
            // means "done". Everything else here is a tap; this is the moment the
            // photograph is safe.
            haptics.committed()
        } catch {
            // Deliberately nothing. A failure buzz would be the phone telling
            // the user they did something wrong, and Memoree's own copy is what
            // should be saying that — and sometimes the failure is a permission
            // they declined an hour ago.
            phase = Self.phase(for: error)
            return
        }

        // **After** the moment is recorded, and outside the `do`.
        //
        // Ordering is the whole design. The commit above is what the user asked
        // for and it must not be able to fail because an *organisation* of the
        // photographs failed; an album is a convenience. Putting this last also
        // means a failed commit does not add assets to an album for a moment that
        // was never written, which would leave a duplicate pair in the user's
        // library that the archive does not know about (ADR-004).
        await fileIntoAlbumIfAsked()
    }

    /// Files the pair into the `Memoree` album, if the user asked for that.
    ///
    /// **Off by default and reads the setting through a closure rather than the
    /// store**, because `CameraViewModel` has no persistence and must not have one
    /// (`AGENTS.md` §3: Features holds views and view models). The Settings
    /// toggle is therefore a live dependency, not a snapshot — the album can be
    /// turned on or off between moments without restarting anything.
    ///
    /// ## Why this cannot fail the commit
    ///
    /// The photographs are **already saved** by the time this runs, and they are
    /// the thing the user asked for. An album is an organisation of them. So a
    /// failure here is recorded and reported and the moment still commits —
    /// otherwise a full disk or a deleted album would cost the user the actual
    /// photographs to save a convenience.
    ///
    /// The counter-argument — "the user turned on a toggle and it silently did
    /// nothing" — is answered by `albumFailure` surfacing on the Today footer and
    /// in Settings, not by risking the write.
    private func fileIntoAlbumIfAsked() async {
        guard albumFailure == nil, await shouldFileIntoAlbum?() == true, let assets = writtenAssets
        else { return }

        do {
            var assetsToFile = [assets.back, assets.front]
            if let writtenBTS {
                assetsToFile.append(writtenBTS)
            }
            try await photoLibrary.addAssets(
                assetsToFile,
                toAlbumNamed: Self.albumName
            )
        } catch {
            let message = "The photographs were saved, but they could not be added "
                + "to the \(Self.albumName) album."
            albumFailure = message
            reportAlbumFailure?(message)
        }
    }

    /// The album's name.
    ///
    /// A constant rather than something the user can rename: Memoree does not
    /// have accounts, settings sync, or a place to put a name, and a renameable
    /// album whose name lived only on the device would be one more thing to lose.
    static let albumName = "Memoree"

    private func recordMoment(_ pair: CapturedPair) async throws {
        guard let record, let assets = writtenAssets else { return }
        // **The clip only travels if it was actually written to the library.**
        // `committedBTS` alone would hand the recorder a clip with no
        // `assetIdentifier`, and the archive would know a clip exists with no way
        // to find it — which is the "missing from Photos" state, reported for a
        // clip that was never written at all.
        //
        // **`saveBTS: false` therefore records no clip**, rather than recording one
        // whose bytes exist only in memory. That is the difference between "you
        // chose not to keep the clip" and "Memoree has a video you cannot find",
        // and the archive has no way to tell them apart.
        var committedClip: CommittedBTS?
        if let clip = committedBTS, let identifier = writtenBTS {
            committedClip = CommittedBTS(
                data: clip.data,
                hasAudio: clip.hasAudio,
                assetIdentifier: identifier
            )
        }

        let trimmedNote = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let noteToSave = trimmedNote.isEmpty ? nil : String(trimmedNote.prefix(80))

        try await record(
            CommittedCapture(
                back: pair.back,
                front: pair.front,
                assets: assets,
                capturedAt: lastCaptureAt ?? now(),
                retakeCount: retakeCount,
                bts: committedClip,
                note: noteToSave
            )
        )
    }

    /// Writes the clip to Photos, once, and remembers that it happened.
    ///
    /// ## Before `record`, so the moment can carry the identifier
    ///
    /// `Moment.record` takes `btsAssetIdentifier`, so the clip has to be written
    /// *before* the row is built or the archive would know a clip exists with no way
    /// to find it. That puts a second library write inside the commit, which is
    /// exactly what `ADR-022` warns about — so it carries the same guard the pair
    /// does: **`writtenBTS` is set the moment the write succeeds, and a retry skips
    /// straight past it.** A retry after a *record* failure therefore does not write
    /// a second clip, which is the same invariant `writtenAssets` exists for.
    ///
    /// ## A failure is reported and never fatal
    ///
    /// The pair is already on disk, so a clip that will not save is a failure to keep
    /// a bonus. It is reported in **grey on the Today footer and never in amber** —
    /// amber has exactly one reserved job, a declined permission the user can only
    /// fix in Settings (`ADR-025`), and a video that did not write is not that.
    private func writeBTSIfAsked() async {
        guard let clip = committedBTS, writtenBTS == nil, shouldSaveBTS?() == true else {
            return
        }
        do {
            writtenBTS = try await photoLibrary.saveBTS(clip.data)
        } catch {
            let message = "Your photographs were saved, but the Behind the Scenes "
                + "clip could not be written to your library."
            btsFailure = message
            reportBTSFailure?(message)
        }
    }

    /// Whether to write the clip to Photos, read at commit time rather than
    /// captured at start.
    ///
    /// **A closure rather than a `Bool`**, so the view model does not read settings
    /// it has no business knowing about — the same reasoning as
    /// `shouldFileIntoAlbum`. Reading at commit matters because a user could change
    /// the setting while composing, and the answer on screen when they pressed Save
    /// is the one that counts.
    private let shouldSaveBTS: (() -> Bool)?

    /// Where to report a failed clip write, so the Today screen can say so.
    private let reportBTSFailure: ((String) -> Void)?

    /// A BTS write that failed after the photographs were saved. Grey, never amber.
    var btsFailure: String?

    /// The clip as trimmed at commit, carried through to `recordMoment`.
    private var committedBTS: CommittedBTS?

    /// The clip's `PHAsset.localIdentifier` once written, and the guard that stops a
    /// retry writing a second one.
    private var writtenBTS: String?

    /// The clip length to trim to. See the initialiser's `clipDuration`.
    private let clipDuration: () -> TimeInterval

    /// Forgets any library write, because the pair it covered no longer exists.
    /// Forgets any library write, because the pair it covered no longer exists.
    private func invalidateCommit() {
        writtenAssets = nil
        writtenBTS = nil
        committedBTS = nil
        lastCaptureAt = nil
        isCommitting = false
    }

    /// Abandons the recording and forgets the pair, together.
    ///
    /// **One method rather than `invalidateCommit` calling `abandonBTS` in a
    /// detached `Task`, and that is the second time this has been the wrong shape.**
    /// A `Task` here was invisible to every caller: `reshoot` and `startOver`
    /// returned before it ran, so a test asserting the recording was abandoned saw
    /// `discardedURLs.count == 0` and — worse — a user who re-shot a half and
    /// immediately captured again could open a *second* recording while the first
    /// was still being closed.
    ///
    /// Making it `async` and awaiting it at both call sites removes the window
    /// entirely. The cost is one hop on a path that is already asynchronous and
    /// already shows a working phase, so nothing the user sees changes.
    private func abandonCapture() async {
        abandonBTS()
        invalidateCommit()
    }

    /// Puts the camera back to shooting and reopens the BTS recording.
    ///
    /// **One helper because the two callers must do exactly the same thing**, and
    /// the half that matters is the half that is easy to leave out: returning to
    /// `.shooting` without a recording behind it looks identical on screen to
    /// returning to it with one.
    ///
    /// `startBTSIfEnabled` re-requests the movie output, which is idempotent — the
    /// controller only sets a flag — so this is cheap on the path that has a live
    /// session and correct on the one that does not.
    private func resumeShootingAfterDiscard() async {
        phase = .shooting
        await startBTSIfEnabled()
    }

    // MARK: - Recovery

    /// Retries after a recoverable failure.
    ///
    /// **Never discards the photographs.** An earlier version cleared `captured`
    /// on every retry, which quietly destroyed both halves after a library write
    /// failed — the exact case its own test called "nothing was lost, the
    /// photographs are still in memory". The test passed anyway because it only
    /// asserted that the phase was not `.permissionDenied`, which is a
    /// statement about permissions and not about the pair.
    ///
    /// The rule is one line and needs no case analysis: **re-run whichever step
    /// failed.** A commit failure re-runs the commit, which is safe to repeat
    /// because the library write is memoised. Anything else re-arms the shutter
    /// on the camera that failed, keeping whatever was already shot.
    func retry() async {
        guard isFailed else { return }

        if case .failed(_, let retryable) = phase, !retryable {
            // Not retryable: a permission the user must change in Settings.
            // Re-running would produce the same answer, so say so plainly
            // rather than looping (AGENTS.md §6).
            phase = .permissionDenied
            return
        }

        phase = .working

        if isCommitting, let pair = capturedPair {
            await performCommit(pair)
            return
        }

        do {
            try await service.switchCamera(to: livePosition)
            phase = .shooting
        } catch {
            phase = Self.phase(for: error)
        }
    }

    /// Rebuilds the session after `mediaServicesWereReset`.
    ///
    /// Exposed for the debug menu: that failure raises no error and fires no
    /// callback, so the recovery path cannot be trusted until it has been
    /// invoked deliberately (TRD §5.5).
    func simulateMediaServicesReset() async {
        do {
            try await service.rebuildSession()
            previewLayer = service.previewLayer
            phase = captured.isEmpty ? .shooting : .review
        } catch {
            phase = Self.phase(for: error)
        }
    }

    // MARK: - Derived

    private func enterReview() {
        phase = .review
        // The photograph taken last is the one they were looking at, so it is
        // the large one until they say otherwise.
        prominentPosition = livePosition
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    var canCapture: Bool { phase == .shooting }

    /// Both halves, or `nil` when either is still outstanding.
    ///
    /// A moment is only a moment when both photographs exist, so this is the
    /// gate on every path that treats the pair as a finished thing rather than
    /// as work in progress.
    var capturedPair: CapturedPair? {
        guard let back = captured[.back], let front = captured[.front] else { return nil }
        return CapturedPair(back: back, front: front)
    }

    /// The camera the user is composing with, in words.
    var livePositionDescription: String {
        livePosition == .front ? "Front camera" : "Back camera"
    }

    /// The photograph already taken, shown in the small square while the other
    /// camera is live. `nil` before the first press.
    var insetPhoto: CapturedPhoto? {
        guard let other = CameraPosition.allCases.first(where: { $0 != livePosition })
        else { return nil }
        return captured[other]
    }

    /// The photograph drawn large in review.
    var prominentPhoto: CapturedPhoto? {
        guard let prominentPosition else { return nil }
        return captured[prominentPosition]
    }

    /// The photograph drawn in the small square during review.
    var insetReviewPhoto: CapturedPhoto? {
        guard let prominentPosition,
              let other = CameraPosition.allCases.first(where: { $0 != prominentPosition })
        else { return nil }
        return captured[other]
    }

    /// Progress copy, which names the step rather than apologising for it.
    var progressDescription: String {
        switch phase {
        case .starting: return "Opening the camera"
        case .working: return captured.isEmpty ? "Capturing…" : "Switching camera…"
        default: return ""
        }
    }

    /// Whether the shutter is shown at all.
    ///
    /// Absent rather than disabled when the camera cannot be used, for the same
    /// reason the shutter was absent on the Today screen until Phase 4: a
    /// control that looks live and does nothing is a dead end.
    var showsShutter: Bool {
        switch phase {
        case .shooting, .review: return true
        case .idle, .starting, .working, .saved, .failed, .permissionDenied:
            return false
        }
    }

    // MARK: - Errors

    private static func phase(for error: Error) -> Phase {
        if let captureError = error as? CaptureError {
            return .failed(
                message: captureError.errorDescription ?? "Something went wrong.",
                isRetryable: captureError.isRetryable
            )
        }
        if let libraryError = error as? LibraryError {
            return .failed(
                message: libraryError.errorDescription ?? "Something went wrong.",
                // A library write failure is worth retrying: the photographs
                // are still in memory and nothing was lost.
                isRetryable: true
            )
        }
        if let storeError = error as? StoreError {
            return .failed(
                message: storeError.errorDescription ?? "Something went wrong.",
                // Reached only once the photographs are already in Photos, so
                // the message says so and the retry cannot lose them.
                isRetryable: storeError.isRetryable
            )
        }
        return .failed(message: error.localizedDescription, isRetryable: true)
    }
}
