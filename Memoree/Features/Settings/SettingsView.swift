import SwiftUI
import UIKit

/// Settings.
///
/// Four things, and the reason there are only four is that the app has one
/// preference worth having. Everything else is either a fact the user cannot
/// change, a permission the system owns, or a promise this app deliberately
/// does not make.
///
/// Reached from a gear in the Today header, presented as a **full-screen cover**.
///
/// **This comment said "sheet" for four months and was wrong.** `TodayView`
/// presents `SettingsView` with `.fullScreenCover` and explains at length why:
/// the sheet version shipped, rendered at `.medium`, and
/// `.presentationDetents([.large])` was "silently ignored in both places" before
/// the switch. Two files in the same app documenting the same decision
/// differently is how the next reader ends up trusting neither.
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

    /// Whether to also file each moment into a `Memoree` album.
    ///
    /// `@State` rather than read straight from the store, because the toggle has
    /// to reflect what was actually *written* — and the album add is a second
    /// `performChanges` after the assets exist, which can fail on its own. A
    /// toggle that reads the stored value would spring back to off after a
    /// failure with nothing on screen to say why.
    @State private var saveToAlbum = false

    /// Set when the album add failed after the photographs were already saved.
    ///
    /// Reported rather than swallowed: the photographs are safe, which is the part
    /// that matters, but the user asked for something that did not happen.
    @State private var albumFailure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    windowSection
                    remindersSection
                    exportSection
                    photosSection
                    permanenceSection
                    diagnosticsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.xl)
            }
            // The background as a `background`, not a sibling view.
            //
            // As a sibling — a `CanvasBackground()` above the `ScrollView` — the
            // scroll view got a shorter proposal than the screen and left the
            // first section floating more than half way down, with a black void
            // above it. The background claimed space that only it wanted. As an
            // actual background it is painted behind the content and competes
            // for nothing.
            .background(CanvasBackground())
            .scrollIndicators(.hidden)
            // A title and a Done button, because this screen was first built
            // with neither — which is why it wanted to be a short sheet with a
            // drag handle and nothing else. A settings screen you can only leave
            // by flicking the sheet downward is a settings screen most people
            // will not find their way out of.
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
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
                .appAnimation(didApply)
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
                        .frame(minHeight: Theme.Size.tapTargetComfortable)
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

    // MARK: - Export

    /// The whole archive as one JSON file.
    ///
    /// **In Settings rather than the archive** because it is not about a
    /// moment. It is the answer to "what happens to my archive if I lose this
    /// phone", which is the question the permanence section above raises and then
    /// leaves unanswered — and a screen that raises a fear without offering the
    /// remedy is a worse thing than one that stays silent.
    ///
    /// Stated as what it is: **a record, not a backup.** The photographs are not
    /// in the file and cannot be restored from it. That sentence is in the
    /// subtitle because a file called "export" that a user believes brings their
    /// archive back is worse than no file — they will not check.
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Your archive")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            Text("""
                A record of every moment: which day, when, and whether it grew \
                your streak. The photographs are not in it — they are already in \
                your Photos library, where any app can reach them.
                """)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let failure = exportFailure {
                Text(failure)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
            }

            if let export = preparedExport {
                ShareLink(
                    item: SharedArchiveFile.export(
                        day: exportedOn.formatted(.iso8601.year().month().day()),
                        data: export
                    ),
                    preview: SharePreview("Memoree archive")
                ) {
                    // **Outlined, not filled.** This was a solid white capsule, which is
                    // the same treatment `PrimaryButton(.filled)` gives and the
                    // app reserves for the one thing a screen wants you to do.
                    // Settings has three sections and this row is not the
                    // important one — the window and the album are. A white pill
                    // at the bottom of the screen is a button that says "this is
                    // the main event" in the only voice the design language has,
                    // and it was spending that on an export nobody opens twice.
                    //
                    // The border keeps it discoverable, which is what the weight
                    // change is at risk of: a row that recedes too far is a
                    // feature that does not exist. `Theme.Radius` already has
                    // what this needs; the outline is `textPrimary`, same as
                    // `PrimaryButton(.outlined)`.
                    Label("Export as JSON", systemImage: "square.and.arrow.up")
                        .font(Theme.Typography.button)
                        .foregroundStyle(Theme.Color.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: Theme.Size.tapTargetComfortable)
                        .overlay {
                            Capsule().strokeBorder(Theme.Color.textPrimary, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the share sheet with one JSON file of every moment")
            } else {
                // **Not a spinner.** An archive of 500 moments encodes in
                // milliseconds, and a spinner implies work that is not happening.
                // The row is simply absent until it is ready, which is immediate.
                Color.clear.frame(minHeight: Theme.Size.tapTargetComfortable).accessibilityHidden(true)
            }
        }
    }

    /// The encoded export, prepared on appear and held in memory.
    ///
    /// Never written to disk here — `SharedArchiveFile` does that when the share sheet
    /// asks, in a temporary directory (AGENTS.md §2.4).
    @State private var preparedExport: Data?
    @State private var exportFailure: String?
    @State private var exportedOn = Date()

    private func prepareExport() {
        let moments = environment.momentStore.facts()
        let export = MomentExport(moments: moments, exportedAt: Date())
        do {
            preparedExport = try MomentExporter.encode(export)
            exportFailure = nil
            exportedOn = export.exportedAt
        } catch {
            preparedExport = nil
            exportFailure = "Memoree could not prepare the export. \(error.localizedDescription)"
        }
    }

    // MARK: - Photos

    /// Whether Memoree also files each moment into an album of its own.
    ///
    /// **Off by default, and the default is the point.** The photographs are
    /// already in the user's library — that is the whole promise (ADR-001, no
    /// server, no app storage). A second copy in a Memoree album is a
    /// convenience for scrolling back, and it is the user's Photos library
    /// getting one more album they did not ask for. So the answer is no until
    /// someone says yes.
    ///
    /// **Turning it off never deletes the album.** ADR-008 forbids reaching into
    /// the library to remove anything, and an album Memoree created is now the
    /// user's to keep or delete themselves. A toggle that silently deleted things
    /// would be the single worst control in the app.
    private var photosSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Photos")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            SettingsRow(
                title: "Keep a \(CameraViewModel.albumName) album",
                subtitle: "Also file each moment into an album alongside your "
                    + "library. Turning this off never deletes anything.",
                control: {
                    Toggle(
                        "",
                        // Not `$saveToAlbum` directly: the toggle has to write
                        // through to the store, or the value survives only until
                        // the next `reload()`.
                        isOn: Binding(
                            get: { saveToAlbum },
                            set: { enabled in
                                saveToAlbum = enabled
                                applyAlbumPreference(enabled)
                            }
                        )
                    )
                    .labelsHidden()
                }
            )
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
        saveToAlbum = environment.momentStore.settings().saveToAlbum
        remindersAuthorized = await environment.notificationService
            .authorizationStatus().willDeliver
        pendingCount = await environment.notificationService.pendingCount()
        prepareExport()
    }

    /// Writes the album preference, and nothing else.
    ///
    /// **No album is created here, and none is deleted.** `albumCreationAttempted`
    /// is deliberately left alone: it guards against re-creating an album the user
    /// deleted themselves, and creating an empty album the moment somebody visits
    /// Settings to look at the toggle would be the app littering their library
    /// with a folder it has not put anything in. The album appears when the first
    /// moment is actually filed into it.
    private func applyAlbumPreference(_ enabled: Bool) {
        let settings = environment.momentStore.settings()
        settings.saveToAlbum = enabled
        try? environment.momentStore.saveSettings(settings)
        if enabled { albumFailure = nil }
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
