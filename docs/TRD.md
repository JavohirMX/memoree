# Memoree — Technical Requirements & Design

**Status:** Draft v1 · **Date:** 2026-09-30 · **Target:** iOS 17.0+, Swift 6, SwiftUI

---

## 1. Environment

| Component | Version | Status |
| --- | --- | --- |
| macOS | 27.0 (26A428) | available |
| Xcode | 27.0 at `/Applications/Xcode.app` | installed |
| iOS SDK | 27.0 | available |
| Command Line Tools | 15-series at `/Library/Developer/CommandLineTools` | superseded |
| Swift | 6.4 | available |

`xcode-select` must point at Xcode, not the CommandLineTools. This is not optional and not
cosmetic, and it fails in a way that looks like something else:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcode-select -p                  # must print /Applications/Xcode.app/Contents/Developer
xcodebuild -version              # must report Xcode 27.0
xcrun --sdk iphoneos --show-sdk-path
```

**Setting `DEVELOPER_DIR` is not a substitute.** It makes `xcodebuild` itself find the right
toolchain, but `xcodebuild` then shells out to `xcrun`, and `xcrun` resolves its utilities
through `xcode-select` — so any command that shells out fails with
`xcrun: error: unable to find utility "devicectl", not a developer tool or in PATH`. That
message names a missing tool rather than a misconfigured selector, which is why it is worth
recording: the fix is the `sudo` line above, not a `PATH` tweak.

Two consequences, both observed on this machine:

- **SwiftLint does not run** without it. The Homebrew binary resolves `sourcekitdInProc`
  through the active developer dir and crashes on startup otherwise, so
  `swiftlint lint` failing was a toolchain symptom, not a broken install.
- **Device tests cannot run** without it, for the `devicectl` reason above.

Also required before the first device build: launch Xcode once and accept the licence, then
set the development team under Signing & Capabilities.

### The development team

`DEVELOPMENT_TEAM` must be the `OU` of the local **Apple Development** certificate — the
signing team — and not the ten-character identifier in the certificate's common name. Those
are the same value for organisation teams and different for individual ones, so copying the
value out of the certificate's subject line produces a team Xcode has no account for:

```
No Account for Team "…". Add a new account in Accounts settings…
```

A wrong value here cannot be worked around by passing `-allowProvisioningUpdates`; the flag
only permits profile generation for a team Xcode already holds credentials for.

Also required before the first device build: launch Xcode once and accept the licence, then
set the development team under Signing & Capabilities.

## 2. Repository layout

```
Memoree/
├── AGENTS.md
├── README.md
├── LICENSE                        # MIT
├── project.yml                    # XcodeGen spec (source of truth)
├── Memoree.xcodeproj/             # committed so the tool is optional
├── docs/
│   ├── PRD.md
│   ├── TRD.md
│   ├── IMPLEMENTATION_PLAN.md
│   └── DECISION_LOG.md
├── Memoree/
│   ├── App/
│   │   ├── MemoreeApp.swift
│   │   ├── AppEnvironment.swift
│   │   └── RootView.swift
│   ├── DesignSystem/
│   │   ├── Theme.swift            # palette, spacing, radii, type ramp
│   │   └── Components/            # buttons, cards, composite, badges
│   ├── Models/
│   │   ├── Models.swift           # Moment, DayRecord, AppSettings
│   │   ├── MomentFacts.swift      # Sendable streak/stats snapshots
│   │   ├── ArchiveSection.swift   # month grouping for Archive
│   │   └── SameDayFlipbook.swift  # this-day-across-years selection (ADR-038)
│   ├── Persistence/
│   │   ├── Persistence.swift
│   │   └── MomentStore.swift      # @MainActor, the only write path
│   ├── Services/
│   │   ├── Scheduler/
│   │   │   ├── MomentScheduler.swift
│   │   │   ├── LocalMomentScheduler.swift
│   │   │   └── NotificationService.swift
│   │   ├── Capture/
│   │   │   ├── CapturePhotoService.swift
│   │   │   ├── CaptureFormatSelector.swift
│   │   │   ├── CaptureSessionController.swift
│   │   │   ├── SequentialCaptureService.swift
│   │   │   ├── InMemoryCaptureService.swift
│   │   │   └── BTSRecorder.swift
│   │   ├── PhotoLibrary/
│   │   │   ├── PhotoLibraryService.swift
│   │   │   ├── PhotoKitLibrary.swift
│   │   │   └── ArchiveThumbnailCache.swift
│   │   └── Streaks/
│   │       └── StreakCalculator.swift
│   ├── Features/
│   │   ├── Onboarding/
│   │   ├── Today/
│   │   ├── Camera/
│   │   ├── Archive/               # grid, calendar, MomentDetailView
│   │   ├── Stats/
│   │   ├── Settings/
│   │   ├── Share/                 # exporter + share sheet
│   │   └── BTS/                   # BTSPlaybackView (sole AVKit Features exception)
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   ├── Info.plist
│   │   └── PrivacyInfo.xcprivacy
│   └── Support/
│       ├── DayIdentifier.swift
│       ├── TimeWindow.swift
│       ├── CountdownFormatter.swift
│       ├── CaptureMomentIntent.swift
│       ├── WidgetSnapshot*.swift      # App Group snapshot (ADR-040)
│       └── WidgetCameraHandoff.swift
├── MemoreeWidget/                     # WidgetKit extension (ADR-040)
│   ├── MemoreeWidget.swift            # small + medium, layout-is-state
│   ├── WidgetTheme.swift
│   ├── Info.plist
│   └── MemoreeWidget.entitlements
└── MemoreeTests/
    ├── …
```


**Layering rule.** `Features/` may import `Models/`, `Persistence/`, `DesignSystem/`.
`Services/` may import `Models/` and `Support/`. Nothing imports `Features/`. Services are
protocols so that every one has a test double. This is what makes NFR-9 and NFR-10 real
rather than aspirational.

**XcodeGen.** `project.yml` is the source of truth; the `.xcodeproj` is committed so that
contributors without XcodeGen can still open and build the project. Regenerate with
`xcodegen generate` after any target or setting change.

## 3. Domain model

SwiftData. No third-party persistence: the data set is one user, a few thousand rows, entirely
local, with no migration pressure that would justify a dependency.

```swift
@Model final class Moment {
    @Attribute(.unique) var id: UUID
    var dayIdentifier: String        // "2026-09-30" in the device's current timezone
    var momentStart: Date            // the random daily window start
    var windowEndsAt: Date           // momentStart + 120s
    var capturedAt: Date             // shutter time of the accepted capture
    var isLate: Bool
    var lateBy: TimeInterval         // 0 when on time
    var retakeCount: Int
    var hasLocation: Bool
    var latitude: Double?
    var longitude: Double?
    var note: String?                // Q1, optional
    var hasBTS: Bool

    // Photos-library references. NO image bytes are stored by Memoree.
    var backAssetIdentifier: String?     // PHAsset.localIdentifier
    var frontAssetIdentifier: String?
    var btsAssetIdentifier: String?

