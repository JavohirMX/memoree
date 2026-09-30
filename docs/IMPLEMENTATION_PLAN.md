# Memoree — Implementation Plan

**Date:** 2026-09-30 · **Phases:** 11 · **Strategy:** vertical slices, each independently runnable

---

## Working agreement

Phases are ordered by **risk**, not by layer. The two things most likely to invalidate the
design — the moment scheduler and the sequential capture — are built and proven early, before
any of the pleasant UI work. If either fails, better to learn in week one than week nine.

Each phase ends with a runnable app on device. A phase is not done until it runs.

**Definition of done, every phase:**
- Builds clean with zero warnings
- `swiftlint lint --quiet` clean
- New logic has unit tests that pass
- Runs on a physical device, not just the simulator
- Any new failure mode is handled, not merely avoided

> The linter gate was a fiction until Phase 4: SwiftLint was installed but crashed on startup,
> and there was no config file, so "swiftlint clean" had never been checked by anything.
> `.swiftlint.yml` now exists and the gate passes. The rules that are off are off for a stated
> reason in the file, not silently.

---

## Phase 0 — Toolchain and skeleton

**Why first:** `xcode-select` pointed at Command Line Tools, which has no iOS SDK.
Nothing can be built until this is fixed, and the failure message is misleading.

> **`DEVELOPER_DIR` is not a substitute for the `xcode-select` switch.** Setting the environment
> variable makes `xcodebuild` find the right toolchain, but `xcodebuild` shells out to `xcrun`,
> and `xcrun` resolves its utilities through `xcode-select`. Anything that shells out then fails
> with `xcrun: error: unable to find utility "devicectl", not a developer tool or in PATH` — a
> message that names a missing tool rather than a misconfigured selector, and cost an hour to
> read correctly in Phase 4.
>
> Two things were blocked on this and looked like unrelated problems: **SwiftLint crashed on
> startup** (its Homebrew binary resolves `sourcekitdInProc` through the active developer dir),
> and **device tests could not run**. Both worked immediately after the switch. A broken
> linter is a toolchain symptom, not a broken install.

| Task | Notes |
| --- | --- |
| Switch developer directory | `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer` |
| Verify iOS SDK | `xcrun --sdk iphoneos --show-sdk-path` must print a path |
| Launch Xcode once, accept licence | Required before code signing |
| Set development team | Signing & Capabilities → your Apple ID team. Must be the certificate's `OU`, not the identifier in its common name — see TRD §1 |
| `git init`, first commit | Non-negotiable; do this before writing code |
| Create `project.yml` for XcodeGen | App target + unit test target |
| Commit generated `.xcodeproj` | So contributors do not need XcodeGen |
| Add `LICENSE` (MIT), `.gitignore`, `README.md`, `AGENTS.md` | |
| `Theme.swift` with the full token set | Static tokens only, no usage yet |
| `MemoreeApp.swift`, `RootView` → black screen | Proves the build/install/sign pipeline |

**Exit:** a black app runs on your device.
**Estimate:** half a day.

---

## Phase 1 — Models and the moment scheduler

**This is the highest-risk logic in the app. Do it before any UI.**

| Task | Notes |
| --- | --- |
| `DayIdentifier` | Local calendar date as `String`, with round-trip helpers |
| `TimeWindow` validation | Clamp to a sane 1-hour span if the user config is degenerate |
| `MomentScheduler` protocol + `LocalMomentScheduler` | HMAC-SHA256 derivation per TRD §4.1 |
| Keychain `InstallSecret` | 32 random bytes, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| SwiftData `ModelContainer` + all four models | Per TRD §3 |
| `MomentStore` | `@MainActor`; the single write path; one moment per day enforced |
| `NotificationService` protocol + impl | Rolling 45-day horizon, refill below 20 |
| Golden-vector tests | Fixed secret + day → fixed time. Locks the derivation. |
| Refill invariant test | Simulate 0, 19, 20 and 64 pending; assert the horizon restores to 45 |
| DST tests | Spring-forward gap, fall-back repeat, month/year rollover |
| Timezone-change test | Change the zone; assert day identifiers re-anchor correctly |

**Exit:** install the app, and within a minute a real notification is pending at a correct,
plausible, stable time. Relaunch five times; the time does not move.
**Estimate:** 2 days.

---

## Phase 2 — Streaks ✅

