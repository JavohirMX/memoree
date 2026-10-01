import Foundation
import UIKit

/// Haptics, in one place.
///
/// **A service, not a `UIImpactFeedbackGenerator` scattered through the views.**
/// Three reasons, and the second is the one that decides it:
///
/// 1. `UIFeedbackGenerator` is `UIKit`, so a view may use it and a service may
///    not (`AGENTS.md` §3). Putting these calls in `Services` keeps the camera
///    and Today screens free of them.
/// 2. **`Services/` may not import SwiftUI**, and `@Environment(\.accessibility
///    ReduceMotion)` is a SwiftUI value. Honouring Reduce Motion from inside a
///    service therefore means reading `UIAccessibility.isReduceMotionEnabled`
///    directly — which is a *better* source anyway, because it does not require
///    the view to be alive to ask.
/// 3. A test double. `UIImpactFeedbackGenerator` cannot be observed, so "the
///    shutter buzzes" is either untested or tested by asserting on a real
///    device's Taptic Engine, which nobody does.
///
/// ## What each one is for
///
/// The rule is that **a haptic describes something the user did**, not something
/// the app did internally. That is the whole reason there are two live events and
/// not three.
///
/// The camera switch is the case that proves it. One shutter press photographs
/// *and* swaps cameras — the swap rides along with the press rather than being a
/// second thing the user does — so buzzing for both would tell the user two
/// things happened when they pressed once, and the second buzz would arrive
/// while the preview was still the old camera, describing something that had not
/// happened yet. **So `cameraSwitched` has no call site, and that is the correct
/// state.** If the mechanic ever becomes a separate switch the user performs, it
/// gets its own buzz then.
///
/// The two that remain:
///
/// - **`.light`** — the shutter. A photograph is a small, ordinary event and
///   `.medium` or `.heavy` overstates it into something consequential.
/// - **`.success`** — the commit, once the pair is written. The only one that
///   means *done*, and the only notification feedback in the app.
///
/// **Nothing on failure.** A failure haptic on a permission denial is the system
/// telling the user something they did not do wrong, and Memoree's own copy
/// already says what happened.
@MainActor
protocol HapticFeedback: AnyObject {
    /// The shutter was pressed and a photograph was taken.
    func shutter()
    /// The camera swapped sides.
    ///
    /// **No call site, deliberately** — see the type's documentation. Declared
    /// because it is the obvious third event, and a reader would otherwise
    /// reasonably wonder whether the switch had simply been forgotten.
    func cameraSwitched()
    /// The pair was written and the moment recorded.
    func committed()
}

@MainActor
final class SystemHapticFeedback: HapticFeedback {

    /// Generators are created once and kept.
    ///
    /// `prepare()` is what makes the buzz immediate: a generator created *at the
    /// moment of the tap* has to spin up, and the delay is perceptible as a lag
    /// between the finger leaving the glass and the sensation arriving — which
    /// reads as the phone being slow rather than as feedback.
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()

    func prepare() {
        light.prepare()
        rigid.prepare()
        notification.prepare()
    }

    func shutter() {
        // No-op when Reduce Motion is on.
        //
        // Haptics are not "motion" and a user who has not asked for reduced
        // motion has not asked for silence — but iOS pairs the two settings on
        // every system that offers haptics, users switch them together, and a
        // full-screen flash of Taptic Engine on every photograph is exactly what
        // someone turning that switch down is avoiding. **Honouring it is a
        // decision, not a fact**, and it is recorded here so it is a decision
        // rather than an omission.
        guard !Self.isReduceMotionEnabled else { return }
        light.impactOccurred()
    }

    func cameraSwitched() {
        guard !Self.isReduceMotionEnabled else { return }
        rigid.impactOccurred()
    }

    func committed() {
        guard !Self.isReduceMotionEnabled else { return }
        notification.notificationOccurred(.success)
    }

    /// Read from UIKit rather than from SwiftUI's environment.
    ///
    /// See the type's note: a service cannot import SwiftUI, and this is the
    /// same underlying setting. `UIAccessibility` also holds a snapshot that
    /// refreshes on its own, so there is no observer to leak.
    private static var isReduceMotionEnabled: Bool {
        UIAccessibility.isReduceMotionEnabled
    }
}

/// Records what was asked for, so a test can assert on it.
///
/// In the app target rather than the test target, for the same reason
/// `InMemoryPhotoLibraryService` is: the production code takes the protocol, and
/// a double that only exists in tests is a double nothing in the app can be
/// given.
@MainActor
final class InMemoryHapticFeedback: HapticFeedback {

    enum Event: Equatable {
        case shutter
        case cameraSwitch
        case commit
    }

    private(set) var events: [Event] = []
    private(set) var prepareCount = 0

    func prepare() { prepareCount += 1 }
    func shutter() { events.append(.shutter) }
    func cameraSwitched() { events.append(.cameraSwitch) }
    func committed() { events.append(.commit) }

    /// Whether the app buzzed at all.
    ///
    /// The assertion most of the tests want, because "no haptics fired" is a
    /// valid state — a user with Reduce Motion on, or a simulator.
    var isSilent: Bool { events.isEmpty }
}
