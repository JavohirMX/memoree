import Foundation
import SwiftUI

/// Animation that respects Reduce Motion.
///
/// The app has four animations and no Reduce Motion handling, which means a user
/// who has asked the system for less movement gets four anyway. On a black canvas
/// with nothing else moving, that is the difference between an app that feels
/// calm and one that twitches — and the setting exists because some people find
/// motion physically unpleasant, not merely distracting.
///
/// ## Why a wrapper rather than a modifier
///
/// `.animation(_:value:)` takes an `Animation`, and an `Animation` is the thing
/// that has to change. So the environment value is read *once, where the
/// animation is written*, rather than through a `.modifier` on the view — which
/// would have to reach inside the view's own modifiers to replace them, and
/// cannot.
///
/// The alternative considered and rejected: `transaction { $0.animation = nil }`.
/// That removes animations added *later* by the same transaction, not the ones a
/// view has already declared, so it silently does nothing here.
///
/// ## What is replaced
///
/// `nil`, which removes the animation and makes the change immediate — not a
/// faster animation, which is not the same thing. A user who has asked for no
/// motion gets none, including none on the properties they did not know were
/// animating.
/// Not `@MainActor`.
///
/// `EnvironmentKey.defaultValue` is read by SwiftUI from wherever it reads the
/// environment, which is not necessarily the main actor, so a main-actor-isolated
/// conformance is a data race the compiler is right to refuse. The value is a
/// `Bool` and genuinely has no isolation requirement.
struct ReducedMotionKey: EnvironmentKey {
    /// Read through the environment rather than from
    /// `UIAccessibility.isReduceMotionEnabled` directly, because the two can
    /// disagree: the environment value follows the setting as SwiftUI observes
    /// it, and a view that reads UIKit behind SwiftUI's back will not update when
    /// the user changes it while the app is backgrounded.
    ///
    /// `HapticFeedback` reads the UIKit value instead, and that is not an
    /// inconsistency — a `UIImpactFeedbackGenerator` is a UIKit object with no
    /// SwiftUI environment, and it is honouring the same setting by the only
    /// route available to it.
    static let defaultValue = false
}

extension EnvironmentValues {
    var isReduceMotionEnabled: Bool {
        get { self[ReducedMotionKey.self] }
        set { self[ReducedMotionKey.self] = newValue }
    }
}

extension View {
    /// The app's animation, or none at all when Reduce Motion is on.
    ///
    /// Every `.animation` in Memoree goes through this. A new one that does not
    /// is a new one that ignores a user's accessibility setting, and it looks
    /// identical in review.
    @ViewBuilder
    func appAnimation<V: Equatable>(
        _ value: V,
        body: @escaping () -> Animation = { .default }
    ) -> some View {
        // `@Environment` is read here rather than taking the value as a
        // parameter, so a view cannot pass the wrong one — and a view that
        // forgets to consult it fails the same way a view that forgets the
        // modifier entirely would: by animating.
        @Environment(\.isReduceMotionEnabled) var reduceMotion
        animation(reduceMotion ? nil : body(), value: value)
    }
}

/// The ambient value, injected once at the root.
///
/// Injected rather than computed in each view because `UIAccessibility
/// .isReduceMotionEnabled` is a snapshot, and the app has to be told when it
/// changes — which it is, here, by a notification posted while the app is
/// backgrounded.
private struct ReduceMotionObserver: ViewModifier {

    @State private var isEnabled = UIAccessibility.isReduceMotionEnabled

    func body(content: Content) -> some View {
        content
            .environment(\.isReduceMotionEnabled, isEnabled)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIAccessibility.reduceMotionStatusDidChangeNotification
                )
            ) { _ in
                isEnabled = UIAccessibility.isReduceMotionEnabled
            }
    }
}

extension View {
    /// Publishes the current Reduce Motion state to the tree.
    ///
    /// Applied once, in `MemoreeApp`, and not in each screen: the setting is
    /// global and a per-screen subscription would be a per-screen chance to be
    /// wrong.
    func observingReduceMotion() -> some View {
        modifier(ReduceMotionObserver())
    }
}