Pure functions; should be quick.

| Task | Notes |
| --- | --- |
| `MomentFacts` | Immutable snapshot; the boundary between SwiftData and the arithmetic |
| `StreakCalculator` | Current, longest, missed days, and the full `StreakSummary` |
| Table-driven tests | DST boundary, month rollover, delete-recompute, "today is not yet a miss" |
| `MomentStore.summary()` | Maps managed objects to facts; recomputes on read, caches nothing |

**Exit:** unit tests green against a hand-built fixture table. **Done — 77 tests pass.**

**The bug this phase caught.** The first implementation of `currentStreak` took only
`onTimeDays` and treated "not on time today" as one case. That conflates *late today* (breaks
the streak, ADR-009) with *nothing captured today* (does not break it, ADR-010), and returned
`1` instead of `0` for a late capture sitting on top of a perfect week. Found by executing the
arithmetic before writing the formal suite, which is the argument for doing exactly that.

**Estimate:** half a day. **Actual:** half a day.

---

## Phase 3 — Photos library write path ✅

Prove the data lands correctly **before** the camera exists, using fixture images. Debugging
HEIC and EXIF is far easier with a known input.

| Task | Notes |
| --- | --- |
| `PhotoLibraryService` protocol | So tests can assert calls without a device |
| `PhotoMetadataInjector` | Pure `Data` → `Data`, testable without PhotoKit |
| Add-only authorisation | `.limited` maps to authorised; `.restricted` does not write |
| Two-asset atomic write | Single `performChanges` block (TRD §6.2) |
| EXIF round-trip | `CGImageSource` → override GPS → `CGImageDestination` |
| Optional album | `saveToAlbum`, default off, `albumCreationAttempted` guard |
| Test double | `InMemoryPhotoLibraryService`, recording what it was asked to do |
| Live device test | Opt-in via `MEMOREE_LIVE_PHOTO_TESTS=1` |

**Exit:** a test method writes two images to the real Photos app on device, with GPS metadata
correctly attached, and returns usable `localIdentifier`s.

> **Status: code complete and proven wherever proof is possible; exit criterion
> needs hardware.** 109 tests pass on the simulator. The four live tests skip there,
> and `LivePhotoRunGuardTests` **fails the run** while they are skipped, so a green
> simulator run cannot be mistaken for a verified one.
>
> The simulator cannot do it. Verified with raw PhotoKit and no Memoree code in the
> path:
>
> - `xcrun simctl privacy grant photos-add` (note `photos-add`, not `photos` —
>   `.addOnly` and `.readWrite` are separate TCC entries) yields
>   `authorizationStatus == .authorized`.
> - `performChanges` then completes with `success = true, error = nil` and returns a
>   well-formed `localIdentifier`.
> - Nothing is created. Ten seconds of polling shows zero assets and zero
>   `PHPhotoLibraryChangeObserver` callbacks, and `Library/Photos/Photos.sqlite` never
>   appears. `photolibraryd` is not running in the runtime.
>
> The API contract is satisfied and the operation is silently discarded.
>
> To close the phase on hardware:
>
> ```sh
> export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
> xcodebuild test -project Memoree.xcodeproj -scheme Memoree \
>   -destination 'platform=iOS,name=<your device>'
> ```
>
> Approve the Photos prompt once. Two `Memoree Phase 3 Fixture` photos are written to
> the camera roll and are not deleted automatically. On a device the guard passes,
> because the live tests genuinely execute.

**A skipped test that reports as passed is a defect.** Swift Testing counts an
early `return` as a pass, which is how four live tests "passed" in one millisecond
having asserted nothing — twice. First behind a `MEMOREE_LIVE_PHOTO_TESTS` gate that
`xcodebuild` never propagates into the test process, then because the simulator
discards writes. Mitigations now in place: each skip prints an unmistakable banner,
and `LivePhotoRunGuardTests` fails the run unless at least one live test executed.
The guard deliberately does not read an environment variable — the first version
did, and a single misplaced XML element in the scheme silently disabled the very
check meant to prevent exactly this.

**Defect found: GPS removal was a no-op.** `CGImageDestinationAddImageFromSource` re-reads
the source's own EXIF *after* the properties dictionary is applied, so removing the GPS key
and passing `nil` reinstated the coordinates from the very metadata being deleted. Stripping
now decodes to a `CGImage` and re-adds, which drops source EXIF by design. Caught because
the test asserted on the *output bytes* rather than on the call arguments.

