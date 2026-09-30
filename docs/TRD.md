# Memoree — Technical Requirements & Design

**Status:** Draft v1 · **Date:** 2026-09-30 · **Target:** iOS 17.0+, Swift 6, SwiftUI

---

## 1. Environment

| Component | Version | Status |
| --- | --- | --- |
| macOS | 27.0 (26A428) | available |
| Xcode | 27.0 at `/Applications/Xcode.app` | installed, **not selected** |
| iOS SDK | 27.0 | available |
| Command Line Tools | 15-series at `/Library/Developer/CommandLineTools` | **currently active** |
| Swift | 6.4 | available |

`xcode-select -p` currently returns the CommandLineTools path, which has **no iOS SDK**.
Every `xcodebuild` invocation fails until this is corrected. This is prerequisite step zero.

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version   # must report Xcode 27.0
xcrun --sdk iphoneos --show-sdk-path
```

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
│   │   └── Components/            # buttons, cards, countdown, badges
│   ├── Models/
│   │   ├── Moment.swift
│   │   ├── MomentDay.swift
│   │   ├── Streak.swift
│   │   └── AppSettings.swift
│   ├── Persistence/
│   │   ├── ModelContainer.swift
│   │   └── MomentStore.swift      # @MainActor, the only write path
│   ├── Services/
│   │   ├── Scheduler/
│   │   │   ├── MomentScheduler.swift       # protocol
│   │   │   ├── LocalMomentScheduler.swift
│   │   │   └── NotificationService.swift
│   │   ├── Capture/
│   │   │   ├── PhotoCaptureService.swift   # protocol
│   │   │   ├── SequentialCaptureService.swift
│   │   │   ├── CaptureSessionController.swift
│   │   │   ├── CameraSwitcher.swift
│   │   │   ├── BTSRecorder.swift
│   │   │   └── CompositeRenderer.swift
│   │   ├── PhotoLibrary/
│   │   │   ├── PhotoLibraryService.swift   # protocol
│   │   │   └── PhotoKitLibrary.swift
│   │   ├── Streaks/
│   │   │   └── StreakCalculator.swift      # pure functions
│   │   └── Export/
│   │       └── MomentExporter.swift
│   ├── Features/
│   │   ├── Onboarding/
│   │   ├── Today/
│   │   ├── Camera/
│   │   ├── Archive/
│   │   ├── MomentDetail/
│   │   ├── Stats/
│   │   └── Settings/
│   ├── Resources/
│   │   ├── Assets.xcassets
│   │   ├── Info.plist
│   │   └── PrivacyInfo.xcprivacy
│   └── Support/
│       ├── DayIdentifier.swift
│       ├── TimeWindow.swift
│       └── Log.swift
└── MemoreeTests/
    ├── MomentSchedulerTests.swift
    ├── StreakCalculatorTests.swift
    ├── DayIdentifierTests.swift
    └── PhotoKitLibraryTests.swift
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

**Uniqueness.** At most one accepted moment per `dayIdentifier`. Enforce in
`MomentStore.record(_:)` with a fetch-and-check plus a SwiftData `#Unique` constraint on
`dayIdentifier`. Re-posting after a delete updates the existing row rather than inserting.

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

Horizon: **45 days**, comfortably inside the documented 64-request pending limit. Refill when
`pendingNotificationRequests().count < 20`, checked on launch, on `scenePhase == .active`, and
after any accepted moment.

