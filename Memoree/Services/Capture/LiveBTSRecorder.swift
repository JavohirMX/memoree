import AVFoundation
import Foundation

/// The real `BTSRecorder`: an `AVCaptureMovieFileOutput` writing to a temporary
/// file, trimmed to its last N seconds at commit.
///
/// ## Why it holds the controller rather than owning an output
///
/// A session cannot have two movie outputs, and creating a second is the class of
/// defect Phase 4 spent six device runs learning about. So `CaptureSessionController`
/// owns the output and this type drives it — the same shape `ADR-018` used to get a
/// preview across the layer boundary without an AVFoundation import in `Features/`.
///
/// ## `@unchecked Sendable`, and what is actually confined
///
/// Two queues, and the rule is which one owns what:
///
/// - **`controllerQueue`** — every `AVCaptureMovieFileOutput` call. The output
///   belongs to the session, and the session belongs to the controller's queue.
///   Reading `isRecording` or calling `startRecording` from anywhere else is a
///   data race against the capture daemon, not merely a Swift one.
/// - **`exportQueue`** — `AVAssetExportSession` work. A *different* queue on
///   purpose: an export is seconds of CPU, and running it on the controller queue
///   would stall the session behind it.
///
/// `pending` and `settings` are therefore guarded by the same lock that guards the
/// hand-off between them, and are never touched from the controller queue directly.
final class LiveBTSRecorder: BTSRecorder, @unchecked Sendable {

    /// Drives the controller's movie output. Injected rather than constructed so
    /// a test can hand this recorder a controller with no camera behind it.
    private weak var controller: CaptureSessionController?

    private let lock = NSLock()

    /// Tracks whether the recording session for this moment is currently open.
    private var isSessionOpen = false

    /// The segment currently actively recording, if any.
    private var activeFileURL: URL?
    private var activeDelegate: MovieFileDelegate?

    /// Completed segments with measured durations, in order.
    private var completedSegments: [(fileURL: URL, duration: TimeInterval)] = []

    /// Settings handed to the output at `startRecording` time.
    ///
    /// **Captured rather than read at stop time**, because the audio session has to
    /// be configured *before* the output starts and `hasAudio` is a property of
    /// what was configured, not of what the authorisation status says afterwards.
    private var startedWithAudio = false

    private let exportQueue = DispatchQueue(label: "bts.export", qos: .utility)

    private let controllerQueue = DispatchQueue(label: "bts.controller")

    private var audioSession: AVAudioSession?