**Defect found: a SwiftData boolean that never persists.** `Moment.isDeleted` was written by
`delete()` and saved without error, then read back `false` from a fresh `ModelContext` —
while `deletedAt` on the same object persisted fine. Isolated to two identical `Bool`s in one
model where `plain` persisted and `isDeleted` did not: an Xcode 27 / iOS 27 SDK defect keyed
on the property name. The tombstone is now `deletedAt` alone, with `isDeleted` derived. See
ADR-017.

**The live test skip logic was wrong twice.** It first called `PHPhotoLibrary
.requestAuthorization(for: .addOnly)`, which blocks indefinitely when TCC holds no decision and
no one can dismiss the dialog — precisely a test host's state. The first live test hung the
entire suite for ten minutes rather than failing.

It then gated on `MEMOREE_LIVE_PHOTO_TESTS=1`, which looked safer but was worse:
`xcodebuild` does not propagate shell environment variables into the test process, so the
documented way to enable the suite silently did nothing and the four tests "passed" in a
millisecond having verified nothing. The gate now checks whether the host can actually persist
a photo — `Photos.sqlite` on the simulator, authorisation status on a device — which is a
property of the host rather than of configuration.

**Estimate:** 1.5 days.

---

## Phase 4 — Camera capture

**The second highest-risk phase.** Build and debug this before the Today screen, because it
will consume the most time and you want the remaining phases to be uneventful.

> **Status: code complete; exit criterion needs hardware.** 156 tests in 20 suites pass on the
> simulator except the two live-run guards, which fail there by design so a green run cannot be
> mistaken for a verified one.
>
> To close the phase on hardware:
>
> ```sh
> export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
> xcodebuild test -project Memoree.xcodeproj -scheme Memoree \
>   -destination 'platform=iOS,id=<your device>' \
>   -only-testing:MemoreeTests/LiveCaptureTests \
>   -allowProvisioningUpdates DEVELOPMENT_TEAM=<your team> \
>   -collect-test-diagnostics never
> ```
>
> **Always pass `-collect-test-diagnostics never`.** When a test fails, xcodebuild collects a
> verbose sysdiagnose from the host before exiting. On a simulator or a device that step hangs
> indefinitely with no output, and the run must be killed — which reports `BUILD INTERRUPTED`
> and destroys the exit code that would have said the run had finished. It reads exactly like a
> frozen test run, and it cost real time in Phase 4, because the tests are long since over: the
> entire simulator suite executes in **0.3 seconds** and the whole invocation in **2**. A
> missing sysdiagnose is worth nothing at this stage; a run that cannot be trusted to exit is.
>
> The 20-run reliability test is the gate. It prints its iteration count and every failure
> unconditionally, so a pass carries its own evidence.

| Task | Notes |
| --- | --- |
| `CaptureSessionController` | Dedicated queue, never main. Ownership documented. |
| `CapturePhotoService` protocol | Enables a fake for UI work and tests |
| Format selection | 3:4, widest supported, `.builtInWideAngleCamera` |
| Rear capture | First working path, front hardcoded as a stub |
| Front camera swap | `removeInput` / `addInput`, then **wait for a real delivered frame** — not a sleep |
| Front mirroring | `connection.isVideoMirrored = true` |
| Camera switch animation | Make the ~0.5s swap feel deliberate: cross-fade preview + haptic |
| Composite preview | ZStack, front inset top-left, 14pt radius, tap to swap primary |
| Unlimited retakes | Loop; count increments; only the final pair persists |
| `maxPhotoDimensions` | iOS 16+ replacement for the deprecated high-res flag |
| Error handling | Runtime error, interruption, **`mediaServicesWereReset`**, thermal critical, no input |
| Permission flow | First-request UX with a plain explanation |

**Device-only.** `AVCaptureMultiCamSession.isMultiCamSupported` is permanently `false` in the
simulator and there is no camera at all. Test on hardware, on a well-lit surface, at arm's
length.

**Exit:** on device, pressing the shutter reliably produces a correctly-oriented, correctly
mirrored, correctly-sized front+back pair. Run it 20 times without a failure. If it flakes, it
is the frame-wait on step 7 — fix it before moving on.
**Estimate:** 3–4 days. Do not rush this.

