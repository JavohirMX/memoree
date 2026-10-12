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
                    behindTheScenesSection
                    photosSection
                    remindersSection
                    exportSection
                    diagnosticsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.l)
            }
            .background(CanvasBackground())
            .scrollIndicators(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { dismiss() }
                }
            }
        }
        .task { await reload() }
    }

    // MARK: - Window

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SettingsSectionHeader("Daily Window", icon: "clock")

            SettingsCard {
                // Explains the mechanic per ADR-023, ADR-032, and ADR-036:
                // capturing is permitted at any time, every memory counts,
                // and the window decides the spontaneous prompt.
                Text("""
                    Memoree picks one random moment inside this window each day \
                    and sends a spontaneous prompt. You can capture memories at \
                    any time—every memory counts toward your streak.
                    """)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsDivider()

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
    }

    // MARK: - Reminders

    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SettingsSectionHeader("Notifications", icon: "bell")

            SettingsCard {
                // Stated as a consequence, not a warning (ADR-036).
                Text(remindersAuthorized
                    ? """
                      Memoree sends a spontaneous daily prompt, plus an evening \
                      streak-saver reminder at 21:00 if you haven't captured a \
                      memory yet. Your phone does the scheduling; nothing is \
                      sent over the network.
                      """
                    : """
                      Notifications are off, so Memoree cannot alert you when \
                      your spontaneous moment arrives. This app can only ask \
                      once, so re-enabling them has to happen in the system \
                      Settings app.
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
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SettingsSectionHeader("Archive & Data", icon: "archivebox")

            SettingsCard {
                Text("""
                    A complete record of every moment: dates, timestamps, and \
                    streak status. The photographs are not in it—they already live \
                    in your Photos library.
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
                    // Not a spinner. Encoding is immediate.
                    Color.clear.frame(minHeight: Theme.Size.tapTargetComfortable).accessibilityHidden(true)
                }
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
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SettingsSectionHeader("Behind the Scenes", icon: "video")

            SettingsCard {
                Text("""
                    Records a few seconds of video around the shutter, so you can see \
                    the moment rather than only the picture. Off by default—turning \
                    it on is the only thing that asks for the microphone.
                    """)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Color.textSecondary)

                SettingsDivider()

                SettingsRow(
                    title: "Record Behind the Scenes",
                    subtitle: "Capture a short clip with every moment.",
                    control: {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { btsEnabled },
                                set: { enabled in
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

                // Hidden rather than disabled while recording is off.
                if btsEnabled {
                    SettingsDivider()

                    SettingsRow(
                        title: "Keep the clip in Photos",
                        subtitle: "Turning this off leaves your moments as two photographs.",
                        control: {
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { saveBTS },
                                    set: { enabled in
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        saveBTS = enabled
                                        applyBTSPreferences(enabled: btsEnabled, save: enabled)
                                    }
                                )
                            )
                            .labelsHidden()
                        }
                    )

                    SettingsDivider()

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
                                UISelectionFeedbackGenerator().selectionChanged()
                                applyClipDuration(newValue)
                            }
                        }
                    )
                }

                if let microphoneNote {
                    SettingsDivider()

                    Text(microphoneNote)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textSecondary)
                }
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
    // MARK: - Photos & Library

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SettingsSectionHeader("Photos & Library", icon: "photo.on.rectangle")

            SettingsCard {
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
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    saveToAlbum = enabled
                                    applyAlbumPreference(enabled)
                                }
                            )
                        )
                        .labelsHidden()
                    }
                )

                SettingsDivider()

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Permanence")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Color.textPrimary)

                    Text("""
                        Memoree holds add-only permission. It never deletes from \
                        your Photos library, and all photographs remain in your \
                        library even if you delete the app.
                        """)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - About & Diagnostics

    @ViewBuilder
    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SettingsSectionHeader("About & Diagnostics", icon: "info.circle")

            SettingsCard {
                MetadataRow(label: "Version", value: appVersionString)
                MetadataRow(label: "Moments in archive", value: "\(momentsCount)")
                MetadataRow(label: "Reminders queued", value: "\(pendingCount)")

                #if DEBUG
                SettingsDivider()

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
        }
    }

    // MARK: - State

    @State private var pendingCount = 0
    @State private var momentsCount = 0

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

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
        momentsCount = environment.momentStore.allMoments.count
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