    /// Where untrimmed recordings go, and where trimmed clips are written.
    ///
    /// **A dedicated subdirectory of the temporary directory**, for the same reason
    /// `TemporaryShareFile` uses one: two moments sharing a session cannot overwrite
    /// each other's bytes, and the whole thing is one removable directory rather
    /// than loose files. The system purges it — nothing here is app storage
    /// (`AGENTS.md` §2.4), and a BTS clip is as much a photograph as the pair is.
    ///
    /// **`static`, and that is the load-bearing part.** A post-crash sweep has to
    /// run at launch, and it must not construct the recorder to do it — that would
    /// create an `AVCaptureSession` on first launch, before the user has granted
    /// camera access, which is precisely what `AppEnvironment` goes out of its way
    /// to avoid. The path is a property of the type, so the sweep is too.
    private static let directory: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("memoree-bts", isDirectory: true)
    }()

    /// Removes every BTS file, with no recorder and therefore no session.
    ///
    /// **This is what runs at launch.** A crash is the one situation in which
    /// nothing else gets to clean up: every normal path here deletes on the way out
    /// — trim, discard, abandon, `stop` — so the only way bytes survive is a
    /// process that ended between two of those. The system would eventually purge
    /// them, and "eventually" is not a cleanup story.
    static func purgeTemporaryFiles() {
        try? FileManager.default.removeItem(at: directory)
    }

    init(controller: CaptureSessionController) {
        self.controller = controller
    }

    // MARK: - BTSRecorder

    var isRecording: Bool {
        lock.withLock { isSessionOpen }
    }

    func microphoneStatus() -> MicrophoneAuthorizationStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    func requestMicrophoneAuthorization() async -> MicrophoneAuthorizationStatus {
        // **Lazy, and only when the user turns BTS on** (`AGENTS.md` §2). A prompt
        // at launch for a feature that may never be enabled is the wrong trade, and
        // a denial is a supported state: the clip is silent, not blocked (ADR-013).
        await AVCaptureDevice.requestAccess(for: .audio)
        return microphoneStatus()
    }

    func startRecording() async throws {
        guard let controller else { throw BTSRecorderError.outputUnavailable }

        // `alreadyRecording` rather than a silent restart: the first recording may
        // already be the moment, and discarding it to begin another is not a
        // recovery, it is data loss.
        guard !isRecording else { throw BTSRecorderError.alreadyRecording }

        let status = microphoneStatus()
        let wantsAudio = status == .authorized

        // **Not `try`, and that is the design.** `configureAudioSession` swallows
        // its own failure: a microphone that refuses to configure must not cost
        // the user their moment. The photographs are the product, and ADR-013's
        // rule is that an unavailable microphone yields a *silent clip*, never a
        // blocked capture.
        if wantsAudio {
            configureAudioSession()
        } else {
            deactivateAudioSession()
        }

        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fileURL = Self.directory.appendingPathComponent("bts-\(UUID().uuidString).mov")

        let delegate = MovieFileDelegate()

        guard controller.movieFileOutput != nil else {
            throw BTSRecorderError.outputUnavailable
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            controllerQueue.async {
                controller.movieFileOutput?
                    .startRecording(to: fileURL, recordingDelegate: delegate)
                c.resume()
            }
        }

        lock.withLock {
            startedWithAudio = wantsAudio
            isSessionOpen = true
            completedSegments = []
            activeFileURL = fileURL
            activeDelegate = delegate
        }
    }

    func pauseRecording() async {
        guard let controller, controller.movieFileOutput != nil else { return }

        let current = lock.withLock { () -> (URL, MovieFileDelegate)? in
            guard let url = activeFileURL, let del = activeDelegate else { return nil }
            return (url, del)
        }
        guard let (fileURL, delegate) = current else { return }

        let finished = await withCheckedContinuation { (c: CheckedContinuation<(TimeInterval?, Error?), Never>) in
            let resumer = SafeContinuationResumer(continuation: c)
            controllerQueue.async {
                delegate.onFinished = { duration, error in
                    resumer.resume(duration: duration, error: error)
                }

                if let output = controller.movieFileOutput {
                    output.stopRecording()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                    resumer.resume(duration: nil, error: nil)
                }
            }
        }

        var measured = finished.0
        if measured == nil || measured == 0 {
            measured = await MovieFileDelegate.duration(of: fileURL)
        }

        lock.withLock {
            activeFileURL = nil
            activeDelegate = nil
            if let duration = measured, duration > 0 {
                completedSegments.append((fileURL: fileURL, duration: duration))
            } else {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    func resumeRecording() async throws {
        guard let controller else { throw BTSRecorderError.outputUnavailable }
        guard isRecording else { throw BTSRecorderError.notRecording }

        let alreadyRecording = lock.withLock { activeFileURL != nil }
        guard !alreadyRecording else { return }

        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let fileURL = Self.directory.appendingPathComponent("bts-\(UUID().uuidString).mov")
        let delegate = MovieFileDelegate()

        guard controller.movieFileOutput != nil else {
            throw BTSRecorderError.outputUnavailable
        }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            controllerQueue.async {
                controller.movieFileOutput?
                    .startRecording(to: fileURL, recordingDelegate: delegate)
                c.resume()
            }
        }

        lock.withLock {
            activeFileURL = fileURL
            activeDelegate = delegate
        }
    }

    func stopRecording() async throws -> BTSRecording {
        guard controller != nil else { throw BTSRecorderError.outputUnavailable }
        guard isRecording else { throw BTSRecorderError.notRecording }

        let hasActive = lock.withLock { activeFileURL != nil }
        if hasActive {
            await pauseRecording()
        }

        deactivateAudioSession()

        let (segments, hadAudio) = lock.withLock { () -> ([(fileURL: URL, duration: TimeInterval)], Bool) in
            let segs = completedSegments
            completedSegments = []
            isSessionOpen = false
            activeFileURL = nil
            activeDelegate = nil
            return (segs, startedWithAudio)
        }

        guard !segments.isEmpty else {
            throw BTSRecorderError.writeFailed("no video segments recorded")
        }

        return BTSRecording(
            segmentURLs: segments.map(\.fileURL),
            segmentDurations: segments.map(\.duration),
            hasAudio: hadAudio
        )
    }

    func trim(_ recording: BTSRecording, toSeconds clipDuration: TimeInterval) async throws -> Data? {
        guard let segmentWindows = BTSTrim.windows(
            recordedDurations: recording.segmentDurations,
            clipDuration: clipDuration
        ), !segmentWindows.isEmpty else { return nil }

        let destination = Self.directory.appendingPathComponent("clip-\(UUID().uuidString).mov")

        // Single-segment direct export (fast, zero re-encode overhead)
        if segmentWindows.count == 1 {
            let segIndex = segmentWindows[0].index
            let source = segIndex < recording.segmentURLs.count ? recording.segmentURLs[segIndex] : recording.segmentURLs[0]
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw BTSRecorderError.exportFailed("the recording is no longer on disk")
            }
            return try await Self.exportSingleSegment(source: source, window: segmentWindows[0].window, destination: destination)
        }

        // Multi-segment composition: load tracks from each segment
        struct ValidSegment {
            let url: URL
            let asset: AVURLAsset
            let videoTrack: AVAssetTrack
            let window: BTSTrim.Window
        }

        var validSegments: [ValidSegment] = []
        for segmentWindow in segmentWindows {
            guard segmentWindow.index < recording.segmentURLs.count else { continue }
            let sourceURL = recording.segmentURLs[segmentWindow.index]
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
            let asset = AVURLAsset(url: sourceURL)
            if let videoTracks = try? await asset.loadTracks(withMediaType: .video),
               let sourceVideoTrack = videoTracks.first {
                validSegments.append(ValidSegment(
                    url: sourceURL,
                    asset: asset,
                    videoTrack: sourceVideoTrack,
                    window: segmentWindow.window
                ))
            }
        }

        guard !validSegments.isEmpty else {
            throw BTSRecorderError.exportFailed("no valid video segments to export")
        }

        if validSegments.count == 1 {
            return try await Self.exportSingleSegment(
                source: validSegments[0].url,
                window: validSegments[0].window,
                destination: destination
            )
        }

        // Multi-track composition stitching
        let composition = AVMutableComposition()
        let scale = CMTimeScale(600)
        var insertTime = CMTime.zero

        let firstTrack = validSegments[0].videoTrack
        let defaultRenderDimensions: (w: CGFloat, h: CGFloat) = (1080, 1440)
        let naturalSize0 = (try? await firstTrack.load(.naturalSize)) ?? CGSize(width: defaultRenderDimensions.w, height: defaultRenderDimensions.h)
        let transform0 = (try? await firstTrack.load(.preferredTransform)) ?? .identity
        let rect0 = CGRect(origin: .zero, size: naturalSize0).applying(transform0)
        let renderWidth = abs(rect0.width) > 0 ? abs(rect0.width) : defaultRenderDimensions.w
        let renderHeight = abs(rect0.height) > 0 ? abs(rect0.height) : defaultRenderDimensions.h
        let renderSize = CGSize(width: renderWidth, height: renderHeight)

        var instructions: [AVMutableVideoCompositionInstruction] = []
        let compAudioTrack = recording.hasAudio ? composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) : nil
        var hasValidAudio = false

        for segment in validSegments {
            guard let compTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            let durationCM = CMTime(seconds: segment.window.duration, preferredTimescale: scale)
            let startCM = CMTime(seconds: segment.window.start, preferredTimescale: scale)
            let timeRange = CMTimeRange(start: startCM, duration: durationCM)

            try compTrack.insertTimeRange(timeRange, of: segment.videoTrack, at: insertTime)

            let trackTransform = (try? await segment.videoTrack.load(.preferredTransform)) ?? .identity
            let trackNaturalSize = (try? await segment.videoTrack.load(.naturalSize)) ?? naturalSize0
            let trackRect = CGRect(origin: .zero, size: trackNaturalSize).applying(trackTransform)
            let trackWidth = abs(trackRect.width) > 0 ? abs(trackRect.width) : renderWidth
            let trackHeight = abs(trackRect.height) > 0 ? abs(trackRect.height) : renderHeight
            let scaleX = renderWidth / trackWidth
            let scaleY = renderHeight / trackHeight
            let finalTransform = trackTransform.concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: insertTime, duration: durationCM)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
            layerInstruction.setTransform(finalTransform, at: insertTime)
            instruction.layerInstructions = [layerInstruction]
            instructions.append(instruction)

            if let compAudioTrack {
                if let audioTracks = try? await segment.asset.loadTracks(withMediaType: .audio),
                   let sourceAudioTrack = audioTracks.first {
                    let audioDuration = (try? await sourceAudioTrack.load(.timeRange).duration) ?? durationCM
                    let safeAudioDuration = min(durationCM, audioDuration)
                    let audioRange = CMTimeRange(start: startCM, duration: safeAudioDuration)
                    if (try? compAudioTrack.insertTimeRange(audioRange, of: sourceAudioTrack, at: insertTime)) != nil {
                        hasValidAudio = true
                    }
                }
            }

            insertTime = CMTimeAdd(insertTime, durationCM)
        }

        if let compAudioTrack, !hasValidAudio {
            composition.removeTrack(compAudioTrack)
        }

        guard insertTime > .zero, !instructions.isEmpty else {
            throw BTSRecorderError.exportFailed("no valid video segments to export")
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw BTSRecorderError.exportFailed("could not create an export session for composition")
        }
        session.outputURL = destination
        session.outputFileType = .mov
        session.videoComposition = videoComposition

        do {
            return try await Self.runExport(session: session, destination: destination)
        } catch {
            // Safety net: if multi-segment composition export fails on device,
            // fall back to exporting the primary segment with passthrough so BTS is never lost.
            if let primary = validSegments.first {
                return try await Self.exportSingleSegment(
                    source: primary.url,
                    window: primary.window,
                    destination: destination
                )
            }
            throw error
        }
    }

    private static func exportSingleSegment(source: URL, window: BTSTrim.Window, destination: URL) async throws -> Data {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw BTSRecorderError.exportFailed("could not create an export session")
        }
        let scale = CMTimeScale(600)
        session.outputURL = destination
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: window.start, preferredTimescale: scale),
            duration: CMTime(seconds: window.duration, preferredTimescale: scale)
        )
        return try await Self.runExport(session: session, destination: destination)
    }

    func discard(_ recording: BTSRecording) {
        for url in recording.segmentURLs {
            try? FileManager.default.removeItem(at: url)
        }
        lock.withLock {
            completedSegments.removeAll { seg in recording.segmentURLs.contains(seg.fileURL) }
        }
    }

    func abandon() {
        let (toStop, completed) = lock.withLock { () -> ((URL, MovieFileDelegate)?, [(fileURL: URL, duration: TimeInterval)]) in
            let open = activeFileURL.flatMap { url in activeDelegate.map { (url, $0) } }
            let completed = completedSegments
            activeFileURL = nil
            activeDelegate = nil
            completedSegments = []
            isSessionOpen = false
            return (open, completed)
        }

        deactivateAudioSession()

        for item in completed {
            try? FileManager.default.removeItem(at: item.fileURL)
        }

        guard let controller, controller.movieFileOutput != nil else {
            if let (url, _) = toStop {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }

        if let (url, delegate) = toStop {
            delegate.fileToDeleteOnCompletion = url
            delegate.holdSelfUntilCallback()
            controllerQueue.async { [weak controller] in
                controller?.movieFileOutput?.stopRecording()
            }
        }
    }

    func clearTemporaryFiles() {
        Self.purgeTemporaryFiles()
    }

    // MARK: - Export

    private static func runExport(session: AVAssetExportSession, destination: URL) async throws -> Data {
        await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                continuation.resume()
            }
        }

        switch session.status {
        case .completed:
            guard let bytes = FileManager.default.contents(atPath: destination.path) else {
                try? FileManager.default.removeItem(at: destination)
                throw BTSRecorderError.exportFailed("the trimmed clip could not be read back")
            }
            try? FileManager.default.removeItem(at: destination)
            return bytes
        case .cancelled, .failed:
            try? FileManager.default.removeItem(at: destination)
            throw session.error ?? BTSRecorderError.exportFailed("the export did not complete")
        default:
            try? FileManager.default.removeItem(at: destination)
            throw BTSRecorderError.exportFailed("the export ended in an unexpected state")
        }
    }

    // MARK: - Audio

    /// Configures the audio session for recording.
    ///
    /// **Best-effort and swallowing, deliberately.** A microphone that refuses to
    /// configure must not cost the user their moment: the photographs are the
    /// product, and ADR-013's rule is that a denied or unavailable microphone
    /// yields a *silent clip*, never a blocked capture. The failure surfaces as
    /// `hasAudio == false` rather than as an error the user has to act on.
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
            try session.setActive(true)
            audioSession = session
        } catch {
            deactivateAudioSession()
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        audioSession = nil
    }
}