    var isDeleted: Bool             // tombstone; the Photos asset is intentionally left alone
    var deletedAt: Date?
}

@Model final class DayRecord {
    @Attribute(.unique) var dayIdentifier: String
    var momentStart: Date
    var notificationIdentifier: String?
}

@Model final class StreakRecord {
    @Attribute(.unique) var id: String     // "current" | "longest"
    var value: Int
    var startedAt: Date?
    var endedAt: Date?
}

@Model final class AppSettings {
    @Attribute(.unique) var id: String     // singleton
    var windowStartMinutes: Int      // minutes from local midnight, default 11*60
    var windowEndMinutes: Int        // default 23*60
    var windowDuration: Int          // capture window seconds, default 120
    var btsEnabled: Bool             // default true
    var btsDuration: Double          // seconds retained, default 5.0
    var saveToAlbum: Bool            // default false  (Q4)
    var saveBTS: Bool                // default true
    var albumCreationAttempted: Bool
    var onboardingComplete: Bool
}
```

`dayIdentifier` is a **local calendar date string in the device's current timezone**, not a UTC
date. This is the single most important modelling decision in the app: it means a moment is
attached to the day the *user* experienced it, which is what a streak means to a human.

**Multi-capture (ADR-030).** Users can take multiple memories per day using "Capture again".
`Moment.dayIdentifier` is non-unique so subsequent captures append rather than overwrite
or soft-delete previous captures. Day records remain unique, and streak calculations count
days with at least one capture of any kind (ADR-032).

## 4. The moment scheduler

### 4.1 Deriving the daily time

The moment time must be (a) random, (b) **stable for the whole day**, and (c) stable across
launches, foregrounds and clock changes. Re-rolling on every launch would make the countdown
nonsensical; re-rolling from wall-clock time would break when the device clock ticks.

```swift
func momentStart(forDay day: DayIdentifier, settings: AppSettings, secret: SymmetricKey) -> Date {
    let message = Data("\(secretSeed)|\(day.rawValue)|\(settings.windowStartMinutes)-\(settings.windowEndMinutes)|\(settings.windowDuration)".utf8)
    let digest = HMAC<SHA256>.authenticationCode(for: message, using: secret)
    var bytes = Array(digest)
    let fraction = Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / Double(UInt64.max)
    let span = Double(settings.windowEndMinutes - settings.windowStartMinutes) * 60
    let offset = (fraction * span).rounded(.down)
    return calendar.date(byAdding: .second, value: Int(offset), to: calendar.startOfDay(for: day.date))!
        .advanced(by: settings.windowStartMinutes * 60)
}
```

`secret` is a 32-byte random key generated once per install and stored in the **Keychain**
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). It is not `NSUserDefaults` — losing it
must not silently change every historical moment time, which is what `UserDefaults` gives you
for free.

The derivation is **pure**: same inputs, same output. That makes it unit-testable against
golden vectors, which is the cheapest possible test of the riskiest logic in the app.

The resolved value is **also persisted** into `DayRecord` on first resolution. The persisted
value always wins. Belt and braces: if the user changes their moment window on day *N*, day
*N*'s already-resolved moment is left alone and the new window applies from day *N+1*. This
prevents a scheduled notification from being invalidated after the fact.

### 4.2 Validation

- `windowEndMinutes > windowStartMinutes`, else clamp to a 1-hour default.
- `windowEndMinutes <= 24 * 60`. 1440 means end-of-day.
- `windowStartMinutes >= 0`.
- Span must be at least 60s; otherwise there is no meaningful randomness.

### 4.3 Scheduling notifications

Horizon: **45 days** for spontaneous moments plus a **7-day rolling window** for evening streak-saver reminders, totaling ~52 requests comfortably inside the documented 64-request pending limit. Refill when `pendingNotificationRequests().count < 20`, checked on launch, on `scenePhase == .active`, and after any accepted moment.

```swift
let prompt = MomentNotificationCopy.prompt(for: day)
let content = UNMutableNotificationContent()
content.title = prompt.title
content.body  = prompt.body
content.sound = .default
content.interruptionLevel = .active

var comps = DateComponents()
comps.year = d.year; comps.month = d.month; comps.day = d.day
comps.hour = d.hour; comps.minute = d.minute; comps.second = 0

let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
try await center.add(UNNotificationRequest(
    identifier: "moment.\(day.rawValue)",
    content: content, trigger: trigger))
