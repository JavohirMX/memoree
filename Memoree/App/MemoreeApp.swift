import SwiftUI

/// The application root.
///
/// Phase 0 only proves the build/install/sign pipeline by rendering a black
/// screen. Feature screens arrive in later phases; `RootView` is deliberately
/// minimal until then.
@main
struct MemoreeApp: App {

    var body: some Scene {
        WindowGroup {
            RootView()
                // Dark only. Stated here so the intent is visible at the top of
                // the app rather than buried in Info.plist (ADR-012).
                .preferredColorScheme(.dark)
        }
    }
}

/// Phase 0 placeholder. Replaced by onboarding → Today routing in Phase 5.
struct RootView: View {
    var body: some View {
        ZStack {
            Theme.Color.canvas
                .ignoresSafeArea()

            Text("Memoree")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)
        }
    }
}

#Preview {
    RootView()
}