### Progress as of 2026-09-30

Done and verified on the simulator — 27 capture tests, zero warnings:

- `CapturePhotoService` protocol, `CapturedPhoto`/`CapturedPair`, `CaptureError` with all nine
  cases carrying user-facing copy, and `isRetryable` distinguishing transient failures from a
  permission the user must change in Settings
- `CaptureFormatSelector`, split so the 3:4 arithmetic is pure over `CMVideoDimensions` and
  unit-tested without a camera
- `CaptureSessionController` — session on `capture.session`, never main; the frame-wait;
  `mediaServicesWereReset` rebuild, reachable from `simulateMediaServicesReset()`
- `SequentialCaptureService` — the full ten-step sequence, owning the ordering so no caller can
  swap without waiting
- `CameraViewModel`, `CameraView`, `CameraPreview`, composite preview, unlimited retakes
- `TodayView.action()` replaced: the shutter is gated on `MomentState.allowsCapture`, so the
  FR-5 early-post refusal is structural rather than a disabled button
- `InMemoryCaptureService` in the app target, so the whole flow is testable with no hardware
- `LiveCaptureTests` + `LiveCaptureRunGuardTests`, device-only, including the 20-run check

**ADR-018 — the preview crosses the layer boundary as a `CALayer`.** Two rules were in tension:
"Features contains no AVFoundation" and "a preview must be on screen". The service owns the
`AVCaptureVideoPreviewLayer` and exposes it as a bare `CALayer`; `Features` wraps that in a
`UIViewRepresentable` importing only SwiftUI and QuartzCore. Neither import rule gets an
exception carved out.

**Three API corrections against the iOS 27 SDK.** `isFormatSampleRateAndResolutionSupported` no
longer exists, so the underlying `videoSupportedFrameRateRanges` are read directly.
`photoQualityPrioritization` lives on `AVCapturePhotoSettings`, not on the output.
`AVError.deviceInUseByAnotherClient` is now `deviceInUseByAnotherApplication`.

**Defect avoided: the frame-wait identified frames by generation, which is wrong.** A counter
read on the delivery callback returns the *new* generation by the time an in-flight frame from
the outgoing camera is delivered, so the stale frame is accepted and the front photo comes out
black — the exact failure a `sleep` was meant to prevent, arriving through a different door. The
wait identifies a frame by `AVCaptureConnection.inputPorts` instead, which does not change
retroactively. This was caught while writing it, not by a test, and is the reason the 20-run
device check is not optional.

**Two naming traps, both of which read as syntax errors rather than mistakes.** A view method may
not share a name with the enum case it is dispatched from: `func permissionDenied` shadowed
`Phase.permissionDenied` and stopped `case .permissionDenied: permissionDenied` from parsing.
And `UIView.layer` is get-only, so the preview surface is added as a sublayer rather than
adopted — correct here only because the service hands it over unattached.

**Not done, and deliberately.** `commit()` stops at the Photos write. `MomentStore.record` and
the streak recompute are Phase 5's orchestration. Stopping there means the shutter leads
somewhere real rather than to a dead end (AGENTS.md §6), and it proves the Phase 3 write path on
hardware in the same run.

**Outstanding:** the 20-run device check, and the human confirmation that the front image is
mirrored and the rear is not. The mirroring test asserts the mechanism held rather than claiming
a visual verdict — a selfie is close to symmetric, so only a person can confirm it reads as a
mirror.

---

## Phase 5 — Today screen

First real feature slice. Everything below it is presentation.

| Task | Notes |
| --- | --- |
| `MomentState` enum | The six states from TRD §8, exhaustive |
| `MomentStateResolver` | Pure function of `(now, interval, todayMoment, dayEnd)` — unit-testable |
| `TodayViewModel` | Owns the only ticking clock; re-derives state once a second |
| `OnboardingView` | Requests notification and camera authorisation, sets the moment window |
| `RootView` routing | Onboarding once, then Today |
| Countdown | `mm:ss`, **tabular figures**, amber under 30s |
| Streak display | Flame + count, from `StreakCalculator` |
| Camera presentation | Shown in `scheduled`, `open`, `lateAvailable`, `captured` |
| Early-post refusal | FR-5: camera unavailable before `momentStart` |
| `captured` success state | Shows the saved pair; allows re-capture which replaces |
| `missed` state | Quiet. No red, no guilt copy |
| Recording a moment | Orchestrate capture → Photos write → `MomentStore.record` → streak recompute |