```

**Pressure-free copy.** Per ADR-023, ADR-032, and ADR-036, moment captures carry no artificial time limit. Copy avoids phrases like "2 minutes left" and instead deterministically rotates playful, encouraging prompts (e.g. "What are you up to right now? 👀", "Time to make a Memoree 📸") keyed to each day's identifier.

**Streak-saver reminders.** If a user has not captured a moment by 21:00 local time, a secondary reminder fires: *"Keep your streak going! 🔥 You haven't captured a memory today yet. Take a moment before the day ends!"* As soon as a moment is captured on a day, its pending streak-saver reminder is immediately canceled.

**Why wall-clock components rather than a time interval.** A `UNTimeIntervalNotificationTrigger`
fires 45 × 86400 seconds after scheduling — which drifts against DST and against the device
traveling between timezones. `UNCalendarNotificationTrigger` with explicit components resolves
against the *current* timezone at fire time, which is the correct semantic for "at 14:37 on
30 September". This is a real correctness decision, not a style preference.

**DST.** If the resolved moment lands in a spring-forward gap, iOS fires at the first valid
instant after the gap. Calendar triggers resolve against the current timezone at trigger time.

**Identifier discipline.** `moment.<dayIdentifier>` for daily prompts and `streak.<dayIdentifier>` for evening reminders. On re-resolve, `removePendingNotificationRequests` with specific identifiers before re-adding. Never call `removeAllPendingNotificationRequests()` — it would also clear permission-related and future-scheduled items.

## 5. Capture

### 5.1 Decision: sequential, not multi-cam

`AVCaptureMultiCamSession` was evaluated and rejected (ADR-003). BeReal's own client appears to
be sequential — user reports describe "whichever camera takes a picture second ends up really
dark", which is the classic symptom of reconfiguring a single session. Matching that has three
advantages: it works on every iPhone back to iPhone 6s, it is testable under a simulator's
constraints, and it avoids the multi-cam thermal and `hardwareCost` budget entirely.

### 5.2 Session architecture

One `AVCaptureSession`, owned by a dedicated `DispatchQueue(label: "capture.session")`.
**Nothing on this queue is `@MainActor`.** UI reads published state; the session never touches
SwiftUI.

```swift
final class CaptureSessionController: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "capture.session")
    private let output = AVCapturePhotoOutput()
    private var currentPosition: AVCaptureDevice.Position = .back
    private(set) var state: State = .idle
}
```

### 5.2.1 The sequence is the user's

**Two shutter presses, two photographs (ADR-021).** The second press is what
switches the camera, and the opening camera is random per moment.

The camera screen opens on one camera. The first press photographs it, and the
other camera then comes up while the photograph just taken sits in the top-left
square. The second press photographs that one, and the moment moves to review.

The service therefore answers one question at a time — `startSession(on:)`,
`captureCurrentPhoto()`, `switchCamera(to:)` — and the view model owns the order.
There is deliberately no `capturePair()`: a single call that captures both halves
would hide the swap, which is a user-visible event, and would make "reshoot just
this one half" inexpressible.

Internally, the swap is:

```
1. session.beginConfiguration()
2. session.removeInput(currentInput)
3. guard session.canAddInput(newInput)          // NO if checked while the old
4. session.addInput(newInput)                   // input is still attached
5. session.commitConfiguration()
6. re-apply the 3:4 activeFormat to the new device
7. await first delivered frame from the new input
```

**Steps 3 and 4 have two constraints, and both were violated before one was
satisfied.** `canAddInput` must be called *inside* `beginConfiguration` — outside
it, while the session is running, it returns NO for the front camera every time.
It must also be called *after* `removeInput`: a session already holding one video
input will not accept a second from a different device, so checking first
returns NO every time. Both arrangements were shipped by accident and both
reported `noInputAvailable(.front)` twenty times out of twenty on a real device.

Step 7 is not optional. Capturing before the front sensor has delivered a frame yields a black
or green image. Implement as a `CheckedContinuation` fed by
`AVCaptureVideoDataOutput` — or, cheaper, by polling
`session.connections.filter { $0.isEnabled }.isEmpty == false` plus a short settle delay.
Prefer the real frame signal; a fixed sleep is the first thing that will flake.

**How the delivered frame is identified.** By `AVCaptureConnection.inputPorts` — the port of
the input actually attached *now* — rather than by a generation counter. A counter read on the
delivery callback is not sufficient, and the reason is worth stating because the failure is
silent: a frame from the outgoing camera, already in flight when the swap happened, is delivered
afterwards, and by then the counter reads the *new* generation. The stale frame is therefore
accepted and the front photo comes out black — the exact failure the sleep was meant to prevent,
arriving through a different door. Port identity does not change retroactively, so a frame from
the removed camera is recognised however late it arrives.

### 5.3 Format selection

Neither `.photo` nor any other `sessionPreset` is reliable across a mid-session input swap.
Use `.inputPriority` and set `activeFormat` explicitly.

```swift
let targetRatio: Double = 3.0 / 4.0   // BeReal's published geometry
let best = device.formats
    .filter { $0.isFormatSampleRateAndResolutionSupported(60) }
    .filter { CMVideoFormatDescriptionGetDimensions($0.formatDescription) is 3:4 within 0.02 }
    .max { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
         < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width }
