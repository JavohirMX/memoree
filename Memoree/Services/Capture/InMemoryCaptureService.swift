import AVFoundation
import Foundation
import QuartzCore

/// An in-memory `CapturePhotoService` for tests and previews.
///
/// Every UI test uses this, so no test needs a real camera. The simulator has
/// no capture hardware at all, so without this the entire capture flow would be
/// untestable off-device (AGENTS.md §3, §7).
///
/// Models the **user-paced** sequence of ADR-021: the caller captures one
/// camera, then explicitly switches, then captures the other. It records what it
/// was asked to do so tests assert the *calls* — that the swap happened on the
/// second press and not the first — rather than merely that nothing crashed.
///
/// Thread-safe: Swift Testing runs suites in parallel.
final class InMemoryCaptureService: CapturePhotoService, @unchecked Sendable {

    private struct State {
        var authorization: CameraAuthorizationStatus = .authorized
        var isRunning = false
        var startCount = 0
        var stopCount = 0
        var rebuildCount = 0
        var configuredFormats: [CameraPosition] = []
        /// The rotation the double is pretending to have applied.
        ///
        /// The real one comes from a rotation coordinator that watches real
        /// hardware, so a double has to be told rather than derive it — the same
        /// way it is told about authorization.
        var orientation: CaptureOrientation?
        /// The zoom in force, and every zoom asked for.
        ///
        /// Both recorded so a test can assert the choice is **remembered across a
        /// swap** — the failure mode that gives a moment two different framings.
        var zoom: CameraZoom = .wide
        var zoomRequests: [CameraZoom] = []
        /// Every point focus was asked for, in the normalised 0…1 form the
        /// protocol takes, so a test can assert the view passes one.
        var focusRequests: [CGPoint] = []
        /// Cameras captured, in the order the user shot them.
        var capturedPositions: [CameraPosition] = []
        /// Cameras switched to, in order. Should mirror `capturedPositions`
        /// minus the first: one switch between the two shots.
        var switchedTo: [CameraPosition] = []
        /// Cameras the session was opened on.
        var openedOn: [CameraPosition] = []
        /// The camera live **right now**. Distinct from `openedOn.last`: after
        /// `switchCamera(to:)` the two disagree, and reading the wrong one makes
        /// a capture report the camera the user already left.
        var livePosition: CameraPosition = .back
        var switchCount = 0
        var capturePairCount = 0
        /// Whether a frame wait happened before each switch.
        var didWaitForFrameBeforeSwitch = false
        var failureToThrow: CaptureError?
        /// Separate slots, because a test that wants to fail *the switch* must
        /// not have that failure consumed by the capture which precedes it in
        /// the same shutter press. One shared slot made that impossible to
        /// express, and the resulting test failure was in the double, not the
        /// model.
        var captureFailure: CaptureError?
        var switchFailure: CaptureError?
        /// Whether the capture subsystem is dead.
        ///
        /// Distinct from `captureFailure`, which is a **single** injected
        /// failure. This one persists until `rebuildSession()`, because that is
        /// what a dead capture daemon does — it stops answering and stays
        /// stopped, and nothing short of replacing the session revives it.
        var isSubsystemDead = false
        /// Injected delay, for testing progress states.
        var artificialDelay: TimeInterval = 0
    }

    private let lock = NSLock()
    private var state = State()
    private var counter = 0

    /// A real `AVCaptureVideoPreviewLayer` would need a live session, and a
    /// `CALayer` is what the view actually installs — so a plain layer is both
    /// sufficient and honest. Tests assert the layer's presence, not pixels.
    private let surface = CALayer()

    // MARK: - Test configuration

    func setAuthorization(_ status: CameraAuthorizationStatus) {
        lock.withLock { state.authorization = status }
    }

    /// Makes the next capture throw, for testing error states.
    func failNextCapture(with error: CaptureError) {
        lock.withLock { state.captureFailure = error }
    }

    /// Makes the next camera switch throw.
    ///
    /// Targeted separately from captures, and the separation is load-bearing
    /// rather than tidy: the second half of a single shutter press does both, so
    /// with one shared slot a test could never express "the photograph
    /// succeeds and the camera switch does not" — the capture would always eat
    /// the failure first.
    func failNextSwitch(with error: CaptureError) {
        lock.withLock { state.switchFailure = error }
    }

    /// Kills the capture subsystem, as a dead capture daemon does.
    ///
    /// ## The behaviour this models, and why it is the important one
    ///
    /// `failNextCapture(with: .photoDataUnavailable(…))` throws **once** and then
    /// the double is healthy again — which models a single dropped callback and
    /// nothing like the real failure. When the daemon actually dies it does not
    /// recover on its own, so **every** capture fails until something rebuilds
    /// the session, and `rebuildSession()` is the only thing that brings it back.
    ///
    /// Without this the double cannot express the defect the capture path had: a
    /// `Try again` button that cannot succeed, because the subsystem behind it
    /// stayed dead. A double that cannot exercise the code it stands in for is a
    /// double that hides bugs.
    func killCaptureSubsystem() {
        lock.withLock { state.isSubsystemDead = true }
    }

    /// Whether the subsystem is currently dead.
    var isSubsystemDead: Bool { lock.withLock { state.isSubsystemDead } }

    /// Delays every operation, so a test can observe the in-progress state.
    func setArtificialDelay(_ delay: TimeInterval) {
        lock.withLock { state.artificialDelay = delay }
    }