**Exit:** the complete daily loop works end to end on device. Capture, save, streak, archive
entry. **Estimate:** 2 days.

### Progress as of 2026-09-30

Done and verified on a running simulator:

- `MomentState` + `MomentStateResolver`, with tests pinning the edges — the window is
  inclusive at both ends, and `missed` must not fire before the day actually ends
- `TodayViewModel`, including local-midnight day rollover
- `TodayView`, `OnboardingView`, `RootView` routing, and design-system components
- **A missing permission request.** The app never asked for notification authorisation, so no
  moment could ever fire. Onboarding now requests it, and the Today footer reports
  "Reminders off" in amber when it is absent.

Not yet: recording the moment itself. Phase 4 supplies the shutter and the camera, and its
`commit()` writes the pair to Photos — but `MomentStore.record`, the streak recompute, and the
captured state in the UI all remain Phase 5 work. Until then a capture is saved to the library
and not yet in the archive.

Observed on the simulator: today's moment derived at **21:54**, inside the 11:00–23:00
default window, stable across launches, countdown ticking 1:27:52 → 1:26:46. That is
Phase 1's scheduler verified end to end on a running device.

**Two defects found by screenshotting the running app**, neither of which a unit test could
have caught:

- The `.task` that *creates* the view model was attached inside the `if let model` branch
  that renders only once the model exists, so it never ran and the screen stayed black.
  Lifecycle modifiers now hang off the outermost container.
- `MomentFacts.lateBy` measured against local midnight rather than the window's end,
  reporting a moment captured ten minutes late as roughly fourteen hours late. `windowEndsAt`
  is now carried on the value type.

---

## Phase 6 — Archive

| Task | Notes |
| --- | --- |
| Grid | LazyVGrid, 3:4 cells, newest first |
| Thumbnails | `PHCachingImageManager` + `NSCache`, keyed by `localIdentifier` |
| Scrolling performance | Target 60/120fps on a 500-moment library |
| Missing-asset handling | Tombstone and render "missing from Photos" |
| Moment detail | Full-bleed, badge, timestamp, coordinates, retake count |
| Delete | Removes the archive entry only. **Does not delete from Photos.** State this in the UI. |
| Empty states | No moments yet / all deleted |

**Exit:** a 500-moment library scrolls smoothly and every moment opens.
**Estimate:** 1.5 days.

---

## Phase 7 — Behind the Scenes

| Task | Notes |
| --- | --- |
| `BTSRecorder` | `AVCaptureMovieFileOutput` → temp file → trim to last N seconds |
| Primary-camera-only | Matches BeReal semantics |
| Mic permission | Lazy, only on first enable; silent clip on denial |
| Zero-length guard | Clamp the trim range at zero for very fast captures |
| Playback | Long-press to preview; mute toggle |
| Save to Photos | `settings.saveBTS`, default on |
| Settings toggle | Per-app preference, not per-moment |

**Exit:** a moment captured with BTS plays back correctly, including after an app restart.
**Estimate:** 1.5 days.

---

## Phase 8 — Share and export

| Task | Notes |
| --- | --- |
| Share sheet | Both originals as two files |
| Composite renderer | Optional combined image, rendered on demand, **never** written to Photos |
| `ShareLink` | Straight from Photos via `PHAsset` image requests — never from app storage |
| `MomentExporter` | All metadata → single Codable JSON |
| Export via share sheet | Filename `memoree-export-<date>.json` |
| Import/restore | Optional stretch: read an export back |
| Onboarding warning | Reinstalling loses app data; Photos survives |

**Exit:** sharing produces two clean, unwatermarked originals and a correct JSON export.
**Estimate:** 1 day.

---

## Phase 9 — Stats

| Task | Notes |
| --- | --- |
| Stats view | Total moments, days captured, current + longest streak, on-time %, average retakes, BTS count |
| Busiest hour | Histogram of `capturedAt` |
| Streak history | Current and past streaks, in place of BeReal's Memories calendar |
| Empty states | Zero moments, one moment |

**Exit:** numbers match the archive by hand-check on three days of data.
**Estimate:** 1 day.

---

## Phase 10 — Settings and polish

