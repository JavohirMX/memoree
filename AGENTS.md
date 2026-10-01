# AGENTS.md

Operating instructions for humans and coding agents working on **Memoree**.

Read this before writing code. The constraints below are not stylistic preferences — several of
them are the product.

---

## 1. What Memoree is

A native iOS app that keeps BeReal's daily forced-spontaneity mechanic and deletes the entire
social layer. No server, no account, no feed, no network. Every capture is written to the
user's Photos library.

If a change makes Memoree require a backend, an account, or a network call, it is wrong. See
`docs/DECISION_LOG.md` ADR-001.

## 2. Non-negotiables

These are load-bearing. Violating any of them is a bug regardless of whether tests pass.

| # | Rule |
| --- | --- |
| 1 | **No network.** No `URLSession`, no `URLRequest`, no `NWPathMonitor`, no analytics, no crash reporting, no remote config, no web views. Airplane mode must pass the full loop. |
| 2 | **No accounts.** No sign-in, no user identity, no usernames, no server-side state. |
| 3 | **No third-party dependencies.** Apple frameworks only. A dependency needs a written justification in the decision log first. |
| 4 | **No image bytes in app storage.** Photos are written to Photos; the app stores metadata and `PHAsset.localIdentifier` only. |
| 5 | **Never delete from the user's Photos library.** Memoree has add-only permission and must behave that way. See ADR-008. |
| 6 | **Dark only.** No `colorScheme` branch. No light mode. Canvas is `#000000` exactly. |
| 7 | **No watermark, ever.** |
| 8 | **No filters, crop, or retouch.** |
| 9 | **Never write to Photos unless the user captured in this app in this session.** |
| 10 | ~~Capture must not be possible before the moment time.~~ **Superseded by ADR-023** — capture is permitted at any time, and every moment counts. The two-minute window now decides only when the notification fires. |

## 3. Architecture

Strict layering. Violations fail review.

```
Features/     → may import Models, Persistence, DesignSystem, Services, Support
Services/     → may import Models, Support.  NEVER imports Features. NEVER imports SwiftUI.
Persistence/  → may import Models
Models/       → imports nothing internal
DesignSystem/ → imports nothing internal
Support/      → imports nothing internal
```

- **`Services/` must not import SwiftUI.** Camera and Photos services have no idea a UI exists.
  They publish state; the UI observes it.
- **Every service is a protocol** with a production implementation and a test double. Services
  that cannot be faked are services that cannot be tested.
- **`Features/` contains SwiftUI views and view models only.** No AVFoundation, no PhotoKit.

Targeted exceptions to "no SwiftUI in Services" — `PhotoKitLibrary` imports `Photos`,
`SequentialCaptureService` imports `AVFoundation`. Neither may import `SwiftUI`.

## 4. Naming

| Thing | Convention | Example |
| --- | --- | --- |
| Types | `UpperCamelCase` | `MomentScheduler` |
| Properties, methods, locals | `lowerCamelCase` | `momentStart` |
| Protocols | Noun, no `I`/`Protocol` suffix | `PhotoLibraryService` |
| SwiftUI views | `...View`, plain | `TodayView` |
| View models | `...Model` | `TodayViewModel` |
| SwiftData models | Domain nouns | `Moment`, `DayRecord` |
| Constants | `lowerCamelCase` static | `Theme.canvas` |
| Booleans | Read as assertions | `isLate`, `hasBTS`, `albumCreationAttempted` |
| Time | Spelled out, never `s`/`ms` bare | `windowDuration`, `lateBy` |
| Days | `dayIdentifier`, string `"2026-09-30"` | — |

Never abbreviate `identifier` to `id` on persisted models — `id` is the primary key, the domain
identifier is `dayIdentifier`. Conflating them has already caused one bug in a similar project.

## 5. Swift 6 concurrency

Strict concurrency is on. These are the settled patterns; do not reinvent them.

**AVFoundation is not `Sendable`.** The standard approach:

```swift
final class CaptureSessionController: NSObject, @unchecked Sendable {
    // All mutable state is confined to `queue`. Justification is written here.
    private let queue = DispatchQueue(label: "capture.session")
}
```

- `@unchecked Sendable` is permitted **only** on types that own a single serial queue and
  confine all mutable state to it. A one-line justification comment is mandatory.
- **Never configure `AVCaptureSession` on the main thread.** Not once, not "just for the
  preview."
- UI-facing state is published through an `@MainActor` observable adapter. The capture layer
  never imports SwiftUI and never touches `@Published` directly.
- Bridge delegate callbacks with `withCheckedThrowingContinuation`, resumed **exactly once**.
  Create a fresh delegate object per capture and drop it afterwards to avoid retain cycles
  through the capture session.

## 6. Error handling

- Typed errors, one per domain: `enum SchedulerError`, `enum CaptureError`,
  `enum LibraryError`. `LocalizedError` conformance for user-facing copy.
- Never `fatalError` in a path reachable from user input. It is acceptable only for
  programmer error caught by a unit test.
- Every error path has a recoverable UI state. There are no dead ends.
- **`AVCaptureSession.mediaServicesWereReset` has no callback and no log line** — the preview
  simply freezes. It must be handled, and it must be reachable from a debug menu to test.

## 7. Camera specifics

Established facts. Re-deriving these wastes days.

- **Sequential, not multi-cam.** Rear capture → reconfigure session → front capture → restore
  rear. ~0.3–1.0s. See ADR-003.