    // MARK: - Inspection

    var isRunning: Bool { lock.withLock { state.isRunning } }
    var startCount: Int { lock.withLock { state.startCount } }
    var stopCount: Int { lock.withLock { state.stopCount } }
    var rebuildCount: Int { lock.withLock { state.rebuildCount } }
    var configuredFormats: [CameraPosition] { lock.withLock { state.configuredFormats } }
    var focusRequests: [CGPoint] { lock.withLock { state.focusRequests } }
    var capturedPositions: [CameraPosition] { lock.withLock { state.capturedPositions } }
    var switchedTo: [CameraPosition] { lock.withLock { state.switchedTo } }
    var openedOn: [CameraPosition] { lock.withLock { state.openedOn } }
    var switchCount: Int { lock.withLock { state.switchCount } }
    var didWaitForFrameBeforeSwitch: Bool {
        lock.withLock { state.didWaitForFrameBeforeSwitch }
    }

    // MARK: - CapturePhotoService

    var previewLayer: CALayer { surface }

    func authorizationStatus() -> CameraAuthorizationStatus {
        lock.withLock { state.authorization }
    }

    func requestAuthorization() async -> CameraAuthorizationStatus {
        lock.withLock { state.authorization = .authorized }
        return .authorized
    }

    func startSession(on position: CameraPosition) async throws {
        let delay = lock.withLock { state.artificialDelay }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }

        try lock.withLock {
            try Self.throwIfNeeded(&state)
            state.isRunning = true
            state.startCount += 1
            state.openedOn.append(position)
            state.livePosition = position
        }
    }

    func stopSession() async {
        lock.withLock {
            state.isRunning = false
            state.stopCount += 1
        }
    }

    func configureFormat(for position: CameraPosition) async throws {
        try lock.withLock {
            try Self.throwIfNeeded(&state)
            state.configuredFormats.append(position)
        }
    }

    func currentRotation() async -> CaptureOrientation? {
        lock.withLock { state.orientation }
    }

    func focus(atNormalizedPoint point: CGPoint) async {
        lock.withLock { state.focusRequests.append(point) }
    }

    func applyZoom(_ zoom: CameraZoom) async throws {
        try lock.withLock {
            try Self.throwIfNeeded(&state)
            guard zoom.isAvailable(on: state.livePosition) else {
                throw CaptureError.zoomUnavailable(zoom, state.livePosition)
            }
            state.zoom = zoom
            state.zoomRequests.append(zoom)
        }
    }

    func currentZoom() async -> CameraZoom {
        lock.withLock { state.zoom }
    }

    func rebuildSession() async throws {
        try lock.withLock {
            try Self.throwIfNeeded(&state)
            state.rebuildCount += 1
            state.isRunning = true
            // **The one thing that revives a dead subsystem.** Matches
            // `rebuildSession`'s real behaviour of constructing a new session,
            // which is a fresh connection to a capture daemon that has since
            // restarted.
            state.isSubsystemDead = false
        }
    }

    /// Records the switch and the frame-wait that must precede it.
    ///
    /// Step 7 of TRD §5.2: the wait happens between the switch and the next
    /// capture. Recorded so a test can prove it was not skipped — capturing
    /// before the sensor delivers yields a black or green photograph, silently.
    func switchCamera(to position: CameraPosition) async throws {
        let delay = lock.withLock { state.artificialDelay }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }

        try lock.withLock {
            try Self.throwSwitchIfNeeded(&state)
            state.switchedTo.append(position)
            state.switchCount += 1
            state.livePosition = position
            state.didWaitForFrameBeforeSwitch = true
        }
    }

    func captureCurrentPhoto() async throws -> CapturedPhoto {
        let delay = lock.withLock { state.artificialDelay }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }

        return try lock.withLock {
            // **Checked before the injected single-shot failure**, so a test that
            // kills the subsystem and also injects a one-off is testing what it
            // thinks it is: the dead subsystem is the state that persists, and
            // `photoDataUnavailable` is exactly what a dead one reports.
            if state.isSubsystemDead {
                throw CaptureError.photoDataUnavailable(state.livePosition)
            }
            try Self.throwCaptureIfNeeded(&state)
            counter += 1
            let position = state.livePosition
            state.capturedPositions.append(position)
            return Self.photo(position: position, sequence: counter)
        }
    }

    // MARK: - Helpers

    private static func throwIfNeeded(_ state: inout State) throws {
        guard let failure = state.failureToThrow else { return }
        state.failureToThrow = nil
        throw failure
    }

    private static func throwCaptureIfNeeded(_ state: inout State) throws {
        guard let failure = state.captureFailure else { return }
        state.captureFailure = nil
        throw failure
    }

    private static func throwSwitchIfNeeded(_ state: inout State) throws {
        guard let failure = state.switchFailure else { return }
        state.switchFailure = nil
        throw failure
    }

    /// A recognisable, correctly-shaped placeholder.
    ///
    /// Real 3:4 dimensions rather than 1×1, so a test that checks geometry
    /// against a captured pair is checking something meaningful.
    private static func photo(position: CameraPosition, sequence: Int) -> CapturedPhoto {
        CapturedPhoto(
            data: Data("mock-\(position.rawValue)-\(sequence)".utf8),
            pixelWidth: 4032,
            pixelHeight: 3024,     // sensor-native landscape; 3:4 either way
            position: position
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