```

3:4 portrait matches BeReal's own published ad spec (rear 768×1024, front inset 234×314) and
matches what the camera roll is overwhelmingly full of, so assets sit naturally in the library.

**Zoom / lenses.** The rear prefers `.builtInDualWideCamera` when it offers 3:4, and selects
0.5× / 1× / 2× via `videoZoomFactor` (native UW → switch-over wide → 2× on wide). The front
offers 0.5× and 1× only: 0.5× attaches `.builtInUltraWideCamera` (discovery fallback if
`default` is nil; **never** a silent wide stand-in), 1× re-attaches `.builtInWideAngleCamera`
(bidirectional). UW format selection prefers the widest `videoFieldOfView` among 3:4
candidates so a max-pixel centre crop does not erase the ultra-wide look. Physical lenses
park at `minAvailableVideoZoomFactor` (the button chooses the device, not a DualWide
multiplier). Remembered rear 2× applies as 1× on the front (`CameraZoom.effective`).
DualWide absent: rear 0.5× is refused. Front lens changes wait for a delivered frame and
pause BTS around the stop.

Set `photoOutput.maxPhotoDimensions` to the chosen format's dimensions (this replaces the
deprecated `isHighResolutionPhotoEnabled` on iOS 16+). Set
`photoQualityPrioritization = .speed` — latency matters inside a two-minute window and there
is no benefit to `.quality` here.

### 5.3a Live preview geometry

The camera preview is a **3:4 viewport** fitted inside the available layout (canvas
letterboxing around it), not a full-bleed fill of the phone screen. The still is
encoded 3:4; filling a taller screen with `resizeAspectFill` cropped the left and
right of that frame, so ultra-wide looked tighter in preview than in the saved
photo. Matching review/composite aspect keeps compose ≈ capture.

**Front↔rear handoff.** The session must stop to swap inputs (ADR-003). The UI
does not label that freeze as "Capturing…" / "Switching camera…". Instead
`cameraSwitchDegrees` runs a full directional Y-flip (fold to ±90°, snap to the
opposite edge, unfold to 0) while `isCameraSwitching` keeps dim/blur/scale on
the card. `switchCamera` starts in the same turn as the fold — no animation
sleep before the reconfigure. Blur clears only when the new camera is ready and
the card unfolds. Reduce Motion hard-cuts the cover. The shutter flash still
marks the photograph itself.

### 5.4 Front-camera mirroring

Set on the connection, not by transforming pixels:

```swift
let connection = output.connection(with: .video)
if currentPosition == .front { connection?.isVideoMirrored = true }
```

`fileDataRepresentation()` reflects connection mirroring, so the saved asset is already correct.
Mirroring the front image is what makes a selfie read as a mirror rather than a photograph of
a photograph. BeReal does this; getting it wrong is instantly visible.

### 5.5 Errors to handle

| Condition | Response |
| --- | --- |
| `AVCaptureSessionRuntimeError` | Surface a recoverable error state; offer retry |
| `AVCaptureSessionWasInterrupted` / `InterruptionEnded` | Pause UI, resume on end |
| `mediaServicesWereReset` | **Silent and lethal** — no error is raised, the preview just freezes. Tear down and rebuild the entire session |
| `.thermalState == .critical` | Block capture with an explanatory state |
| Device storage full | Fail the Photos write; keep the moment in a pending-save state and retry |
| Input unavailable (camera in use by another app) | Explicit error state, not a silent hang |

`mediaServicesWereReset` deserves its own test hook. It produces no log line and no callback;
it is the single most common cause of "my camera app froze" in the field.

### 5.6 Composite preview

BeReal's geometry, from their published ad guidelines:

- Rear: full-bleed, 3:4
- Front: inset, top-left, **14pt corner radius**, overlapping the rear
- Tap the inset to swap which is primary

**Which photograph is "primary" is random per moment** (ADR-021), so the large
one is whichever the user shot second — the one they were looking at when they
finished.

Two states, and they are not the same screen:

- **Shooting.** The large view is the *live* camera; the photograph already taken
  sits in the inset. The inset is **not tappable** here: the large view has to
  stay live, because it is what the user is composing with. Promoting the inset
  would cover the camera they are about to shoot.
- **Review.** Both slots are photographs. Tapping the small one promotes it and
  the other drops into the square.

Reshooting a single half is a separate control, not a tap target, because that
tap is already taken by swapping. Overloading one target with two meanings makes
the common action unpredictable.

Implemented as a ZStack in SwiftUI over the two `UIImage`s. The composite is **only** rendered
on demand for sharing (FR-14); it is never written to Photos, because the user chose two
separate assets.

### 5.7 Behind the Scenes

BTS records **both cameras sequentially** (ADR-035, superseding ADR-013's single-camera limit):
the first camera is recorded while the user composes and shoots photo 1; during the camera swap,
the recorder pauses the first segment, resumes on the second camera, and records the second
segment until photo 2 is captured.

At commit, the segments are stitched together end-to-end using `AVMutableComposition` and trimmed to the user-configured clip duration (default 5s, split evenly across segments with borrowing for shorter segments) via `AVAssetExportSession`, standardized to portrait 3:4 Full HD (1080×1440) using uniform aspect-preserving transforms to eliminate lag and prevent distortion. If composition fails, passthrough export serves as a safety fallback.

Audio requires the microphone permission **and** an `AVCaptureDeviceInput` for `.audio` on the
same `AVCaptureSession` as the movie output. `AVAudioSession` alone does not put a track on the
file. Request mic access lazily, only when BTS is enabled for the first time;
`CaptureSessionController.syncAudioInput(authorized:)` attaches (or removes) the mic input
before recording starts. Mic denied, missing device, or `canAddInput == false` yields a silent
clip rather than blocking the moment (ADR-013). Camera swaps tear down only the video input —
audio survives rear↔front. Mute still defaults on at playback (ADR-039).

#### Ordering: the output is asked for before the session, the recording after

`CaptureSessionController` attaches a movie output only to sessions configured **after**
`wantsMovieOutput` is set, and re-attaching one to a live session means another
`beginConfiguration` cycle on a subsystem this project has measured as fragile. So
`CameraViewModel` calls `CapturePhotoService.enableMovieOutput()` *before* `startSession` and
`BTSRecorder.startRecording()` *after* it, from two separate methods because one of them has a
precondition the other cannot have.

The failure when this is wrong is invisible. `LiveBTSRecorder` throws `outputUnavailable`,
ADR-013's design swallows it, and the app shows BTS as on while recording nothing, forever.
`InMemoryCaptureService`'s event log is what makes the order assertable at all.

#### Discarding, and why `abandon()` exists

A re-take, a start-over, and leaving the camera all discard the recording —
`BTSRecorder.abandon()`, which cannot throw. `try? stopRecording()` followed by `discard` looks
equivalent and is not: when the stop throws — which is what ADR-027's session rebuild causes —
the recording's path is never handed back, so the bytes cannot be released *and* `isRecording`
stays `true`, which makes every later `startRecording` throw `alreadyRecording`. Swallowed, the
symptom is "BTS stopped working" with nothing to report.

#### Playback and Photos Library Storage

When writing the BTS clip to Photos, `PhotoKitLibrary.saveBTS` writes to a temporary file URL and
uses `PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL:)` to guarantee valid asset
creation. When saving to the user's `Memoree` album, the saved BTS video asset is filed alongside
the photo pair.

`PhotoLibraryService.btsClipFile(for:)` sanitizes the `PHAsset.localIdentifier` (substituting `/` with
`_` to prevent invalid nested filesystem paths) and writes the clip to a temporary file via
`PHAssetResourceManager.writeData(for:toFile:)`. `BTSPlaybackView` plays it with an `AVPlayer`.
Playback is reachable from both the Archive's Moment Detail view and directly from the Home feed
cards via a BTS header pill button and the card's context menu. Play/pause and mute only — no scrubber,
no volume, no full screen. Mute is on by default; Memoree is opened in queues and lectures.

**Reduce Motion (ADR-039).** When `@Environment(\.isReduceMotionEnabled)` is true,
`BTSPlaybackMotionPolicy` disables autoplay-on-load and end-of-item looping. The clip loads paused;
the user taps to play; when the item ends it seeks to the start and waits. When the setting is off,
autoplay and loop remain. Mute still defaults on either way. The policy is a pure value tested
without driving `AVPlayer`.

Playback is the one thing under `Features/` that imports AVFoundation or AVKit (ADR-029). The
`NoNetworkingTests` scan is why the local read uses `FileManager.contents(atPath:)` rather than
`Data(contentsOf:)`, and why both source scans strip comments: a guard that fires on prose gets
worked around by deleting the prose.

## 6. Photos library

### 6.1 Permission

**Add-only.** Request `PHPhotoLibrary.authorizationStatus(for: .addOnly)` and
`requestAuthorization(for: .addOnly)`.

```swift
// Info.plist
NSPhotoLibraryAddUsageDescription =
  "Memoree saves each moment you capture to your photo library. It never reads your library."
NSPhotoLibraryUsageDescription =   // required for .addOnly on iOS 14+
  "Memoree needs to add the moments you capture to your photo library."