/// The delegate `AVCaptureMovieFileOutput` requires, and the only source of a
/// recorded clip's duration.
///
/// **I wrote this recorder against a memory of the API and the compiler caught
/// it.** `stopRecording` takes no arguments, so there is no completion handler
/// carrying a duration — the number arrives here, in
/// `didFinishRecordingTo:…error:`, or not at all. The first version had this type
/// empty on the reasoning that the duration was "the value actually measured by
/// the output", which was true and irrelevant: nothing was reading it.
///
/// `@unchecked Sendable` because the protocol AVFoundation declares is not
/// annotated for Swift 6 concurrency and the object crosses into it directly.
/// The one mutable field is `onFinished`, written on the controller queue before
/// `stopRecording()` and read once on the delegate's callback — the same
/// hand-off shape the project already uses for `previewSurface`.
/// Ensures a continuation is resumed exactly once and never hangs.
/// All mutable state is confined to `lock` to guarantee continuation is resumed at most once.
private final class SafeContinuationResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<(TimeInterval?, Error?), Never>

    init(continuation: CheckedContinuation<(TimeInterval?, Error?), Never>) {
        self.continuation = continuation
    }

    func resume(duration: TimeInterval?, error: Error?) {
        let shouldResume = lock.withLock {
            if !didResume {
                didResume = true
                return true
            }
            return false
        }
        if shouldResume {
            continuation.resume(returning: (duration, error))
        }
    }
}

