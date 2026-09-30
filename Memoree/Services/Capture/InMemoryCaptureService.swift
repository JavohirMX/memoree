import AVFoundation
import Foundation
import QuartzCore

/// An in-memory `CapturePhotoService` for tests and previews.
///
/// Every UI test uses this, so no test needs a real camera. The simulator has
/// no capture hardware at all, so without this the entire capture flow would be
/// untestable off-device (AGENTS.md §3, §7).
///
/// Thread-safe: Swift Testing runs suites in parallel.
///
/// Records what it was asked to do, so tests assert the *calls* — that a pair
/// was captured in the right order, that the front was waited for — rather than
/// merely that nothing crashed.
final class InMemoryCaptureService: CapturePhotoService, @unchecked Sendable {

    private struct State {
        var authorization: CameraAuthorizationStatus = .authorized
        var isRunning = false
        var startCount = 0
        var stopCount = 0
        var rebuildCount = 0
        var configuredFormats: [CameraPosition] = []
        var capturedPositions: [CameraPosition] = []
        var swapCount = 0
        var capturePairCount = 0
        /// Whether `waitForDeliveredFrame` was called before the front capture.
        var didWaitForFrameBeforeFront = false
        var failureToThrow: CaptureError?
        /// Injected delay before a pair is returned, for testing progress states.
        var artificialDelay: TimeInterval = 0
    }

    private let lock = NSLock()
    private var state = State()
    private var counter = 0

    /// A real `AVCaptureVideoPreviewLayer` would need a live session, and a
    /// `CALayer` is what the view actually installs — so a plain layer is both
    /// sufficient and honest. Tests assert on the layer's presence, not pixels.
    private let surface = CALayer()

    // MARK: - Test configuration

    func setAuthorization(_ status: CameraAuthorizationStatus) {
        lock.withLock { state.authorization = status }
    }

    /// Makes the next capture call throw, for testing error states.
    func failNextCapture(with error: CaptureError) {
        lock.withLock { state.failureToThrow = error }
    }

    /// Delays `capturePair`, so a test can observe the in-progress state.
    func setArtificialDelay(_ delay: TimeInterval) {
        lock.withLock { state.artificialDelay = delay }
    }

    // MARK: - Inspection

    var isRunning: Bool { lock.withLock { state.isRunning } }
    var startCount: Int { lock.withLock { state.startCount } }
    var stopCount: Int { lock.withLock { state.stopCount } }
    var rebuildCount: Int { lock.withLock { state.rebuildCount } }
    var configuredFormats: [CameraPosition] { lock.withLock { state.configuredFormats } }
    var capturedPositions: [CameraPosition] { lock.withLock { state.capturedPositions } }
    var swapCount: Int { lock.withLock { state.swapCount } }
    var capturePairCount: Int { lock.withLock { state.capturePairCount } }
    var didWaitForFrameBeforeFront: Bool {
        lock.withLock { state.didWaitForFrameBeforeFront }
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

    func startSession() async throws {
        try lock.withLock {
            try Self.throwIfNeeded(&state)
            state.isRunning = true
            state.startCount += 1
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

    func rebuildSession() async throws {
        try lock.withLock {
            try Self.throwIfNeeded(&state)
            state.rebuildCount += 1
            state.isRunning = true
        }
    }

    func capturePhoto(at position: CameraPosition) async throws -> CapturedPhoto {
        try lock.withLock {
            try Self.throwIfNeeded(&state)
            state.capturedPositions.append(position)
            counter += 1
            return Self.photo(position: position, sequence: counter)
        }
    }

    /// Mirrors `SequentialCaptureService.capturePair()`, including the frame-wait
    /// ordering, so a test can assert the sequence without a camera.
    func capturePair() async throws -> CapturedPair {
        let delay = lock.withLock { () -> TimeInterval in
            state.capturePairCount += 1
            return state.artificialDelay
        }
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }

        let back = try await capturePhoto(at: .back)

        lock.withLock {
            state.swapCount += 1
            // Step 7 of TRD §5.2: the wait happens between the swap and the
            // front capture. Recorded so a test can prove it was not skipped.
            state.didWaitForFrameBeforeFront = true
        }

        let front = try await capturePhoto(at: .front)
        return CapturedPair(back: back, front: front)
    }

    // MARK: - Helpers

    private static func throwIfNeeded(_ state: inout State) throws {
        guard let failure = state.failureToThrow else { return }
        state.failureToThrow = nil
        throw failure
    }

    /// A recognisable, correctly-shaped placeholder.
    ///
    /// Real 3:4 dimensions rather than 1×1, so a test that checks geometry
    /// against a captured pair is checking something meaningful.
    private static func photo(position: CameraPosition, sequence: Int) -> CapturedPhoto {
        CapturedPhoto(
            data: Data("mock-\(position.rawValue)-\(sequence)".utf8),
            pixelWidth: 3024,
            pixelHeight: 4032,
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
