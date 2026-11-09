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

    /// In-flight window commit task for debouncing rapid stepper adjustments.
    @State private var windowCommitTask: Task<Void, Never>?

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

    /// Whether notifications are enabled by the user in-app.
    @State private var notificationsEnabled = true

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
        .onDisappear {
            windowCommitTask?.cancel()
            let finalWindow = window
            Task {
                await environment.updateWindow(finalWindow)
            }
        }
    }

    // MARK: - Window

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SettingsSectionHeader("Daily Window", icon: "clock")

            SettingsCard {
                // Explains the mechanic per ADR-023, ADR-032, and ADR-036:
                // capturing is permitted at any time, every memory counts,
                // and the window decides the spontaneous prompt.
                Text("Random daily prompt inside this window. Capture anytime — every day counts.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsDivider()

                WindowPicker(
                    window: $window,
                    onCommit: { new in await apply(new) }
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
                SettingsRow(
                    title: "Daily Reminders",
                    subtitle: remindersAuthorized
                        ? "Spontaneous daily prompt and 21:00 streak saver."
                        : "Notifications are turned off in system Settings.",
                    control: {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { notificationsEnabled && remindersAuthorized },
                                set: { enabled in
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    Task { await handleNotificationToggle(enabled) }
                                }
                            )
                        )
                        .labelsHidden()
                        .disabled(!remindersAuthorized && notificationsEnabled)
                    }
                )

                if !remindersAuthorized {
                    SettingsDivider()

                    Text("Notifications are off in iOS Settings. Memoree can only ask once — turn them back on in system Settings.")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

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
                } else {
                    SettingsDivider()

                    Text(notificationsEnabled
                        ? "Scheduled on-device only. Capture anytime — every day counts."
                        : "Reminders are paused. You can still capture anytime on the Today screen.")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                Text("JSON of dates and streak facts. Photos stay in your library — this is a record, not a restore.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("About export") {
                    Text("The file cannot rebuild your photographs. It only lists what Memoree remembers about each moment.")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Spacing.xs)
                }
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textSecondary)
                .tint(Theme.Color.textSecondary)

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
                Text("Short clip around the shutter. Off by default — enabling asks for the microphone.")
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

    private func handleNotificationToggle(_ enabled: Bool) async {
        let status = await environment.notificationService.authorizationStatus()
        if enabled {
            if status == .notDetermined {
                let granted = await environment.notificationService.requestAuthorization()
                remindersAuthorized = granted
                if granted {
                    notificationsEnabled = true
                    updateNotificationSetting(true)
                    await environment.refreshHorizonIfNeeded(force: true)
                } else {
                    notificationsEnabled = false
                    updateNotificationSetting(false)
                }
            } else if status.willDeliver {
                notificationsEnabled = true
                remindersAuthorized = true
                updateNotificationSetting(true)
                await environment.refreshHorizonIfNeeded(force: true)
            } else {
                notificationsEnabled = false
                remindersAuthorized = false
            }
        } else {
            notificationsEnabled = false
            updateNotificationSetting(false)
            await environment.notificationService.clearAll()
        }
        pendingCount = await environment.notificationService.pendingCount()
    }

    private func updateNotificationSetting(_ enabled: Bool) {
        let settings = environment.momentStore.settings()
        settings.notificationsEnabled = enabled
        try? environment.momentStore.saveSettings(settings)
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

                // Same copy Today shows in its footer: photographs are safe; the
                // album add is what failed. Grey, not amber — this is not a
                // declined permission (ADR-025), and not a destructive confirm.
                if let albumFailure {
                    SettingsDivider()

                    Text(albumFailure)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.albumFailure")
                }

                SettingsDivider()

                DisclosureGroup("About Photos permission") {
                    Text("Add-only access. Memoree never deletes from Photos. Your pictures stay if you delete the app.")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Theme.Spacing.xs)
                }
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.Color.textSecondary)
                .tint(Theme.Color.textSecondary)
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

                Button {
                    Task { await environment.simulateMediaServicesReset() }
                } label: {
                    Text("Reset camera services")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: Theme.Size.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
        notificationsEnabled = settings.notificationsEnabled ?? true
        remindersAuthorized = await environment.notificationService
            .authorizationStatus().willDeliver
        pendingCount = await environment.notificationService.pendingCount()
        momentsCount = environment.momentStore.allMoments.count
        // Peek, do not consume: Today shows the same note in its footer, and a
        // one-shot handoff would race whichever screen reloads first. Cleared
        // when the album preference changes.
        albumFailure = environment.albumFailureNote
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
        // Preference changed: the failed ask is either withdrawn (off) or about
        // to be retried on the next capture (on). Either way the note is stale.
        environment.clearAlbumFailure()
        albumFailure = nil
    }

    /// Applies a new window with a short debounce to avoid churning the
    /// 45-day notification horizon during rapid stepper adjustments.
    private func apply(_ new: TimeWindow) async {
        windowCommitTask?.cancel()
        windowCommitTask = Task {
            // Short debounce so consecutive taps accumulate smoothly
            // without locking or dimming the controls.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            let applied = await environment.updateWindow(new)
            if !Task.isCancelled {
                didApply = applied
                pendingCount = await environment.notificationService.pendingCount()
            }
        }
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
