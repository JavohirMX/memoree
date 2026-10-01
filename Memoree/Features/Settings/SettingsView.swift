import SwiftUI
import UIKit

/// Settings.
///
/// Four things, and the reason there are only four is that the app has one
/// preference worth having. Everything else is either a fact the user cannot
/// change, a permission the system owns, or a promise this app deliberately
/// does not make.
///
/// Reached from a gear in the Today header, presented as a sheet with its own
/// `NavigationStack` so it has a title and a dismiss affordance rather than
/// being a full-screen takeover — it is a place you visit, not a place you are.
struct SettingsView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    /// The window as it stands, so the picker has something to edit and a
    /// no-op drag is detectable.
    @State private var window = TimeWindow.default

    /// A commit is in flight.
    @State private var isCommitting = false

    /// Whether the last commit actually changed anything.
    ///
    /// Its own row, because the alternative is a control that appears to do
    /// nothing — and given that this screen is four months late in existing, the
    /// first thing anyone will do is drag a slider and look for proof.
    @State private var didApply = false

    /// Whether reminders are authorised. Re-read on appear rather than passed
    /// in: the user may have changed it in system Settings while this app was
    /// backgrounded, and this screen is the one place that can say so.
    @State private var remindersAuthorized = false

    var body: some View {
        NavigationStack {
            CanvasBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    windowSection
                    remindersSection
                    permanenceSection
                    diagnosticsSection
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.xl)
            }
        }
        .task { await reload() }
    }

    // MARK: - Window

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Your window")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            // The one paragraph that has to explain the whole mechanic, because
            // a window that only decides when you get interrupted is not
            // self-evident. Said as three facts rather than as a rule.
            Text("""
                Memoree picks one random moment inside this, each day, and \
                reminds you then. A photo taken during those two minutes grows \
                your streak; one taken at any other time is kept but does not \
                count.
                """)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            WindowPicker(
                window: $window,
                onCommit: { new in await apply(new) },
                isCommitting: isCommitting
            )

            Text(didApply ? "Applied. Tomorrow onward." : "Wider is more random.")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .animation(.default, value: didApply)
        }
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Reminders")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            // Stated as a consequence, not a warning. With no server, iOS only
            // ever asks once, so a declined permission is permanent from the
            // app's side — and the honest thing is to say what the user loses
            // rather than to imply it can be fixed here. It cannot (AGENTS.md §9).
            Text(remindersAuthorized
                ? """
                  Memoree will remind you once a day. Your phone does the \
                  asking; nothing is sent anywhere.
                  """
                : """
                  Reminders are off, so Memoree cannot tell you when your \
                  moment is. This app can only ask once, so turning them back \
                  on has to happen in the system Settings app.
                  """)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !remindersAuthorized {
                // The only amber in the app, and this is its one reserved job
                // (ADR-025): a permission the user declined and cannot fix from
                // in here.
                Button {
                    Task { await openSystemSettings() }
                } label: {
                    Text("Open Settings")
                        .font(Theme.Typography.button)
                        .foregroundStyle(Theme.Color.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.Color.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the system Settings app so you can turn on notifications for Memoree")
            }
        }
    }

    // MARK: - Permanence

    /// What deleting the app costs.
    ///
    /// The most permanent-feeling thing in the product, and it was previously
    /// documented in a PRD risk table and a Phase 10 task rather than anywhere
    /// the user would look. Memoree holds **add-only** authorisation and
    /// physically cannot delete a photograph it wrote (ADR-008) — so the split
    /// is real and asymmetric: the photos are untouchable, the archive is not.
    private var permanenceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("If you delete Memoree")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            Text("""
                Your archive and your streak are stored only on this phone, \
                inside this app. Deleting the app deletes them.

                Your photographs do not live here. They are in your Photos \
                library and Memoree never touches them — it has no permission \
                to, and never will.
                """)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Diagnostics

    /// Facts about what the app has scheduled, and the one recovery hook worth
    /// being able to reach.
    ///
    /// The camera-reset button used to live in the Today footer, behind an
    /// `.opacity` that hid it whenever there were no moments and reminders were
    /// on — an invisible but still tappable control, guarding the one failure
    /// mode that produces no error, no callback and no log line. It belongs with
    /// the other diagnostics, where being visible is the point (TRD §5.5).
    @ViewBuilder
    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Diagnostics")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textTertiary)

            MetadataRow(label: "Reminders queued", value: "\(pendingCount)")

            #if DEBUG
            Button("Reset camera services") {
                Task { await environment.simulateMediaServicesReset() }
            }
            .font(Theme.Typography.metadata)
            .foregroundStyle(Theme.Color.textSecondary)
            .accessibilityHint(
                "Rebuilds the camera session from scratch, the way iOS does after a media services reset"
            )
            #endif
        }
        .padding(.top, Theme.Spacing.l)
    }

    // MARK: - State

    @State private var pendingCount = 0

    private func reload() async {
        window = environment.momentStore.settings().timeWindow
        remindersAuthorized = await environment.notificationService
            .authorizationStatus().willDeliver
        pendingCount = await environment.notificationService.pendingCount()
    }

    /// Applies a new window and reports whether anything moved.
    ///
    /// The `isCommitting` guard is what stops a second drag from racing the
    /// first: each commit discards 44 day records and rebuilds the horizon, and
    /// two of those interleaving would leave the notification schedule describing
    /// a window the user is no longer in.
    private func apply(_ new: TimeWindow) async {
        guard !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }

        didApply = await environment.updateWindow(new)
        pendingCount = await environment.notificationService.pendingCount()
    }

    /// Opens this app's page in the system Settings app.
    ///
    /// `UIApplication.openSettingsURLString` is a local intent, not a network
    /// call, so it does not violate ADR-001. There is no deep link back —
    /// `Info.plist` registers no URL scheme, deliberately.
    @MainActor
    private func openSystemSettings() async {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        await UIApplication.shared.open(url)
    }
}
