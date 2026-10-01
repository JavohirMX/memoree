import Foundation
import Testing
import UIKit

@testable import Memoree

/// Namespace for the shared test doubles below.
///
/// Empty on purpose. These were private to `TodayViewModelTests` and are needed
/// by the Phase 6 suites as well — three files each declaring the same
/// fourteen-line scheduler is three places to fix when `MomentScheduler` grows a
/// method, and the copy that gets missed is the one that then reads a real value
/// and asserts on nothing.
enum TestSupport {
    typealias Clock = StepClock
    typealias Scheduler = FixedScheduler
}

/// A scheduler that returns the same moment for every day.
///
/// Deliberately the *worst* possible scheduler: it ignores the day and the
/// window entirely, so any test using it is testing something other than the
/// derivation. That is the point — it makes a test's fixture visible as
/// "everything is at 14:00" rather than hiding it behind a plausible-looking
/// hash, and it is why the window-change suite can pin tomorrow to 14:00 and
/// then assert the new window moved it.
struct FixedScheduler: MomentScheduler {

    let start: Date

    func momentInterval(
        for day: DayIdentifier,
        window: TimeWindow,
        windowDuration: TimeInterval
    ) -> MomentInterval {
        MomentInterval(start: start, end: start.addingTimeInterval(windowDuration))
    }

    func momentStart(
        for day: DayIdentifier,
        window: TimeWindow,
        windowDuration: TimeInterval
    ) -> Date { start }
}

/// A clock that advances by a fixed step on every read.
///
/// The alternative — a real `Date()` — makes "the ticker re-derives from the
/// clock" either untestable or a two-second sleep, and a sleep is a flake
/// waiting for a loaded CI box.
final class StepClock: @unchecked Sendable {

    private let lock = NSLock()
    private var current: Date
    private let step: TimeInterval

    init(origin: Date, step: TimeInterval = 0) {
        self.current = origin
        self.step = step
    }

    /// The current instant, advanced by `step` for the next read.
    ///
    /// A method rather than a property so it can be passed straight into a
    /// `TodayViewModel(environment:now:)` closure, which takes `@Sendable () ->
    /// Date`. A property would need wrapping at every call site, and one of them
    /// would eventually be wrapped wrong — reading it twice and getting two
    /// different instants, which is exactly the bug the injected clock exists to
    /// prevent.
    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = current
        current = current.addingTimeInterval(step)
        return value
    }
}

/// A 2×2 white PNG.
///
/// Rendered rather than pasted as base64, so a test file carries no opaque
/// blob. What it has to be is *decodable*: `InMemoryPhotoLibraryService.image`
/// builds a `UIImage` from these bytes, and a fixture that stopped decoding
/// would make every "missing from Photos" test pass for the wrong reason.
enum PixelFixture {

    static let png: Data = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        guard let data = image.pngData() else {
            Issue.record("could not build the fixture image")
            return Data()
        }
        return data
    }()
}
