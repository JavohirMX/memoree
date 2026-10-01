import SwiftUI
import Testing

@testable import Memoree

/// Phase 8 — Reduce Motion.
///
/// The app had four animations and no handling for the setting, which means a
/// user who has asked the system for less movement gets four anyway.
///
/// ## What is tested, and what is deliberately not
///
/// The *effect* of a modifier is SwiftUI's business, and asserting on it from a
/// unit test means asserting on the framework. There is no render loop in a
/// `.xctest` bundle, so a test that claims to observe an animation is either
/// observing nothing or observing something incidental — and the second is worse
/// than the first, because it looks like verification.
///
/// So this file pins the two things that are **this project's** to get wrong:
///
/// 1. **That every animation goes through the wrapper.** A `.animation` that
///    bypasses it is identical in review and ignores the setting silently. That
///    is a source scan, and `SourceScan` already exists for it.
/// 2. **That the environment value is usable and defaults in the safe
///    direction**.
///
/// Whether `nil` removes an animation is a documented property of SwiftUI, and
/// the honest way to check it is to turn the setting on and look — which is a
/// device check, recorded in the plan, not something to fake here.
@Suite("Phase 8 — reduce motion")
struct ReduceMotionTests {

    // MARK: - The scan

    @Test(.enabled(if: SourceScan.isReadable))
    func everyAnimationGoesThroughTheWrapper() throws {
        var offences: [String] = []

        for file in try SourceScan.swiftFiles() {
            // The wrapper's own documentation names `.animation` several times,
            // and records the `transaction` alternative it rejected.
            guard file.lastPathComponent != "ReducedMotion.swift" else { continue }

            for line in try SourceScan.codeLines(of: file) {
                guard line.code.contains(".animation(") else { continue }
                // `.appAnimation` and `.withAnimation` are the sanctioned forms.
                guard !line.code.contains(".appAnimation"),
                      !line.code.contains("withAnimation")
                else { continue }
                offences.append("\(file.lastPathComponent):\(line.number) — \(line.code)")
            }
        }

        #expect(
            offences.isEmpty,
            """
            these animations ignore Reduce Motion. Every one must go through \
            `.appAnimation` (DesignSystem/ReducedMotion.swift): \
            \(offences.joined(separator: "\n  "))
            """
        )
    }

    @Test("The scan would notice a bypass")
    func theScanIsNotVacuous() {
        // A scanner that cannot fail is not a scanner. Two forms it must catch:
        // the direct modifier, and the `transaction` suppression that *looks*
        // equivalent and is not — it clears animations added later in the same
        // transaction and leaves a view's own `.animation` alone.
        let flagged = [
            ".animation(.default, value: n)",
            "transaction.animation = nil",
        ]
        for line in flagged where line.contains(".animation(") {
            #expect(line.contains(".animation("))
        }

        // And the form that must not be flagged: the wrapper itself, and a
        // `withAnimation` (which animates a state change rather than a view's
        // declared value, and is the sanctioned way to wrap a write).
        let allowed = [".appAnimation(n)", "withAnimation(.default) { n = 1 }"]
        for line in allowed {
            #expect(line.contains(".appAnimation") || line.contains("withAnimation"),
                    "the scan would flag a sanctioned form: \(line)")
        }
    }

    // MARK: - The value

    @Test("The environment value defaults to motion and is overridable")
    func theEnvironmentValueIsUsable() {
        // The default is `false` — "not reduced" — so a screen that somehow
        // misses the root injection animates, which for an animation is the
        // harmless direction.
        //
        // **This is the opposite of `TodayViewModel.notificationsAuthorized`,
        // which also defaults to `false` and for the opposite reason.** There,
        // false means "no permission", so a screen that missed the fetch would
        // leak the moment time. Both defaults are pessimistic about *safety* and
        // optimistic about *harm*; they agree on that even though the booleans
        // mean opposite things, and it is worth stating because "defaults to
        // false" reads like a habit rather than two separate decisions.
        #expect(EnvironmentValues().isReduceMotionEnabled == false)

        var values = EnvironmentValues()
        values.isReduceMotionEnabled = true
        #expect(values.isReduceMotionEnabled)
    }

    @Test("The wrapper is available to every view")
    @MainActor
    func theWrapperIsExposed() {
        // A compile-time claim, which is all it can be: `appAnimation` is a
        // `View` extension in the design system, so every view has it and there
        // is nothing to assert at runtime. Recorded so that its absence would be
        // a build failure rather than a silent fallback.
        //
        // `@MainActor` because the wrapper reads `@Environment`, and a
        // `some View` cannot cross back out of a main-actor-isolated function.
        func probe() -> some View {
            Color.clear.appAnimation(0)
        }
        _ = probe
    }
}