- **Wait for a real delivered frame after the input swap** before capturing the front photo. A
  fixed sleep is the first thing that will flake under load.
- **`sessionPreset` is unreliable across an input swap.** Use `.inputPriority` and set
  `activeFormat` explicitly. Target 3:4, widest supported, `.builtInWideAngleCamera`.
- **Front mirroring is set on the connection**, not by transforming pixels:
  `connection.isVideoMirrored = true`. `fileDataRepresentation()` already reflects it.
- **`maxPhotoDimensions`**, not the deprecated `isHighResolutionPhotoEnabled`.
- **The simulator has no camera.** Every capture change must be verified on hardware.

## 8. Photos library

- **Add-only authorisation.** Never request `.readWrite`. Never enumerate the library except
  for asset identifiers the app already owns.
- Both assets are created inside **one** `performChanges` block. A half-written moment is a
  broken invariant.
- `fileDataRepresentation()` already carries capture EXIF — write those bytes rather than
  re-encoding. Inject GPS by round-tripping `CGImageSource` → override the GPS dictionary →
  `CGImageDestination`.
- **Never `CLGeocoder`.** Coordinates are stored, never resolved to a place name.
- Orphaned assets (user deleted them in Photos) are tombstoned, not repaired.

## 9. Notifications

- **45-day rolling horizon**, refilled below 20 pending. iOS caps pending local notifications
  at 64; this margin is deliberate.
- `UNCalendarNotificationTrigger` with explicit wall-clock components. **Never** a time interval
  trigger — it drifts across DST and timezone travel.
- Identifier format: `moment.<dayIdentifier>`. Always
  `removePendingNotificationRequests(withIdentifiers:)` before re-adding a specific request.
  **Never `removeAllPendingNotificationRequests()`.**
- Declined notifications are a supported state, not an error. The app must remain fully usable
  without them, because nothing can re-notify the user.

## 10. Tests

- **Pure logic gets unit tests, exhaustively.** The scheduler (golden HMAC vectors), streaks
  (table-driven), day identifiers (DST and timezone round-trips), state resolution.
- **Streak and statistics arithmetic operates on value types, never on SwiftData models.**
  `Moment` is not `Sendable`, and a managed object's fields can change underneath a pure
  function. Snapshots (`MomentFacts`) are the boundary; `MomentStore` does the mapping.
- **Every service protocol has a test double.** UI tests use them; no test should need a real
  camera or a real photo library.
- **Device-only behaviour is documented as such** in the test name, so nobody wastes an hour
  debugging it in the simulator.
- The invariant "no networking type is reachable from app code" should be asserted by a test,
  not merely intended. `docs/TRD.md` §13.

## 11. Design system

Use tokens from `DesignSystem/Theme.swift`. Never hardcode a hex value in a view.

| Token | Value | Reserved for |
| --- | --- | --- |
| `canvas` | `#000000` | Every screen background. Exactly black. |
| `surface` | `#1C1C1E` | Cards, sheets, rows |
| `surfaceElevated` | `#2C2C2E` | Pressed states, chips |
| `textPrimary` | `#FFFFFF` | Titles, primary actions |
| `textSecondary` | `#8E8E93` | Timestamps, metadata |
| `accent` | `#FFD60A` | **The only** amber, and the app's single accent. One use: a declined permission the user can only restore in system Settings (ADR-025) |
| `destructive` | `#FF453A` | Delete confirmation only |

There is no brand hue. White is the verb. If you find yourself reaching for a second colour,
re-read `docs/DECISION_LOG.md` §10.

The countdown uses **tabular figures** so digits do not jitter.

**The amber has exactly one job**, reserved for a permission the user declined and cannot fix
inside the app. It used to mean "late", and it no longer does — an off-window moment is
deliberately indistinguishable from an on-time one, so there is nothing for it to warn about
(ADR-023, ADR-025). If you want amber to mean lateness again, that is a new ADR with a written
reserved job, not a reuse of this one.

## 12. Before you commit

- [ ] Builds clean, zero warnings
- [ ] No new dependency
- [ ] No `URLSession`, `URLRequest`, `NWPathMonitor`, or web view
- [ ] No `@unchecked Sendable` without a justification comment
- [ ] No `fatalError` in a user-reachable path
- [ ] No hardcoded colours or spacing
- [ ] New logic has tests; DST and timezone cases considered
- [ ] **Verified on a physical device** if camera or Photos behaviour changed
- [ ] Airplane mode still passes the full loop
- [ ] Any new architectural decision is written into `docs/DECISION_LOG.md` with its
      alternatives and a reversal trigger

## 13. Working on this repo

- **Docs are not optional.** If behaviour changes, `docs/TRD.md` changes in the same commit.
  A stale TRD is worse than none.
- **Decisions are immutable.** Do not edit an ADR. Supersede it with a new one and mark the old
  `Superseded by ADR-nnn`. The reasoning history is the valuable part.
- **Cite sources in PR descriptions** when behaviour is derived from research rather than
  preference. `docs/PRD.md` §11 lists the primary sources.
- **Flag uncertainty.** If something was not verified, say so in a comment. Do not present
  inference as established fact.
- **Prefer removing code to adding it.** The entire premise is that most of BeReal is
  unnecessary. That instinct is usually right.
- **Talk to the user plainly.** Short messages, plain words, no ceremony. Say what happened and
  what is needed next, then stop. Long essays are for `docs/` and commit messages, not for the
  conversation. If something did not work, one sentence on what and one on why is enough.
