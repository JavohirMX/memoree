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

    // MARK: - Behind the Scenes state

    /// Mirrors `settings.btsEnabled` rather than reading the store, for the reason
    /// `saveToAlbum` does: the toggle has to reflect what was actually written, so
    /// a failed save springs back rather than showing a setting the app is not
    /// honouring.
    @State private var btsEnabled = false

    /// Mirrors `settings.saveBTS`. Distinct from `btsEnabled` — see the section.
    @State private var saveBTS = false

    /// The chosen clip length in seconds, clamped through `BTSTrim`.
    @State private var btsDuration = BTSTrim.defaultClipDuration

    /// What to say about the microphone, if anything.
    ///
    /// **`nil` in the common case, and that is deliberate.** A declined microphone
    /// is a supported state, not an error (ADR-013), so there is no amber and no
    /// dialog — but silently recording nothing forever while a toggle says it is on
    /// is its own kind of lie. One grey sentence, once, is the honest middle: the
    /// user asked for a feature, the feature is running, and it is silent.
    @State private var microphoneNote: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    windowSection
                    remindersSection
                    behindTheScenesSection
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
                .foregroundStyle(Theme.Color.textSecondary)
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
                  Memoree sends a spontaneous daily prompt, plus an evening \
                  streak-saver if you haven't captured a memory yet. Your phone \
                  does the asking; nothing is sent anywhere.
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

    // MARK: - Behind the Scenes

    /// Whether Memoree records the few seconds around a moment, and whether it
    /// keeps them.
    ///
    /// **Two toggles and a length, and each earns its place.**
    ///
    /// - *Record* decides whether a movie output is attached at all. Off means no
    ///   microphone prompt, no video written to disk, and nothing to trim.
    /// - *Keep in Photos* decides whether the trimmed clip becomes an asset in the
    ///   user's library. **Separate, because they are different promises**: someone
    ///   who wants the clip and not the photograph on their lock screen is a
    ///   perfectly ordinary person, and folding the two into one toggle would
    ///   force them to choose between a feature and half of it.
    /// - *Length* is the tail of the recording that survives the trim. **The last
    ///   N seconds, never the first** — ADR-013: the clip is the moment itself, not
    ///   the walk to the camera.
    ///
    /// ## Off by default, and the reason is the microphone
    ///
    /// Not conservatism. Turning recording on makes Memoree ask for the
    /// microphone, and a permission prompt for a feature nobody has heard of is how
    /// people say no to permissions for things they would have said yes to. The
    /// user opts in; Memoree does not ask on their behalf.
    private var behindTheScenesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Behind the Scenes")
                .font(Theme.Typography.screenTitle)
                .foregroundStyle(Theme.Color.textPrimary)

            Text("""
                Records a few seconds of video around the shutter, so you can see \
                the moment rather than only the picture. Off by default — turning \
                it on is the only thing that asks for the microphone.
                """)
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textSecondary)

            SettingsRow(
                title: "Record Behind the Scenes",
                subtitle: "Capture a short clip with every moment.",
                control: {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { btsEnabled },
                            set: { enabled in
                                btsEnabled = enabled
                                if enabled && !saveBTS {
                                    saveBTS = true
                                }
                                applyBTSPreferences(
                                    enabled: enabled,
                                    save: enabled ? saveBTS : false
                                )
                            }
                        )
                    )
                    .labelsHidden()
                }
            )

            // **Hidden rather than disabled while recording is off.** A greyed-out
            // row invites the question "what is this", and the answer — a setting
            // for a feature that is off — is not worth a line of screen. Disabling
            // it instead would be honest but would also put two dead controls on
            // the screen, which is what the album toggle's neighbour used to be.
            if btsEnabled {
                SettingsRow(
                    title: "Keep the clip in Photos",
                    subtitle: "Turning this off leaves your moments as two photographs.",
                    control: {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { saveBTS },
                                set: { enabled in
                                    saveBTS = enabled
                                    applyBTSPreferences(enabled: btsEnabled, save: enabled)
                                }
                            )
                        )
                        .labelsHidden()
                    }
                )

                SettingsRow(
                    title: "Clip length",
                    subtitle: clipLengthExplanation,
                    control: {
                        Picker("", selection: $btsDuration) {
                            ForEach(Self.clipLengths, id: \.self) { seconds in
                                Text("\(Int(seconds))s").tag(seconds)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: btsDuration) { _, newValue in
                            applyClipDuration(newValue)
                        }
                    }
                )
            }

            if let microphoneNote {
                Text(microphoneNote)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
    }

    /// The lengths offered, in seconds.
    ///
    /// **A closed list rather than a slider.** Every value between the floor and
    /// the ceiling is valid, so a slider would expose the full continuum and imply
    /// that 9.3 seconds means something different from 9 — which is not true, and
    /// is not a decision anybody wants to make. `BTSTrim.maximumClipDuration` caps
    /// the range for the same product reason it wrote down.
    private static let clipLengths: [Double] = [3, 5, 8, 10, BTSTrim.maximumClipDuration]

    /// What the chosen length will actually keep, said plainly.
    ///
    /// Because the answer is not the number: a recording shorter than the requested
    /// length keeps all of it, and one longer than the moment keeps only the tail.
    /// A row reading "Clip length: 5s" invites the reader to assume they will get
    /// exactly five seconds, and they will not if they captured fast.
    private var clipLengthExplanation: String {
        "Keeps the last \(formatted(btsDuration))."
            + " A moment you captured very quickly keeps less."
    }

    private func formatted(_ seconds: Double) -> String {
        seconds == seconds.rounded()
            ? "\(Int(seconds)) seconds"
            : String(format: "%.1f seconds", seconds)
    }

    /// Writes the two BTS toggles in one place.
    ///
    /// **One function rather than two**, because they are written together and read
    /// together — `CameraHostView`'s `shouldSaveBTS` requires both — and a screen
    /// that could persist one without the other is a screen that can produce a
    /// state the rest of the app has no meaning for.
    private func applyBTSPreferences(enabled: Bool, save: Bool) {
        let settings = environment.momentStore.settings()
        settings.btsEnabled = enabled
        settings.saveBTS = save
        try? environment.momentStore.saveSettings(settings)
        refreshMicrophoneNote()
    }

    /// Clamped on write, not only on read.
    ///
    /// `CameraViewModel` clamps again through `BTSTrim.validatedClipDuration`, and
    /// that is the guard that matters — a store can be corrupt, hand-edited, or
    /// migrated. Clamping here as well means the value on disk is one the app would
    /// have chosen, so a reader of the database is not misled about what was
    /// asked for.
    private func applyClipDuration(_ seconds: Double) {
        let clamped = BTSTrim.validatedClipDuration(seconds)
        let settings = environment.momentStore.settings()
        settings.btsDuration = clamped
        try? environment.momentStore.saveSettings(settings)
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
                .foregroundStyle(Theme.Color.textSecondary)

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
        let settings = environment.momentStore.settings()
        window = settings.timeWindow
        saveToAlbum = settings.saveToAlbum
        // **Clamped on read, not only on write.** A store can be corrupt or
        // migrated, and a picker showing a value the recorder would refuse is a
        // control describing something that will not happen.
        btsDuration = BTSTrim.validatedClipDuration(settings.btsDuration)
        btsEnabled = settings.btsEnabled
        saveBTS = settings.btsEnabled && settings.saveBTS
        remindersAuthorized = await environment.notificationService
            .authorizationStatus().willDeliver
        pendingCount = await environment.notificationService.pendingCount()
        refreshMicrophoneNote()
        prepareExport()
    }

    /// Says what the microphone is doing, and only when it is doing something
    /// other than the expected thing.
    ///
    /// **Three states, two of them silent.** Not asked yet means the prompt is
    /// still coming and there is nothing true to say; authorised means silence;
    /// denied and restricted are the two the user should hear about, because both
    /// produce clips with no sound and neither is visible anywhere else.
    ///
    /// **Read from `AVCaptureDevice` through the recorder**, so this screen does
    /// not import AVFoundation (`AGENTS.md` §3) and the answer cannot drift from
    /// what the recorder will actually do.
    private func refreshMicrophoneNote() {
        guard btsEnabled, let recorder = environment.btsRecorder else {
            microphoneNote = nil
            return
        }
        switch recorder.microphoneStatus() {
        case .notDetermined, .authorized:
            microphoneNote = nil
        case .denied:
            microphoneNote = "Memoree does not have microphone access, so clips will "
                + "be silent. You can change this in Settings."
        case .restricted:
            microphoneNote = "Microphone access is blocked on this device, so clips "
                + "will be silent."
        }
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