| Task | Notes |
| --- | --- |
| Moment window picker | Start + end, with the "earlier is more random" explanation |
| BTS toggle + duration | |
| Save-to-album toggle | |
| Data export | |
| Deletion warning | Make the reinstall consequence unmistakable |
| Dark-mode audit | Assert no `colorScheme` branch anywhere; light mode is not a feature |
| Dynamic Type | Verify the countdown and metadata at accessibility sizes |
| VoiceOver | Camera, archive, detail |
| Reduce Motion | Honour it for the camera-switch animation |
| Reduce Transparency | N/A on pure black, but verify |
| Haptics | Capture, and the camera switch |

**Exit:** Settings does everything; accessibility pass complete.
**Estimate:** 2 days.

---

## Phase 11 — Release readiness

Do this only if and when you want TestFlight or the App Store.

| Task | Notes |
| --- | --- |
| `PrivacyInfo.xcprivacy` | `NSPrivacyTracking=false`, empty collected types (TRD §12) |
| Required-reason APIs | Declare `UserDefaults` (`CA92.1`) if used |
| Binary audit | `nm -u` for private API selectors; confirm zero networking symbols |
| **Network-free test** | Airplane mode, full loop, everything works |
| Icons | App icon, all sizes, no BeReal resemblance |
| Launch screen | Black |
| App Store metadata | Name, description, screenshots. **No** "BeReal" in the description |
| Privacy policy URL | Required for App Store; host it somewhere |
| Age rating | 4+ (no UGC, no accounts, no network) |
| Export compliance | No encryption beyond OS-provided → standard declaration |
| TestFlight upload | 90-day builds; re-signing cadence understood |

**Exit:** TestFlight build installs and runs for a friend.
**Estimate:** 1 day.

---

## Sequencing

```
Phase 0 ──► Phase 1 ──► Phase 2 ──┐
  toolchain   scheduler   streaks   │
                                   ├──► Phase 5 ──► Phase 6 ──► Phase 7
                     Phase 3 ──────┤      Today      Archive     BTS
                     photos         │         │         │          │
                                   │         └──► Phase 8 ──► Phase 9 ──► Phase 10 ──► Phase 11
                     Phase 4 ──────┘      share        stats     polish       release
                     capture
```

Phases 2 and 3 are independent and can overlap. Phases 8, 9 and 10 are largely independent of
each other.

**Critical path:** 0 → 1 → 4 → 5 → 6. Roughly 9–10 days of focused work to a fully working app.

---

## Test matrix

| Target | Coverage |
| --- | --- |
| iPhone 15/16/17 | Primary development device |
| An older device, if you have one | Format selection, thermal behaviour, multi-format edge cases |
| iOS 17.0 | The deployment floor — test the oldest supported OS first, it breaks in the best ways |
| iPad | Universal build should not crash; not optimised |
| Airplane mode | The full loop must work. This is a product requirement, not a test |
| Permission denied (each) | Camera, notifications, photos, mic, location — every single one |
| Low storage | Photo write fails cleanly; moment not silently lost |
| DST transition day | Moment resolution, day identity, streak |
| Timezone change mid-day | Day re-anchoring |
| 500+ moments | Archive scroll performance |
| App kill mid-capture | No partial moment written |

## Risks to the schedule

| Risk | Likelihood | Response |
| --- | --- | --- |
| Phase 4 sequential capture proves flaky | Medium | Highest-risk phase, first. Buffer 2 extra days. The frame-wait is almost certainly the culprit |
| HEIC + EXIF fights back | Medium | Phase 3 comes before Phase 4, using fixtures, precisely to contain this |
| Keychain access prompts on a dev build | Low | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` avoids most prompts |
| Notification horizon starves silently | Low | Invariant test at exactly 64 pending |
| Swift 6 concurrency fights AVFoundation's non-`Sendable` types | High | `@unchecked Sendable` with a documented justification, isolated to one file, confined to one queue. Decide this in Phase 0, not under pressure |
| Simulator-only testing gives false confidence | High | Every phase exits with a **device** run |

## Explicitly not doing

- No `AVCaptureMultiCamSession` (ADR-003)
- No server, no sync, no accounts, no network code of any kind
- No Android, no web, no macOS, no watchOS
- No third-party dependencies. The entire app is Apple frameworks plus SwiftUI. If a
  dependency ever seems necessary, that is a signal to re-read the no-server commitment.