```

Memoree never calls `requestAuthorization(for: .readWrite)` and never enumerates the library
except for the specific asset identifiers it already owns. The privacy claim in
`NSPhotoLibraryAddUsageDescription` is literally true, and the app should be written so that it
stays true.

### 6.2 Writing two assets atomically

Both assets are created inside a **single** `performChanges` block so the pair either both lands
or neither does. A half-saved moment is a broken invariant.

```swift
try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
    PHPhotoLibrary.shared().performChanges({
        let backReq  = PHAssetCreationRequest.forAsset()
        let frontReq = PHAssetCreationRequest.forAsset()
        backReq.addResource(with: .photo, data: backData,  options: nil)
        frontReq.addResource(with: .photo, data: frontData, options: nil)
        backAssetID  = backReq.placeholderForCreatedAsset?.localIdentifier
        frontAssetID = frontReq.placeholderForCreatedAsset?.localIdentifier
    }, completionHandler: { ok, err in
        ok ? c.resume() : c.resume(throwing: err ?? LibraryError.unknown)
    })
}
```

`placeholderForCreatedAsset` is valid *inside* the change block and its `localIdentifier` is
valid afterwards — this is the intended mechanism for capturing the identifiers of assets you
just created.

### 6.3 EXIF preservation and GPS injection

`fileDataRepresentation()` returns a full JPEG/HEIC with capture EXIF. Writing those bytes
directly preserves everything. GPS is injected only when the user opted in for that moment,
by round-tripping through `CGImageSource` / `CGImageDestination` and overriding only the GPS
dictionary:

```swift
var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
if let lat = lat, let lon = lon {
    props[kCGImagePropertyGPSDictionary] = [
        kCGImagePropertyGPSLatitude: abs(lat),
        kCGImagePropertyGPSLatitudeRef: (lat >= 0 ? "N" : "S"),
        kCGImagePropertyGPSLongitude: abs(lon),
        kCGImagePropertyGPSLongitudeRef: (lon >= 0 ? "E" : "W"),
        kCGImagePropertyGPSTimeStamp: ISO8601DateFormatter().string(from: Date()),
    ]
}
```

Never call `CLGeocoder`. Coordinates are stored; they are never resolved to a place name, and
no network request is ever made to do so. This keeps NFR-1 intact and is a materially better
privacy posture than BeReal, which publishes 1-metre coordinates through an open endpoint.

### 6.4 Album (optional, default off)

When `settings.saveToAlbum`, lazily create or fetch an album named `Memoree` and add both
placeholders via `PHAssetCollectionChangeRequest`. Guard with `albumCreationAttempted` so a
user who deletes the album does not get it recreated on every capture.

A failed album add **never fails the moment** — the photographs are already in Photos. The
failure is noted on `AppEnvironment.albumFailureNote` and shown on both Today’s footer and
Settings’ Photos section (grey metadata, not amber). Changing the album toggle clears the note.

### 6.5 Reading back for the archive

Grid thumbnails use `PHCachingImageManager` with a request per visible cell, keyed by
`localIdentifier`, at a target size derived from the cell bounds × screen scale. Feed results
into a small in-memory `NSCache<NSString, UIImage>`. Do not use `PHCachingImageManager`'s
`startCachingImages` for this size of data set — the bookkeeping costs more than it saves.

**The cache lives on the manager, so there is one manager per service.** Constructing one per
call caches nothing, which is invisible behind a single composite on the Today screen and only
appears once a 500-cell grid re-requests every image on every scroll.

**The target size is part of the cache key, not just a parameter.** Photos returns a different
decode for a thumbnail and for a full-screen image, so a key that omitted the size would hand
the detail view a 96pt thumbnail — a bug that renders as a blurry photograph and reads as a
Photos problem rather than a cache one.

If an asset identifier no longer resolves, **render a "missing from Photos" cell and leave the
moment in the archive.** The user may have deleted it from Photos deliberately, and tombstoning
during a grid read would delete an archive entry because of a *read* — irreversible from the
user's side, and triggered by nothing they did in this app. `MomentStore.delete()` is the only
tombstone path.

**Archive remove failures are surfaced.** `ArchiveViewModel.delete` writes `deleteError` on a
failed tombstone (or a missing row) and Archive presents an alert. Silent swallow left the detail
dismissing while the row remained — a dead end AGENTS.md §6 forbids. Photos assets are never
touched.

**The grid is grouped into months, and the grouping is a pure function.** `ArchiveSection` lives
in `Models`, takes `[MomentFacts]` and a `Calendar`, and returns sections keyed by a
`MonthKey` of year and month. Grouping by the *user's* calendar rather than UTC is not a detail:
a moment captured at 01:00 on 1 September in Auckland is 13:00 on 31 August in UTC, so a UTC
grouping files it under the wrong header on the screen whose only job is saying when a
photograph was taken.

The key is an integer pair rather than a `"YYYY-MM"` string or a start-of-month `Date`. A string
is not an instant, so it sorts lexicographically; a `Date` has to be manufactured from
`dateComponents` that silently fill in day and hour from the calendar's defaults. Both fail later
than they fail here.

The screen offers a **dual-view toggle**:
1. **Photo Grid**: A `ScrollView` of `Section`s in a `LazyVStack(pinnedViews: .sectionHeaders)`,
   each section holding its own `LazyVGrid`. **Pinned headers must have an opaque background** —
   these cells are full-bleed photographs, so a transparent header always has something showing
   through the text. Headers report both the month name and the count of moments (`section.countDescription`).
   Each cell carries a day-of-month badge on the top-left, a discreet Behind-the-Scenes (`video.fill`)
   badge on the top-right when `hasBTS` is true, and tactile spring feedback on tap (`PressDipStyle`).
2. **Monthly Calendar View (`ArchiveCalendarView`)**: A 7-column monthly calendar layout mapping
   days to photo thumbnails or subtle empty day slots, derived purely from `ArchiveSection.calendarDays()`.
   Captures can be opened with the same tactile feedback, sharing the exact same thumbnail streaming pipeline.
   The **day-of-month number sits below** the photo circle (not overlaid on it). When a day has more
   than one moment (ADR-030), the cell shows the newest thumbnail and a top-leading `×N` badge
   (`CalendarDayItem.momentCount`) so the count cannot be read as a second date; VoiceOver announces
   the count. Grid/calendar mode and Export Timelapse are separate trailing toolbar items with
   shared toolbar background hidden so they do not merge into one capsule.

An understated **collection summary header** at the top displays total moment count and the chronological
date span (e.g. `48 moments · Jun 2026 – Oct 2026`).

### 6.6 Flipbook export

Archive can export the **entire library** as a stop-motion timelapse via
`PhotoLibraryService.exportFlipbookVideo(for:framesPerSecond:)`. `PhotoKitLibrary` loads each
moment's rear asset (aspect-fit), draws it letterboxed on an opaque black 1080×1440 canvas
(`AspectFitRect` — no stretch, no crop), writes an H.264 `.mov` at 2 fps, then saves the file
into Photos (add-only). Features never imports AVFoundation for this path — encoding stays in
the photo-library service.

**This day across years (ADR-038).** When the same calendar month/day spans at least two distinct
years, Today’s ON THIS DAY section offers a quiet outline control that exports that subset through
the same `exportFlipbookVideo` path. Selection is pure (`SameDayFlipbook` over `[MomentFacts]`);
unlike `flashbackMoments`, the selection **includes the current year** so today’s capture can sit
in the movie. Fewer than two years: the control is omitted — no empty-state cheerleading.

## 7. Streaks

`StreakCalculator` is **pure functions over value types** — no SwiftData, no clock, no side
effects. This is what makes it exhaustively testable and free of isolation ceremony.

The input is `[MomentFacts]`, an immutable snapshot reduced to the fields the statistics need.
Not `[Moment]` directly, for two reasons: `Moment` is a managed object whose fields can change
behind the calculator's back, and `Moment` is not `Sendable` while `Set<DayIdentifier>` is.

```swift
enum StreakCalculator {
    /// Consecutive days with a captured moment, walking back from today.
    ///
    /// Two cases for today:
    ///   1. captured today -> count it
    ///   2. nothing today  -> walk from yesterday; the run stands (ADR-010)
    static func currentStreak(
        capturedDays: Set<DayIdentifier>,
        today: DayIdentifier,
        calendar: Calendar
    ) -> Int

    static func longestStreak(capturedDays: Set<DayIdentifier>, calendar: Calendar) -> Int

    static func missedDays(capturedDays: Set<DayIdentifier>, today: DayIdentifier, calendar: Calendar) -> Int