```swift
let content = UNMutableNotificationContent()
content.title = "It's time"
content.body  = "You have \(settings.windowDuration / 60) minutes to capture a moment."
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

**Why wall-clock components rather than a time interval.** A `UNTimeIntervalNotificationTrigger`
fires 45 × 86400 seconds after scheduling — which drifts against DST and against the device
traveling between timezones. `UNCalendarNotificationTrigger` with explicit components resolves
against the *current* timezone at fire time, which is the correct semantic for "at 14:37 on
30 September". This is a real correctness decision, not a style preference.

**DST.** If the resolved moment lands in a spring-forward gap, iOS fires at the first valid
instant after the gap. If the gap swallows the two-minute window entirely (a 1-hour forward jump
landing precisely on the minute), the moment is treated as missed and the day goes Late. Test
this explicitly.

**Identifier discipline.** `moment.<dayIdentifier>`. On re-resolve, `removePendingNotificationRequests`
with that identifier before re-adding. Never call `removeAllPendingNotificationRequests()` —
it would also clear permission-related and future-scheduled items.

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

Configuration sequence for each shutter:

```
1. output.capturePhoto(with: rearSettings, delegate: self)      // rear
2. await delegate callback for rear data
3. session.beginConfiguration()
4. session.removeInput(currentInput)
5. session.addInput(newInput)                                   // front
6. await connection on sessionQueue of .runtimeError == nil
7. await first delivered frame from the front input
8. output.capturePhoto(with: frontSettings, delegate: self)    // front
9. await delegate callback for front data
10. session.beginConfiguration(); restore rear input           // return to rear
```

Step 7 is not optional. Capturing before the front sensor has delivered a frame yields a black
or green image. Implement as a `CheckedContinuation` fed by
`AVCaptureVideoDataOutput` — or, cheaper, by polling
`session.connections.filter { $0.isEnabled }.isEmpty == false` plus a short settle delay.
Prefer the real frame signal; a fixed sleep is the first thing that will flake.

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
`.builtInWideAngleCamera` for both positions — not the tele or ultra-wide.

Set `photoOutput.maxPhotoDimensions` to the chosen format's dimensions (this replaces the
deprecated `isHighResolutionPhotoEnabled` on iOS 16+). Set
`photoQualityPrioritization = .speed` — latency matters inside a two-minute window and there
is no benefit to `.quality` here.

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
- Tap the inset (or double-tap the frame) to swap which is primary

Implemented as a ZStack in SwiftUI over the two `UIImage`s. The composite is **only** rendered
on demand for sharing (FR-14); it is never written to Photos, because the user chose two
separate assets.

### 5.7 Behind the Scenes

BTS records **only the primary camera**, matching BeReal: *"Only the first camera you choose to
capture your BeReal will be used to record your BTS video."*

v1 implementation: `AVCaptureMovieFileOutput` writing to a temporary file, started when the
camera screen appears, stopped on commit, then trimmed to the last `btsDuration` seconds with
`AVAssetExportSession(timeRange:)`. A continuous single-file recording is deliberately preferred
over a segmented ring buffer here: the camera session lasts seconds, not minutes, so the
temp-file write cost is trivial and the failure modes are far fewer.

```swift
let range = CMTimeRange(
    start: asset.duration - CMTime(seconds: settings.btsDuration, preferredTimescale: 600),
    duration: CMTime(seconds: settings.btsDuration, preferredTimescale: 600))
```

Guard the lower bound at zero — a fast capture can produce an asset shorter than `btsDuration`.

Audio requires the microphone permission. Request it lazily, only when BTS is enabled for the
first time, and degrade to a silent clip if denied rather than blocking the moment.

Because capture is sequential, the BTS file contains the rear stream up to the switch and
nothing after. That is the correct and expected behaviour, not a bug.

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

### 6.5 Reading back for the archive

Grid thumbnails use `PHCachingImageManager` with a request per visible cell, keyed by
`localIdentifier`, at a target size derived from the cell bounds × screen scale. Feed results
into a small in-memory `NSCache<NSString, UIImage>`. Do not use `PHCachingImageManager`'s
`startCachingImages` for this size of data set — the bookkeeping costs more than it saves.

If an asset identifier no longer resolves, tombstone the moment and render a
"missing from Photos" cell. The user may have deleted it from Photos deliberately.

## 7. Streaks

`StreakCalculator` is **pure functions over `[Moment]`**, no SwiftData, no dates fetched
implicitly. This is what makes it exhaustively testable.

```swift
enum StreakCalculator {
    /// Consecutive days ending today (or yesterday, if today has no post yet)
    /// that contain at least one *on-time* moment.
    static func currentStreak(moments: [Moment], today: DateIdentifier, calendar: Calendar) -> Int

