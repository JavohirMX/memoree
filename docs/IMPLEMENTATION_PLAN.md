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
- `swiftlint` (or SwiftFormat) clean
- New logic has unit tests that pass
- Runs on a physical device, not just the simulator
- Any new failure mode is handled, not merely avoided

---

## Phase 0 — Toolchain and skeleton

**Why first:** `xcode-select` currently points at Command Line Tools, which has no iOS SDK.
Nothing can be built until this is fixed, and the failure message is misleading.

| Task | Notes |
| --- | --- |
| Switch developer directory | `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer` |
| Verify iOS SDK | `xcrun --sdk iphoneos --show-sdk-path` must print a path |
| Launch Xcode once, accept licence | Required before code signing |
| Set development team | Signing & Capabilities → your Apple ID team |
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

## Phase 2 — Streaks

Pure functions; should be quick.

| Task | Notes |
| --- | --- |
| `StreakCalculator` | Current, longest, broken days, on-time percentage |
| Table-driven tests | DST boundary, month rollover, delete-recompute, "today is not yet a miss" |
| `StreakRecord` persistence | Recompute on read rather than maintaining incrementally — one fewer thing to get wrong |

**Exit:** unit tests green against a hand-built fixture table.
**Estimate:** half a day.

---

## Phase 3 — Photos library write path

Prove the data lands correctly **before** the camera exists, using fixture images. Debugging
HEIC and EXIF is far easier with a known input.

| Task | Notes |
| --- | --- |
| `PhotoLibraryService` protocol | So tests can assert calls without a device |
| Add-only authorisation | Request, handle `.limited` and `.denied` |
| `Info.plist` usage strings | Camera, photo add, microphone, location |
| Two-asset atomic write | Single `performChanges` block (TRD §6.2) |
| EXIF round-trip | `CGImageSource` → override GPS → `CGImageDestination` |
| Verify with fixture | Write two known images; confirm both appear in Photos with correct EXIF and timestamps |
| Optional album | `saveToAlbum`, default off, `albumCreationAttempted` guard |
| Test double | `InMemoryPhotoLibraryService` for all UI-phase tests |

**Exit:** a test method writes two images to the real Photos app on device, with GPS metadata
correctly attached, and returns usable `localIdentifier`s.
**Estimate:** 1.5 days.

---

## Phase 4 — Camera capture

**The second highest-risk phase.** Build and debug this before the Today screen, because it
will consume the most time and you want the remaining phases to be uneventful.

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

---

## Phase 5 — Today screen

First real feature slice. Everything below it is presentation.

| Task | Notes |
| --- | --- |
| `MomentState` enum | The six states from TRD §8, exhaustive |
| State resolver | Pure function of `(now, settings, todayMoment)` — unit-testable |
| Countdown | `mm:ss`, **tabular figures**, amber under 30s |
| Streak display | Flame + count, from `StreakCalculator` |
| Camera presentation | Shown in `scheduled`, `open`, `lateAvailable`, `captured` |
| Early-post refusal | FR-5: camera unavailable before `momentStart` |
| `captured` success state | Shows the saved pair; allows re-capture which replaces |
| `missed` state | Quiet. No red, no guilt copy |
| Recording a moment | Orchestrate capture → Photos write → `MomentStore.record` → streak recompute |

**Exit:** the complete daily loop works end to end on device. Capture, save, streak, archive
entry.
**Estimate:** 2 days.

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