    static func summary(facts: [MomentFacts], today: DayIdentifier, calendar: Calendar) -> StreakSummary
}
```

`MomentStore.summary()` bridges the two: it maps managed objects to facts and calls through.
Nothing is cached — a stored counter is one more thing that can drift out of agreement with the
archive, and the recompute is microseconds over a few thousand rows.

Three rules that are easy to get wrong and are therefore pinned by tests:

1. **Every capture counts toward the streak.** Any memory captured on a day counts toward the
   streak, regardless of whether it occurred inside or outside the notification window (ADR-032).
   Only a day with **no moment at all** breaks the streak.
2. **The streak does not break until the day has actually passed.** An unposted *today* is not
   a miss, whatever time it is. Otherwise the streak visibly resets every morning and rebuilds
   by evening (ADR-010).
3. **Deleted moments recompute.** Tombstoning removes the row from `allMoments`, so the streak
   falls immediately with no cache invalidation step.

### 7.1 Home Screen widget (ADR-040)

`MemoreeWidget` is a WidgetKit extension. It does **not** open SwiftData. The app publishes a
`WidgetSnapshot` into the App Group (`group.com.javohirmx.memoree`) via
`WidgetSnapshotPublisher` after `MomentStore.record` / `delete` and on Today foreground reload.
Pure derivation lives in `WidgetSnapshotBuilder` (unit-tested).

| Family | Waiting (no moment today) | Done (moment today) |
| --- | --- | --- |
| Small | Empty shutter ring centered; compact streak bottom-leading | Huge centered streak |
| Medium | Ring + compact streak; week strip | Large streak; week strip |

Tap → `CaptureMomentIntent` → App Group camera handoff → `AppEnvironment.pendingCameraRequest`.
No photographs on the widget. App Group flakiness on Simulator is a device-check concern; logic
tests do not require the suite to be provisioned.

## 8. App states

The Today screen is a pure function of `(now, moment, latest Moment)`. Enumerating the states
exhaustively prevents the "what if both the window has passed and I've never posted" gap that
plagues this kind of UI.

**Chronological feed is grouped by calendar day.** `FeedDayGroup.grouping` buckets
`chronologicalFeedMoments` (newest day first). Each section titles the day once (`Today` /
`Yesterday` / medium date relative to the view-model clock); cards under it show **time only**
so multi-capture days (ADR-030) do not repeat the date on every card. ON THIS DAY / flashbacks
stay their own block and still use the full relative header per card.

| State | Condition | UI |
| --- | --- | --- |
| `captured` | a moment exists today | "Saved"; today's composite; re-capture allowed (replaces) |
| `scheduled` | now < momentStart, no moment today | "Memoree will ask you once today" — or "Next moment at 14:37" when notifications are off |
| `open` | momentStart ≤ now ≤ windowEndsAt, no moment today | "It's time"; calm invitation; shutter |
| `windowPassed` | now > windowEndsAt, no moment today | "Today's moment has passed"; shutter still there |

**No case carries a payload, and that is the enforcement.** `captured` used to carry
`late`/`lateBy` and the view rendered an amber "posted 12m late" badge above a sentence
saying the streak had not grown; `scheduled` and `open` carried countdowns. ADR-023 ruled
out the badge, ADR-024/ADR-032 removed the home-screen countdown, and ADR-032 made every
capture count toward the streak. Rather than delete the branches that rendered timing
judgment, the values went — so a view **cannot** leak the distinction whether or not anyone
remembers not to. `MomentStateTests` asserts that an on-time and an off-window moment
resolve identically.

`windowPassed` is not a miss. A day ends only when a day passes with no photograph at all
(ADR-010), and by the time it has, it is tomorrow and the state is `scheduled` again — which
is why the separate `missed` state was deleted rather than kept. It was unreachable in the
app: `endOfDay(containing: now)` is always later than `now`, so the `now < dayEnd` guard
that led to it always held.

The shutter renders in **every** state. The early-post refusal (`FR-5`) was removed — capture
is permitted at any time, and every capture day counts (ADR-032).

**No home-screen countdown (ADR-032).** When notifications are off, the footer still shows
a static "Moment today · …" row so the user has one way to learn the reminder time (ADR-024),
without a ticking number that reads as pressure.

## 9. Notification handling

`MemoreeApp` registers `UNUserNotificationCenterDelegate` via
`@UIApplicationDelegateAdaptor`, and in
`userNotificationCenter(_:willPresent:withCompletionHandler:)` returns
`[.banner, .sound]` so tapping is not required.

**The delegate is not optional, and its absence was two separate bugs.** Without
a delegate, iOS *suppresses* a notification arriving while the app is in the
foreground — the user is looking at the screen the reminder is meant to
interrupt, and nothing appears. Without `didReceive`, tapping a reminder only
launches the app, discarding the intent that made them tap. The ritual's one
trigger silently degraded to "works if you happen to be elsewhere".

Deep link: notification category `MOMENT` with no action buttons. Tapping
foregrounds the app into the camera, because the tap *is* the intent.

**How the tap is routed.** There is no URL scheme and no universal link —
`Info.plist` registers neither, deliberately, because Memoree makes no network
calls (AGENTS.md §2.1). So the tap is delivered in-process: the delegate raises a
flag on `AppEnvironment` and `TodayView` watches it.

- The flag is checked on appear **and** on change. A cold launch delivers the tap
  before `TodayView` has registered an observer, and `.onChange` only fires for
  changes that happen after it exists.
- It is consumed once. `TodayView` reappears every time the camera is dismissed,
  and a tap from twenty minutes ago must not re-open the camera on the next
  visit.
- Neither the delegate nor the environment is a singleton. The delegate is owned
  by the property wrapper and handed the one closure it needs.
- `UIApplicationDelegate` is main-actor isolated and
  `UNUserNotificationCenterDelegate` is not, so conforming to both crosses an
  isolation boundary. The two callbacks are `nonisolated` — which the system
  genuinely requires — and the handler they forward to lives in a lock-guarded
  box rather than on the main-actor instance. That is what makes the annotation
  honest instead of merely silencing the compiler.

**Opening the camera is not gated on the window.** A stale reminder tapped hours
late opens the camera regardless, and `MomentState.allowsCapture` decides whether
a shutter is offered. Refusing to open it would be the worse answer: the user
tapped because they wanted to photograph something, and "late" is a supported
state (F9, ADR-009), not an error.

**The horizon decision is pure and separately tested.** `UNUserNotificationCenter`
is a thin shell that reports what is pending and does what it is told;
`NotificationHorizonPlanner` decides what to schedule, from value types alone.
This split exists because the decision is otherwise **unobservable** — the system
centre cannot be subclassed into a test double — which is why Phase 1's refill
invariant test was never written and stayed unwritten through two refactors.
The invariant is at 0/19/20/64 pending, and includes the one that matters most:
above 64, iOS drops adds silently and the user simply stops being reminded, with
nothing thrown and nothing logged.

If notifications are denied, every state is still reachable and the shutter is still there — the
Today screen additionally **shows the moment time**, because with no notification it is the
only way the user could ever learn when the moment was (ADR-024). The ritual degrades; it does
not die. This is the correct degradation for a no-server app: nothing can re-notify you, so
the app must remain fully functional without push.

This is the one place the UI changes shape on a permission, and the reason is not convenience:
the notification and the clock are the same information delivered twice, and showing both
spends the surprise for nothing.

## 10. Design system

Dark only. No `colorScheme` branch anywhere — the theme is a constant.

| Token | Value | Use |
| --- | --- | --- |
| `canvas` | `#000000` | Every screen background |
| `surface` | `#1C1C1E` | Cards, sheets, rows |
| `divider` | `#2C2C2E` | Hairlines, pressed states, chips. Absorbed `surfaceElevated`, which was the same value under a second name |
| `textPrimary` | `#FFFFFF` | Titles, primary actions |
| `textSecondary` | `#8E8E93` | Timestamps, metadata |
| `textTertiary` | `#848486` | The faintest passing grey. Icons, dividers, decorative marks |
| `onAccent` | `#000000` | Label on a white fill |
| `accent` | `#FFD60A` | **The only** amber, and the app's single accent. One use: a permission the user declined and can only restore in system Settings (ADR-025) |