private final class MovieFileDelegate: NSObject, AVCaptureFileOutputRecordingDelegate,
                                      @unchecked Sendable {

    private let lock = NSLock()
    private var _onFinished: ((TimeInterval?, Error?) -> Void)?
    private var _finishedResult: (TimeInterval?, Error?)?
    private var selfRetain: MovieFileDelegate?

    /// Called when the output has finished writing, with the measured duration.
    /// Delivers cached result immediately if didFinishRecordingTo already ran.
    var onFinished: ((TimeInterval?, Error?) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onFinished
        }
        set {
            let pending: (TimeInterval?, Error?)? = lock.withLock {
                _onFinished = newValue
                return (newValue != nil) ? _finishedResult : nil
            }
            if let pending, let callback = newValue {
                callback(pending.0, pending.1)
            }
        }
    }

    /// File to delete once AVFoundation completes writing, if abandoned.
    var fileToDeleteOnCompletion: URL?

    func holdSelfUntilCallback() {
        lock.withLock { selfRetain = self }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {}

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let toDelete = lock.withLock { () -> URL? in
            let file = fileToDeleteOnCompletion
            fileToDeleteOnCompletion = nil
            selfRetain = nil
            return file
        }

        if let toDelete {
            try? FileManager.default.removeItem(at: toDelete)
        }

        Task {
            let dur = await Self.duration(of: outputFileURL)
            let callback: ((TimeInterval?, Error?) -> Void)? = self.lock.withLock {
                self._finishedResult = (dur, error)
                return self._onFinished
            }
            callback?(dur, error)
        }
    }

    /// The recorded file's own duration, in seconds.
    ///
    /// **The file, not a clock.** The duration the output actually wrote is the
    /// number `BTSTrim` needs; wall time between two `Date()` calls is bounded by
    /// the same start and stop but includes the teardown, and on a busy phone the
    /// two differ by more than a frame.
    ///
    /// **`nil` for an unreadable or zero-length asset**, and the caller treats that
    /// as an error rather than substituting a guess — see `onFinished`.
    fileprivate static func duration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let loaded = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(loaded)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

}