    static func longestStreak(moments: [Moment], calendar: Calendar) -> Int

    /// Days with no on-time moment. A late-only day counts as a break (ADR-009).
    static func brokenDays(moments: [Moment], calendar: Calendar) -> Set<DateIdentifier>
}
```

Two rules that are easy to get wrong and are therefore pinned by tests:

1. **The streak does not break until the day has actually passed.** If it is 09:00 and the
   moment window is 11:00–23:00, an unposted *today* is not a miss. Only strictly past days
   break the streak. Otherwise the streak visibly resets every morning and rebuilds by evening,
   which would be maddening.
2. **Deleted moments recompute.** Deleting today's on-time moment resets the streak
   immediately, because there is no moment left to justify it.

## 8. App states

The Today screen is a pure function of `(now, moment, latest Moment)`. Enumerating the states
exhaustively prevents the "what if both the window has passed and I've never posted" gap that
plagues this kind of UI.

| State | Condition | UI |
| --- | --- | --- |
| `scheduled` | now < momentStart | Big countdown to the moment; "Next moment at 14:37" |
| `open` | momentStart ≤ now ≤ windowEndsAt, no moment today | Shutter CTA; `mm:ss` remaining, amber under 30s |
| `captured` | on-time moment today | Success state; streak shown; capture again allowed (replaces) |
| `lateAvailable` | now > windowEndsAt, no moment today | "Late" state; capture still permitted |
| `capturedLate` | late moment today | Amber badge; streak unchanged |
| `missed` | day over, no moment | "Missed" — no CTA, no nagging |

`missed` is quiet. No red, no guilt copy, no notification. The streak simply is what it is.

## 9. Notification handling

`MemoreeApp` registers `UNUserNotificationCenterDelegate` and, in
`userNotificationCenter(_:willPresent:withCompletionHandler:)`, returns
`[.banner, .sound]` so tapping is not required.

Deep link: notification category `MOMENT` with no action buttons. Tapping foregrounds the app
into the camera, because the tap *is* the intent.

If notifications are denied, `scheduled` and `open` states are still reachable — the Today
screen shows the countdown and the CTA. The ritual degrades; it does not die. This is the
correct degradation for a no-server app: nothing can re-notify you, so the app must remain
fully functional without push.

## 10. Design system

Dark only. No `colorScheme` branch anywhere — the theme is a constant.

| Token | Value | Use |
| --- | --- | --- |
| `canvas` | `#000000` | Every screen background |
| `surface` | `#1C1C1E` | Cards, sheets, rows |
| `surfaceElevated` | `#2C2C2E` | Pressed states, chips |
| `divider` | `#2C2C2E` | Hairlines |
| `textPrimary` | `#FFFFFF` | Titles, primary actions |
| `textSecondary` | `#8E8E93` | Timestamps, metadata |
| `textTertiary` | `#636366` | Disabled |
| `onAccent` | `#000000` | Label on a white fill |
| `late` | `#FFD60A` | **Only** amber: late badges, sub-30s countdown |
| `destructive` | `#FF453A` | Delete confirmation only |

Type ramp (SF Pro, system): countdown 24/700 **tabular**; screen title 22/700; card username
17/600; body 15/400; metadata 13/400; badge 12/700; button 17/600.

Radii: button and countdown `Capsule`; card 18; BTS inset 14; thumbnail 6; avatar `Circle`.
Spacing base 4pt.

Shadows on a black canvas do not read as darkening — they read as opacity. Use
`Color.black.opacity(0.6)` with a 24pt blur, or skip them entirely.

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
| Capture | Manual on device. **Cannot be tested in the simulator** — `isMultiCamSupported` is permanently false there and the camera does not exist |
| PhotoKit | Simulator for permission flows; real device for actual writes and EXIF verification |
| Network-free | Airplane-mode test on device; `nm -u` binary audit; a unit test asserting no `URLSession` is constructed by any production type |

That last one is unusual and deliberately so: given that "no server" is the product's central
claim, it should be mechanically enforced, not merely intended.