`destructive` was `#FF453A` for delete confirmations and **has been removed.** It had no call
site: SwiftUI's `role: .destructive` supplies the system red for every destructive control in
the app, so the token was a second red that only existed in the theme file.

The amber token was named `late` and reserved for late badges and a sub-30s countdown. ADR-023
and ADR-024 removed both, and an off-window moment is now deliberately indistinguishable from an
on-time one — so there was nothing left for the colour to *mean*. It is not called `late`
anymore, because a token whose name contradicts its only use is the same mistake the badge was.
See **ADR-025**.

**`textTertiary` is `#848486`, and the ramp is two tiers.** It was `#636366`, which measures 3.51:1
on the canvas and 2.84:1 on a card against WCAG AA's 4.5:1 — and it carried real words, not
decoration. `#848486` is 5.63:1 on black and 4.56:1 on a card: the faintest grey that passes on the
harder of the two backgrounds it is used on.

**The cost is a tier, and it is stated here rather than discovered later.** Secondary is 6.44:1
and tertiary is 5.63:1 — a 13% step, down from 46%. Thirteen percent does not read as a tier. The
alternative does produce three distinct passing tiers on black (`#848486` / `#B0B0B8` / `#FFFFFF`,
a 73% step) but only by brightening every piece of secondary text in the app. Tone kept, tier
given up. **Legibility is not negotiable; a third shade of grey is.**

An invariant computes the ratio from the hexes in `Theme.swift` — not from a copy of them in the
test, which is how the first version of it asserted about the values the app used *before* the fix
and failed after it.

Type ramp (SF Pro, system): display 64/700 **tabular**; screen title 22/700; card username
17/600; body 15/400; metadata 13/400; button 17/600. Every one is a **text style**
(`Font.system(.headline)`), not a point size — a fixed size does not scale, and this app had no
Dynamic Type at all until Phase 8. The two display numerals have no text style and use
`@ScaledMetric`, capped at 2.5×.

**A control's height must never be pinned to a literal.** `PrimaryButton` was
`.frame(height: 52)` against a scaling label, and at `accessibility-extra-extra-large` the "p" of
"Capture" was clipped by the capsule's bottom edge. `minHeight` instead: the 52pt target holds at
every size the design was drawn at and grows with the label beyond it. An invariant fails on any
`.frame(height: n)` above a hairline.

**Custom controls meet Apple's 44×44 pt hit region.** `Theme.Size.tapTarget` is the floor.
The drawn control may stay smaller when the design calls for it — camera zoom circles stay at
`Theme.Size.zoomButton` (34pt, stock camera), and photo-overlay chrome stays compact via
`ChromeIconButton` — but the tappable frame is expanded with `expandedCircularHitTarget` or an
explicit `frame`/`minHeight` of `tapTarget`. Filter pills, Jump, and view-mode toggles use
`minHeight: tapTarget`. Calendar day cells fill their grid slot rather than inventing a second
layout for narrow widths.

**A solid white control is reserved for `PrimaryButton`.** On black there is no other emphasis
available — no hue, no shadow that reads — so white fill is the loudest thing a screen can say and
it says it in exactly one way. Settings' export row was a solid white pill competing with the
amber "Open Settings" button two sections below it. An invariant fails on any
`background(Theme.Color.textPrimary)` outside `Components.swift`.

**User-facing motion goes through Reduce Motion.** Prefer `View.appAnimation` for
`.animation(_:value:)` and `withAppAnimation` for transactional updates. Raw `withAnimation` in
Features is a regression — under Reduce Motion the change must be immediate, not merely faster
(ADR-039 for BTS; same rule for UI chrome).

**Times are rendered by the device, never by format string.** `"HH:mm"` and
`String(format: "%02d:%02d")` were both in the app, on the screen that tells the user when to be
ready and on the screen where they set their window. A user in the United States read a 24-hour
clock while eight other screens said "11:00 AM". Both now use `.formatted(time: .shortened)`.

**The app icon is generated, not drawn.** `Scripts/make-appicon.swift` renders it with CoreGraphics
from `Theme`'s own numbers — the 3:4 frame, `Radius.inset` against `Size.insetStandard`, the
composite's top-left overlap — and writes one opaque 1024 PNG. An icon is the one piece of this
app's visual identity that no design system governs, and a hand-drawn PNG is a file nobody can
review: no diff shows whether the inset moved. Three numbers in that script are deliberately *not*
the app's values (corner radius 8% rather than 5%, stroke 5% of the frame's width, inset 34%
rather than 27%) because the icon is judged at 60pt, where the app's values are correct but too
small to read. The comments say which is which.

`AppIconTests` exists because the `AppIcon.appiconset` directory had been in the repository since
day one with a `Contents.json` naming **no file**, and every build and every test suite passed
while the app could not be submitted. It also checks the icon is opaque — App Store Connect
rejects an alpha channel, and `sips` adds one while resizing, which is how an icon that shipped
in a build stops being shippable after somebody tidied it — and that `LaunchBackground` and
`AccentColor` are the values this design system says they are.
**`24:00` is the one exception and stays** — it means end-of-day, a boundary rather than an
instant, so there is no honest `Date` for it and rendering it as `00:00` would put the end of a
window before its start.

Radii: button `Capsule`; card 18; BTS inset 14; thumbnail 6; avatar `Circle`.
Spacing base 4pt.

Shadows on a black canvas do not read as darkening — they read as opacity. **Use them never.**
`Elevation` existed with one member and a comment directly above it saying to prefer omitting
them; both are gone.

## 11. Concurrency

Swift 6 strict concurrency.

- `CaptureSessionController` is `NSObject, @unchecked Sendable`; all mutable state is confined to
  `capture.session`. Justification is documented at the declaration.
- UI-observable state is published through an `@MainActor` observable adapter. The capture layer
  never imports SwiftUI.
- `PhotoLibraryService` and `MomentScheduler` are `Sendable` protocols with `async` methods.
- Continuation-based bridging is used exactly once per delegate callback and resumed exactly
  once. The delegate objects are per-capture and discarded afterwards to avoid retain cycles
  through the capture session.

## 12. Privacy & App Store readiness

`PrivacyInfo.xcprivacy`:

```xml
<key>NSPrivacyTracking</key>            <false/>
<key>NSPrivacyTrackingDomains</key>     <array/>
<key>NSPrivacyCollectedDataTypes</key>  <array/>
```

**Empty collected data types is the correct and honest answer.** Location is captured into
metadata that never leaves the device, which does not constitute collection under Apple's
definition. Photos are written, not collected. There are no third-party SDKs, so there are no
required-reason APIs to declare beyond `UserDefaults` if it is used
(`NSPrivacyAccessedAPICategoryUserDefaults`, reason `CA92.1`).

`Info.plist` usage strings: camera, microphone (BTS only), photo library add, location
(optional, `NSLocationWhenInUseUsageDescription` — "When" only, never "Always").

No `NSUserTrackingUsageDescription`. No `ATTrackingManager`. No `UIPasteboard` scraping. No
undocumented selectors — verified with `nm -u` against the built binary before any TestFlight
upload.

## 13. Verification strategy

| Layer | Method |
| --- | --- |
| Scheduler | Pure-function unit tests against golden HMAC vectors; notification-refill invariant test at 0/19/20/64 pending |
| Streaks | Table-driven tests for DST boundaries, month rollover, delete-recompute, today-not-yet-missed |
| Day identifiers | Round-trip tests across DST transitions and a timezone change |
| Capture | `LiveCaptureTests` on device, including a 20-run reliability check. **Cannot be tested in the simulator** — `AVCaptureDevice.default` returns nil there and the camera does not exist. `LiveCaptureRunGuardTests` fails a simulator run so the skip cannot pass silently |
| PhotoKit | Simulator for permission flows; real device for actual writes and EXIF verification |
| Network-free | Airplane-mode test on device; `nm -u` binary audit; a unit test asserting no `URLSession` is constructed by any production type |
| Archive grouping | Pure-function tests on `ArchiveSection.grouping(_:calendar:)` against a **pinned** calendar. The boundary cases are the tests that matter: a moment on the far side of the month boundary from UTC in both directions, a DST transition inside a month, interleaved input, and "every moment appears exactly once". Calendar multi-capture: `momentCount` / newest thumbnail when ADR-030 leaves more than one moment on a day |
| Today feed day groups | Pure-function tests on `FeedDayGroup.grouping` / `title(now:)`: empty, same-day collapse, newest-first day order, Today/Yesterday/dated titles against a pinned clock |
| BTS Reduce Motion | Pure-value tests on `BTSPlaybackMotionPolicy` (no autoplay/loop when reduced; mute default independent). Device check for actual AVPlayer behaviour |
| Same-day flipbook | Pure-function tests on `SameDayFlipbook.moments` / `isExportable`: month-day match across years (including current), leap-day exact match, local calendar vs UTC, multi-capture same year does not unlock export, year-span does |
| Design system | Source-scan invariants: no hardcoded colour, no hardcoded dimension, no `accessibility` symbol escaping the design system, and — see below — what a test asserting about design *cannot* catch |

That last one is unusual and deliberately so: given that "no server" is the product's central
claim, it should be mechanically enforced, not merely intended.

### What the source scans can and cannot do

Four design invariants are enforced by scanning source rather than by rendering. **A source scan
cannot tell you whether a screen looks right**, and the project has been bitten by assuming it can:
a test once asserted that the header icons were *pinned* to a fixed 20pt, faithfully protecting
the defect that Dynamic Type could not reach them.

| Invariant | Catches | Cannot catch |
| --- | --- | --- |
| No hardcoded colour in a view | A new `#RRGGBB` bypassing `Theme.Color` | Whether the token's contrast passes — that is a separate computation |
| No hardcoded dimension in a view | A literal `52` or `96` reintroduced | Whether the value is right |
| No `.frame(height: n)` above a hairline | A pinned control height clipping a scaling label | *Which* accessibility size clips, and by how much |
| Only `PrimaryButton` paints a white control background | A secondary control spending the app's one emphatic gesture | Whether the hierarchy reads correctly to a person |

The contrast invariant is the exception: it **computes the WCAG ratio from the hexes in
`Theme.swift`**, because the whole point is the ratio and someone brightening a token by eye cannot
tell whether they have passed. Its first version listed the hexes inside the test instead, which
meant it asserted about the values the app used *before* the fix and failed after it — a test
carrying its own copy of the thing it is testing is a test of the copy.

**Every claim about a size, a colour or a layout was checked by screenshotting a build at each
relevant setting, and two claims written down beforehand were wrong when measured.** The clipped
descender was estimated as eleven points of lost title from a smaller accessibility size than
actually clips. These are recorded in the code comments at the fixes, because a comment that
asserts a measurement nobody took is worse than no comment.

### Scans with recorded exceptions

A scan with no exceptions is a scan that gets switched off, so each exclusion states its reason:

- **`0` and `1` are not scanned for dimensions.** `VStack(spacing: 0)` means "no gap" and a 1pt
  divider is a hairline — both literal by nature, and a token for each would claim to be part of
  the system when it is not.
- **Comments are stripped before scanning.** The first fixed-glyph test matched `.system(size:`
  inside a comment *explaining why icons used to be fixed* — a test that fails on its own
  documentation.
- **The shutter's white fill is exempt** from the filled-control rule. It is `.fill` rather than
  `.background`, and it is the inside of a ring the user is looking straight at.

### The clock rule, and the two tests that had an expiry date

**A test that pins a date *and* derives "today" from the real clock has written a test with an
expiry date.** Two of ~350 did, and the suite went red at 00:00 on 2026-10-02 with no code change.

`StreakCalculator.currentStreak` and `AppEnvironment.updateWindow` both take their boundary from
the real clock — correctly, because in the app they must. The mistake was in the tests, which
pinned the *other* end: `makeModel` injects a `StepClock`, but `MomentStore.summary()` reads the
system clock, so a capture on a hardcoded day only lands inside the walk while that day is today
or yesterday. Those tests had a two-day expiry, and they expired at midnight.

The fix is to derive the day. `summary(today:)` takes an explicit argument precisely so this is
possible, and the pure-function suites (`StreakCalculatorTests`, `StreakSummaryTests`) already pass
it — which is why they were the only streak tests that survived the rollover.

**One test had gone green for the wrong reason**, which is the more dangerous half. The
late-capture test asserted `currentStreak == 0`; a stale day also yields 0, because of the gap
rather than the lateness. It was passing and proving nothing. **An assertion satisfied for the
wrong reason is worse than one that fails**, because the first advertises coverage.

Where a test genuinely needs a fixed instant — export file contents, persistence round-trips — a
literal is correct, and those pass `Date(timeIntervalSince1970:)` or compare against a fixed
string. The rule is not "never pin a date". It is **never pin a date for a value measured against
today**.
