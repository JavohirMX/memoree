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

## Phase 1 — Models and the moment scheduler ✅

**This is the highest-risk logic in the app. Do it before any UI.**

> **Status: complete; the plan had simply never been marked.** The exit criterion
> is met — a real notification is pending at a correct, plausible, stable time,
> and it does not move across relaunches.
>
> One promised item was missing, and the reason it was missing is the useful
> part: the **refill invariant test** could not be written, because the horizon
> decision was interleaved with `UNUserNotificationCenter` calls and the system
> centre cannot be subclassed into a test double. The decision was therefore
> unobservable, and the test stayed unwritten through two refactors and four
> phases. It is now `NotificationHorizonPlanner` — a pure function over value
> types — with the invariant asserted at 0/19/20/64 pending.
>
> `NotificationService` also had no test double at all, and could not have had
> one: `TodayViewModel` and `OnboardingView` both read the real status through
> `as? UserNotificationService`, so a double was not merely absent but
> *unreachable* — every test took the "not the production type" branch while
> appearing to exercise the real path. The status is now
> `NotificationAuthorization` on the protocol, matching the pattern the camera
> and Photos services already use.

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

#### What the device runs actually found

Five hardware runs, each of which found a real defect that twelve simulator tests could not. The
order matters: each fix exposed the next, and two of the "fixes" were regressions that the
hardware caught immediately.

| # | Symptom | Cause |
| --- | --- | --- |
| 1 | `noInputAvailable(.back)` ×5 | Selector rejected all 57 formats — sensors are natively landscape (ADR-019) |
| 2 | `Cannot Record` ×19 | `maxPhotoDimensions` from a stale device lookup rather than the attached input's active format |
| 3 | one timeout, then a cascade | A failed pair left the session mid-swap; every later attempt failed |
| 4 | `noInputAvailable(.front)` ×20 | **Regression.** `canAddInput` moved outside `beginConfiguration`, where it always returns NO |
| 5 | `noInputAvailable(.front)` ×20 | **Regression.** `canAddInput` moved *before* `removeInput`, where a session holding one video input refuses a second |

**`canAddInput` has two constraints, and both were violated before one was satisfied.** It must
be called *inside* `beginConfiguration`, and *after* the outgoing input is removed. The
"check first so a refusal leaves the session untouched" instinct is wrong: a session already
holding a video input will not accept a second from a different device. Recovery from a
refused swap comes from the session rebuild in `capturePair`, not from the ordering.

**The frame-wait deadline, set from measurement rather than taste.**
`FrameWaitDiagnostics` performs 40 swaps on a real iPhone 17 with no photo capture between
them:

```
min 0.421s · median 0.472s · p90 0.809s · max 0.815s · 0 failures in 40
```

An idle swap-and-wait is half a second and never approaches the old two-second deadline. But
in the real sequence the swap follows a **photo capture**, and `AVCapturePhotoOutput` and
`AVCaptureVideoDataOutput` share the session — frames pause while a photo is processed. That
is exactly where the reliability loop failed: 2 in 20 against 0 in 40 isolated. The deadline is
now 5s, about six times the worst idle observation. The cost is paid only when the camera is
genuinely dead, and it buys headroom against a photograph that looks fine and is wrong forever.

**The lesson worth keeping.** Every defect above was found by *running*, and none by a test
asserting on a value. The tests that should have caught them asserted on hand-built fixtures
that encoded the same wrong assumptions. A suite built from invented data is a description of
what someone believed. `CameraDiagnostics` and `FrameWaitDiagnostics` exist so the next
question is answered by a measurement instead of by inference from an error string.

### Progress as of 2026-10-01 — three device runs, and the gate is still unmeasurable

**Read this before spending another device run on Phase 4.** Three runs happened, each failed
differently, and the third failed differently *after* a fix that was verified to work. That is
the signature of an unreliable harness, not a regression, and the two obvious fixes each break
something else.

| Run | What happened |
| --- | --- |
| 1 | Whole suite, 163 tests. `twentyPacedMoments`, `mirroringIsCorrect`, `capturedPairWritesToPhotos` all failed. **The reasons were lost** — the result bundle was corrupt (`mkstemp: No such file or directory`) and the log was truncated by a `tail -120` |
| 2 | Capture + Photos suites only, full log. `twoPressesProduceAPair` failed with `configurationFailed("Cannot Record")`, then the daemon died (`connectionDied`, `err=-16453`) and the 20-run test completed **zero** iterations before the process was killed |
| 3 | Same suites, with one shared service. **`twoPressesProduceAPair` passed in 2.8s, both orders, 4032×3024.** But `sessionRebuilds` took **200.8s** (was 0.583s) and everything after it was degraded. Run abandoned |

**The root cause of all three: session allocations per process.** `AVCaptureSession.init()` is a
*synchronous* XPC round-trip to the capture daemon (`FigCaptureSessionRemoteCreate`). One device
run of this suite allocates **eight** sessions back to back, each released before the next. The
twenty-moment loop was fixed for exactly this on an earlier day — and the fix **was not applied
to the other seven call sites**. That is the same shape as ADR-019's format selection: a correct
fix applied where the symptom appeared and nowhere else.

**Run 3's fix worked, and then broke something else.** Sharing one service across the suite fixed
the allocation problem outright. It failed because `rebuildSession()` allocates a *new*
`AVCaptureSession` **by design** — replacing a dead one is its entire job — so on a shared service
it runs against a session previous tests have already started and stopped. 0.583s on a fresh
service, **200.8s** on the shared one.

**So the two candidate fixes each break something:**

- **Per-test services (current).** Correct isolation, eight allocations, daemon wedges, gate
  measures nothing.
- **One shared service (tried, reverted).** One allocation, two-press test green — but the
  destructive test destroys the shared instance for everything after it.

### Decided 2026-10-01 — the gate runs alone, in its own `xcodebuild`

**`Scripts/capture-gate.sh`.** Option 3. One allocation, which is the shape that is known to
work, and **nothing in production code changed to suit a test**.

- **Not option 1** (split across two test processes) because Swift Testing cannot do it — it
  needs a second scheme or a UI test target, so it is the most machinery for the least certainty.
- **Not option 2** (reuse one controller, reset between tests) because that changes
  `rebuildSession` to suit a test, and `rebuildSession` is doing real work handling
  `mediaServicesWereReset`. "Closest match to the app" is a virtue only when the app already
  does the thing.

The cost is a second invocation per device run — measured in seconds, against the
twenty-minute runs that three failed attempts cost.

**And the runner proves the gate ran.** `-only-testing:` with a misspelled identifier matches
nothing and xcodebuild reports `** TEST SUCCEEDED **` with exit code 0. **Verified on this
machine, deliberately, with a typo**, because this project has been bitten three times by
something that looked like a pass and asserted nothing: four Phase 3 tests that "passed" in a
millisecond, and a twenty-moment run that reported zero iterations as if it had finished. The
script greps the output for the gate's own name and fails if it is absent, and reports a third
state — *inconclusive* — when the name is present but the run did not exit cleanly, so an
interrupted run is never reported as a pass.

**The other seven tests are unaffected** and still run in the normal device invocation. The
allocation problem only ever made the *gate* unmeasurable; the cheaper tests are what runs 1
and 2 were trying to fix, and they do run.

**A lesson about process, which cost three device runs.** Run 1's failure reasons were lost to a
corrupt result bundle, so run 2 was scoped identically and spent another twenty minutes learning
the same thing. Run 3 then re-ran the *whole* suite to verify a fix that the three-second
two-press test demonstrates on its own. Both were avoidable and both were mine: **when a
hypothesis has a three-second test, run that test.** A device run is the most expensive
instrument in this project and the least precise one, and a scoped re-run answers the question in
minutes rather than twenty.

**Not landed: no change to `LiveCaptureTests`.** It is back to per-test services, with the
findings recorded in the suite's own documentation so the next person does not re-derive them
from three failed runs.

### The one real product bug this did find

**The app let the screen lock during a capture.** Nothing anywhere set
`isIdleTimerDisabled` — confirmed by `grep`, not assumed. A user composes a shot, the display
dims, the device locks, iOS tears the session down, and the photograph is gone — with no error,
because there is no error to report when the app was suspended.

It is also, almost certainly, why the runs report a dead daemon: **a test host is a normal app and
locks on the normal schedule**, and a twenty-moment run is longer than that schedule. Run 1 had to
be retried from scratch because the phone was locked at launch.

**This is fixed and landed.** Scoped to the camera screen's appearance rather than the app's, and
restored on `onDisappear` so a cancelled capture does not leave the display pinned on. Holding it
on the Today screen would drain a battery to show a streak.

### Still outstanding for this phase

- ~~The human mirroring verdict, which only a person can give.~~ **Verified 2026-10-01:**
  the selfie reads as a mirror. That was the one check in this phase that no
  automated test could stand in for, and it is closed.
- **A green twenty-moment run — parked at 18/20 on 2026-10-01.** See below.

### Parked 2026-10-01 — 18/20, and what the five attempts actually found

The gate runs now (`Scripts/capture-gate.sh`) and it measures. It does not pass.

| Attempt | Change | Result |
| --- | --- | --- |
| 1 | none | 16/20, 4 timeouts, all `front→back` |
| 2 | configure the device before attaching | **6 timeouts.** Worse. Reverted. |
| 3 | `framesSeen` counter | `seen=0` on every timeout — the output delivers *nothing* |
| 4 | stop / reconfigure / restart the session | **18/20.** One timeout left. |
| 5 | sample session state at the deadline | Frame waits clean, but the **capture daemon died** |

**The finding, and it unifies everything above.** Attempt 5 produced a log full of
`FigCaptureSessionRemote: storage->connectionDied` and `err=-16453` — the capture
subsystem itself had died, at moment 3 of 20. Everything after failed with
`photoDataUnavailable` because no photo callback arrives from a dead daemon.

**When the daemon dies you get zero frames.** So the `noDeliveredFrame` timeouts
that attempts 2–4 chased were never a frame-wait bug, a port-matching bug, or a
format-ordering bug. They were the symptom of a dead capture subsystem, and
attempts 2 and 3 were fixes for problems that did not exist.

**Attempt 4 is kept.** Stopping the session to swap is measurably better — 0 frame-wait
timeouts where there were four — and it costs 0.3–1.0s on a swap a user performs
twice a day. But it also **triples the session transitions**, and 20 moments now
mean ~60 start/stop/reconfigure cycles. Whether that is what killed the daemon, or
whether the device was simply warm after five back-to-back runs, was not
established — a cold single run would separate them and was not done.

**What is actually known, stated plainly:**

- The capture mechanic works. 18 of 20 paced moments captured a valid 3:4 pair.
- The failures are intermittent hardware/subsystem timing, not a logic defect.
- A user swapping cameras **twice a day** will not reproduce a gate that swaps
  **forty times in six minutes**.
- The daemon death is **uninvestigated**, and attempt 5's log is the evidence for
  it. Anyone picking this up should start there, not with the frame wait.

**What is deliberately not done.** The frame-wait instrumentation is kept and
prints a `CAUSE:` line naming the mechanism — `SESSION STOPPED`,
`STALE CONNECTION`, `STALLED EARLY`, or `OUTPUT PARKED` — because it is what turned
a symptom into a measurement, and the next person needs it. **No threshold was
loosened to make the gate pass.** The gate says 18/20 and the plan says 18/20.

**The lesson, and it is the same one this phase has now taught three times.** Attempt 2
was a prediction from reading code with nothing measured. It made things worse.
Attempt 3 measured *that* the output was silent but not *why*, and attempts 3–4
were still working from the symptom. Only when the diagnostic asked "is the
subsystem alive" rather than "are frames arriving" did the real cause appear — and
it was in a log line that had been present in an earlier run and been read as noise.

**This phase's exit criterion is not met, and the gate is the honest instrument for
that.**

**Cosmetic, recorded so it is not rediscovered as new:** every device run logs
`[SwiftUI] Invalid frame dimension (negative or non-finite)` — 146 times in one run. It fires at
launch, before any test starts, and is present in the build from before this session's changes,
so it is not a regression. A layout pass is producing an impossible frame somewhere in the root
view; worth finding on its own account, and harmless today.

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

### Progress as of 2026-10-01 — the sixth device run found the one that mattered

Phase 3 is **closed**: all four live Photos tests pass on an iPhone 17. Phase 4's exit
criterion ran, and found two more defects that eleven phases of simulator testing could not.

**The camera worked exactly once per app launch.** `configureSession` called
`canAddOutput(photoOutput)` and then `addOutput(photoOutput)` on *every* `startSession`.
`stopSession` stops the session but never removes outputs, and `AppEnvironment.captureService`
is a single cached instance for the life of the process — so the second time the camera screen
was opened, both outputs were already attached, `canAddOutput` returned false, and the guard
threw `configurationFailed("photo output rejected")`. The 20-iteration loop hit it on
iteration 2; nineteen of twenty moments failed.

The message names the photo output and points at authorisation, when the camera is present,
working, and already configured.

**Why nothing caught it, which is the part worth keeping.** The *inputs* were handled correctly
the whole time — `attachInput` removes the outgoing input before attaching the new one — so the
defect is an asymmetry, not an error, and no single code path looks wrong. It exists only
*across* two sessions. Twenty-seven capture tests passed because the simulator has no camera and
therefore never re-enters the path. It took someone opening the camera twice on real hardware.

**The 20-run loop was itself wrong, and fixing it hid nothing.** It constructed a new
`SequentialCaptureService` per iteration, which meant twenty `AVCaptureSession` allocations.
Constructing one makes a *synchronous* XPC round-trip to the capture daemon
(`FigCaptureSessionRemoteCreate`), and twenty of them in a background test process tripped the
watchdog: `0x8BADF00D`, "Failed to terminate gracefully after 5.0s", main thread parked inside
`_createFigCaptureSession`. That loop was testing a shape the product never runs — the app has
one session for its whole life. It now reuses one service, which is not a way to dodge a crash
but the only shape the app is ever in.

**`ensureAlbum` created a duplicate album on every call** (Phase 3). It searched for an existing
album with `fetchAssetCollections(withLocalIdentifiers: [])` — a fetch for *zero* identifiers,
which returns nothing, so the "find existing" branch was dead code. Invisible in the app because
`saveToAlbum` defaults to off and no production path reached it. Two layers of "not shipped"
hid a defect the first real invocation exposed.

**A lesson about the diagnostic suites.** `CameraDiagnostics` took 158 seconds in one run and
0.021 in the next, on the same build. It is a printout, not a gate — as this plan says — and
including it in a routine run cost more wall time than the entire rest of the suite. Excluded
from the standard device run; keep it for when the next unexplained failure needs those lines.

**Outstanding:** the human confirmation that the front image is mirrored and the rear is not. The
mirroring test asserts the mechanism held rather than claiming a visual verdict — a selfie is
close to symmetric, so only a person can confirm it reads as a mirror. The Today screen's
composite is finally somewhere to look at one.

**How to run it, and why the flags are not optional:**

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -project Memoree.xcodeproj -scheme Memoree \
  -destination 'platform=iOS,id=<your device>' \
  -only-testing:MemoreeTests/LiveCaptureTests \
  -only-testing:MemoreeTests/LivePhotoLibraryTests \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=MBBD9BRZ67 \
  -collect-test-diagnostics never
```

Two device-specific lessons are baked into that command. `DEVELOPMENT_TEAM` is `MBBD9BRZ67`,
read from the certificate's `OU` — not `MBB9BRZ67`, which differs by one character and is what
`project.yml` said for five phases. A simulator build never signs, so the wrong value passed
every test in the project. And `-collect-test-diagnostics never` because when a test *fails*,
xcodebuild collects a sysdiagnose from the host before exiting, which on a device hangs
indefinitely with no output and reports `BUILD INTERRUPTED` — destroying the exit code that
would have said the run had finished. It reads exactly like a frozen test run.

### Progress as of 2026-10-03 — the death was survivable all along, and the gate was measuring the harness

**Two findings, and the first one is about the instrument rather than the capture path.**

#### The gate had been reporting a locked phone as a capture failure

The first run of the day returned **0/20 in 0.12 seconds**. Every moment failed instantly with

```
<<<< AVCapturePhotoOutput >>>> Fig assert: "hasFigCaptureSession" at bail (AVCapturePhotoOutput.m:596)
configurationFailed("Cannot Record")
```

`hasFigCaptureSession` means the photo output had **no session behind it at all**. Nothing had
started: `FRAME-WAITS (0)`, `SESSION-REBUILDS 0`, twenty identical failures at about 4ms each.
That is not a camera failing. That is a guard rejecting everything on sight.

The cause is the harness. `xcodebuild test` builds, installs and *then* runs, and the build and
install take **four and a half minutes** on this machine. This document has already recorded
that a test host is a normal app that locks on the normal schedule — *"a test host is a normal
app and locks on the normal schedule, and a twenty-moment run is longer than that schedule"* —
and attributed the earlier daemon deaths to it. Same fact, and it was costing the gate its
meaning in a way indistinguishable from a capture defect.

**`Scripts/capture-gate.sh` now builds first, then stops and waits for a human.** The window in
which the phone must be awake drops from four and a half minutes to the length of the run, which
is about two. `MEMOREE_GATE_ASSUME_AWAKE=1` skips the prompt for an already-orchestrated run.
Confirmed immediately by the cheapest possible test — `twoPressesProduceAPair`, the three-second
one — which passed at 4032×3024 in both orders on the same build.

#### The daemon death is real, reproduces cold, and the app now survives it

With the phone genuinely awake, the gate measures again. **19/20, `SESSION-REBUILDS 1`,
19 frame waits and 0 timeouts.**

The frame-wait number is the one that closes a two-week-old argument: **every frame wait was
clean.** Four attempts' worth of tuning had been spent on a mechanism that produced zero
timeouts in a full run. It was never the problem.

The daemon still dies, and it is now timestamped rather than reconstructed:

```
14:03:05.501  << FigXPC >> signalled err=-16155
14:03:05.501  FigCaptureSessionRemote  "! storage->connectionDied"  err=-16405
              FigCaptureSourceRemote   "! storage->connectionDied"  err=-16453   (×119)
```

**It is not thermal and it is not the lock.** This was a cold device, 37 seconds into the run,
after five successful moments. And it is not the frame wait, which was clean throughout.

What changed is what happens next. Moment 18 failed with `photoDataUnavailable(.back)`, the
recovery rebuilt the session once, and **moments 19 and 20 captured correctly.** Previously the
daemon's death ended the run: every later moment failed identically for the life of the process,
behind a **Try again** button that could not work.

**A detail that argues the death is survivable more often than not.** The connection died twice
in this run — once after moment 5, and once before moment 18 — and moments 6 through 17 all
succeeded across the first one. iOS re-established the XPC connection and the existing session
carried on. Only the second death was not self-healed. So the honest description is not "the
daemon dies and the camera dies": it is **the daemon's connection drops, usually recovers on its
own, and occasionally does not** — and the recovery is what covers the occasions that do not.

#### The second run found a worse bug, and it was not the one being investigated

The next run returned **8/20**, and its failure signature was new:

```
moment  5: noDeliveredFrame(.back)
moment  6: configurationFailed("Cannot Record")
moment 11: photoDataUnavailable(.back)
moment 12: configurationFailed("frame-signal output rejected")
moment 13: configurationFailed("frame-signal output rejected")      …and so on, to 20
SESSION-REBUILDS 2
```

**Two rebuilds where the first run had one.** The daemon dropped twice, so `rebuildSession` ran
twice, and the second one left the camera dead *in a different way* — not dead-subsystem, but
`frame-signal output rejected`, forever.

The cause is a line of `rebuildSession` that had been there since Phase 4:

```swift
session = replacement
photoOutput = AVCapturePhotoOutput()      // replaced
videoOutput.alwaysDiscardsLateVideoFrames = true   // NOT replaced — the old object is reused
```

**An `AVCaptureOutput` belongs to exactly one session and cannot be migrated.** The frame-signal
output stayed attached to the doomed session, so `canAddOutput` on the replacement returned
**false** — and because nothing ever replaced the object, every subsequent `configureSession`
threw for the life of the process. **One dead capture subsystem turned into a permanently
bricked camera, which is the exact failure `rebuildSession` exists to end.**

It read like an oversight because it *was* one, and it survived two weeks of device runs because
reaching it required a swap to fail *and* a rebuild to already have happened. A single-rebuild run
looks perfect. The gate only found it because the daemon happened to drop twice.

**And this is the second time today that a defect presented as one thing was another.** The first
was a locked phone reported as a capture failure. Both were found by the gate measuring
something other than what it was pointed at.

#### Where this leaves the gate

Three runs, same build of the app except where noted:

| Run | Result | `SESSION-REBUILDS` | What actually happened |
| --- | --- | --- | --- |
| 1 | 0/20 in 0.12s | 0 | Phone locked during a 4.5-minute build. Nothing started. |
| 2 | **19/20** | 1 | One daemon death, recovered, moments 19–20 fine. Frame waits **19/19 clean**. |
| 3 | 8/20 | 2 | Two daemon deaths. The second hit the output-migration defect above. |

**The gate's result tracks how many times the daemon drops, and nothing else.** One drop costs
one moment. Two drops cost twelve. That is the whole variance, and it is a property of the
device's capture subsystem rather than of this code — with one exception that was a real bug and
is now fixed.

**Still not 20/20, and the threshold has not moved.** But the number now means something
different: it is no longer "two flakes and a dead camera", it is "one moment lost per daemon
death, and the camera comes back". Whether that is the right exit criterion is a decision for
the user, not something to settle by editing the threshold.

**Phase 4 remains open at 19/20**, by decision. The criterion is met in the sense that the app
now behaves correctly and the cause is understood and survivable; it is not met in the literal
sense that twenty captures have not all succeeded unprompted. Both facts are recorded rather
than reconciled, because reconciling them would mean moving the threshold.

#### The gate now retries, because the product does — ADR-028

The gate and the product had started to disagree about what a failure means. The gate
records one and moves to the next moment. The product shows **Try again**, the user presses
it, and since ADR-027 that press runs against a live session. **So the gate was counting a
self-healed failure exactly as heavily as an unrecoverable one.**

A moment that fails with `indicatesDeadCaptureSubsystem` is now retried once, from the
shutter — the whole moment, not the step that failed, because a moment that died during its
first capture leaves a different session state from one that died after the swap, and a user
starts over from the shutter rather than from halfway.

**Three things this deliberately does not do**, and each is the point:

| | |
| --- | --- |
| **It does not lower the bar** | A moment that cannot be captured after the retry is still a failure and the test still fails |
| **It is narrower than the retry button** | Only a dead subsystem earns a second attempt. `noInputAvailable` and `configurationFailed` are exactly as true on the next try |
| **It does not hide the retries** | `needed the retry` is printed unconditionally beside `SESSION-REBUILDS` and `FRAME-WAITS summary` |

That last one is what keeps it honest. **A run where twenty moments succeeded because the
recovery worked must not read like a run where twenty moments succeeded first time.** A
reader can now tell them apart, and the reversal trigger in ADR-028 says what would make the
whole mechanism removable: three consecutive cold runs at 20/20 with no retry and no rebuild.

#### A run that hung for eighteen minutes, on a defect I had written off

The next run did not finish. It printed **twelve moments and then went silent** — the last log
line at `14:50:34`, the kill at `15:09:05`, no summary line. Moment 13 never returned.

The retry did what ADR-028 says it should, first:

```
CAPTURE moment  9/20 dead subsystem (photoDataUnavailable(.front)) — retrying once, as a person would
CAPTURE moment  9/20 FAILED: configurationFailed("Cannot Record")
```

It retried, and the retry failed too, and the moment was recorded as a failure. **That part is
correct.** Moment 10 also failed, moments 11 and 12 succeeded, and then moment 13 hung.

**The hang is in `startSession`, and it is not the rebuild.** `session.startRunning()` is called
on the session queue inside a `withCheckedThrowingContinuation` with **no deadline**. When the
capture daemon is wedged rather than merely slow, `startRunning()` blocks that queue, the
continuation is never resumed, the `await` never returns, **and every other capture operation
queues behind the same serial queue** — so the camera screen is not merely stuck, it is
permanently unresponsive with no error and no way out.

**This project already wrote the rule that forbids it, fifty lines above the defect, in the same
file.** `frameWaitTimeout` and `photoWaitTimeout` both exist because *"an un-resumed
continuation hangs the app rather than failing it."* `startSession` has neither.

**And this is the reversal of a claim made two hours earlier.** ADR-027 named the slow-rebuild
risk, observed two fast rebuilds, and I wrote that the concern was *"retired rather than merely
unproven."* It was not retired. It was **mislocated**: the risk was never the rebuild being
slow, it was that **nothing on the path into a running session has a deadline at all.** A note
in the same ADR already said the evidence was one observation — it was two, and I treated that
as enough to close the question. It was not, and closing it is what made this run the one that
found it.

**Fixed the same day, and the established pattern did not transfer — which is the
interesting part.**

`frameWaitTimeout` and `photoWaitTimeout` are armed with `queue.asyncAfter` **on the session
queue**, which works because the queue is idle while it waits. `startRunning()` is not idle:
it *occupies* that queue and blocks there, so a deadline scheduled on it cannot run until the
call returns — which is the case the deadline exists to catch. **The one mechanism this file
had for bounding a wait was structurally incapable of bounding this one.**

So the deadline is armed on a separate queue and arbitrated by `ResumeGate`, a small
lock-guarded exactly-once gate, rather than by a queue-confined pending slot. Five seconds,
matching the frame wait for the same measured reason — the worst idle observation across forty
swaps on an iPhone 17 is 0.815s, so six times that is a number chosen so being wrong means the
daemon is genuinely gone. The gate is armed **before** the queue is asked to do anything, so
the clock runs while `configureSession` does.

**`ResumeGateTests` covers what a device run cannot produce on demand.** A wedged daemon needs
hardware and twenty minutes and cannot be made to hang deliberately. The gate is pure
concurrency with no AVFoundation in it, and its one way to be wrong **traps** rather than
fails — a `CheckedContinuation` resumed twice. So 200 iterations race the work against the
deadline and assert the settle count is exactly one every time; zero hangs the caller, two
traps. Also pinned: a success is not undone by a deadline firing afterwards, and an unfinished
call surfaces the timeout error rather than hanging.

**One test deliberately does not exist.** `arm` guards a double-arm with a `precondition`,
which traps — correct for a programmer error, and `AGENTS.md` §6 permits a trap only where a
unit test catches it. **Exercising it would take the whole suite down**, so the test that would
prove it is not written; what is pinned instead is the property that would trap in production,
which is that *settling* an already-settled gate is a no-op rather than a second resume.

**What this does not fix, stated plainly.** The session queue is still held by the blocked
`startRunning()`. The user now gets **"the camera did not start within 5 seconds"** instead of
an indefinite spinner, and can leave the screen — but the session is not usable until the
process restarts, because the recovery path (`rebuildSession`) needs the same queue. **This is
a bounded, reported failure where there was an unbounded silent one.** It is not recovery, and
`AGENTS.md` §6's "no dead ends" is satisfied by the error and not by the camera working.

**The remaining piece, precisely.** Recovery means the timeout abandons the wedged queue and
rebuilds on a **fresh** one — a new `DispatchQueue` and a new `AVCaptureSession` swapped in
together. The hazard is exactly-once resumption: the abandoned closure must not touch shared
state or resume again once its continuation has been settled, which means it has to capture its
own session and queue rather than reading `self.session`. That is a change to the concurrency
core of the most safety-critical file in the project, and it is not something to write on the
same day as finding the bug.

**And `stopTimeout` is declared at the top of the file and never used** — the same unbounded
shape on the stop path, noticed once by someone and left unwired. Recorded rather than deleted,
because the number has a job to do whenever the stop path gets the same treatment.

#### What this does not settle

**Why the daemon drops is still unknown.** `-16155` on `FigXPC` precedes every death and is not
explained. It is now reproducible on demand on a cold device, which is the most this phase ever
had: five attempts failed to produce one clean observation of the event.

**19/20 is not 20/20, and the gate's criterion has not been met.** The threshold has not been
moved — `AGENTS.md` §13 asks for uncertainty to be flagged rather than presented as fact, and
this section is not a claim that it has. The remaining failure is the daemon dying *during* a
capture, which no app-side code can prevent.

**But the gate and the product now disagree about what a failure means.** The gate records a
failure and moves to the next moment. The product shows **Try again**, and the user takes it —
and after the recovery that retry now succeeds. The gate never presses it, so it counts a
self-healed failure exactly as heavily as an unrecoverable one. Making the gate retry the way a
person would is a change to what the gate *measures*, not a loosened threshold, and it needs to
be decided explicitly rather than adopted because it produces a green number.

#### ADR-027 and one risk in it, still unproven

`ADR-027` records the recovery and its reversal trigger. The risk it names did **not**
materialise: the rebuild did not hang, and the run took 128 seconds — roughly a third of the
six minutes the gate is documented as taking. `rebuildSession()` against a dying daemon was fast.
That is one observation, not a guarantee, and the ADR says so.

**Also unchanged and still unexplained:** `[SwiftUI] Invalid frame dimension (negative or
non-finite)` fires at about 1/second for the whole run, not only at launch as previously
recorded. Still harmless, still not found.

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

### Open — the window is a reminder, not a deadline (ADR-023)

**Found by opening the app.** At 09:34 on a day whose moment was at 16:00 there was no shutter at
all: `MomentState.allowsCapture` is false for `scheduled`, and `TodayView` renders the shutter
only when it is true. The behaviour was correct as written — `AGENTS.md` §2 rule 10 said so,
`FR-5` said so, and three places asserted it — but the onboarding copy says *"Without this you can
still open the app and capture whenever you like."* The app was contradicting its own first-run
screen, and nobody found it except a person trying to photograph something.

**Decided (ADR-023), revised the same day:** capture at any time; an off-window moment neither
grows nor breaks the streak; a day with **no moment at all** breaks it; no badge and no
explanation. This reverses ADR-009, which is marked superseded.

**Not yet implemented.** In order:

| # | Task | Note | Done |
| --- | --- | --- | --- |
| 1 | **Decide what the countdown means** | **Blocking, and it is a copy question.** `mm:ss` reading "1:47 remaining" implies a deadline that no longer exists and that now costs the user their streak. Either it goes, or it counts down to the *reminder*. A ticking number that lies is worse than no number — and this one would lie *and* have consequences. | **ADR-024** |
| 2 | `MomentState.allowsCapture` → always true | `TodayView.action` drops its guard. FR-5 goes. | ✅ — and the predicate is **deleted**, not made constant. A property that is always `true` and a view that asks it are two things to keep honest; the shutter now renders unconditionally. |
| 3 | Collapse `lateAvailable` | It existed only to say "closed, but you may still post". Merge into the ordinary not-yet-captured case. | ✅ — as **`windowPassed`**, and the payloads went with it. Not merged into `scheduled`: its copy was *"the window has closed"*, which is a different fact from *"the window has not opened"*, and rendering the wrong one is how the app ended up lying in the first place. |
| 4 | `currentStreak` skips off-window days | Stop condition becomes "no moment at all" rather than "not on time". The signature already takes both `onTimeDays` and `capturedDays`, so the harder decision is made once and the arithmetic follows. | ✅ |
| 5 | **`longestStreak` becomes longest run of days with *any* moment** | **Not optional — the alternative displays a lie.** With `currentStreak` skipping, it can exceed a strictly-consecutive `longestStreak`, and the Today footer would show "best 2" beside a streak of 3. Using the same skip rule for both makes them equal whenever no day is ever missed, so the footer never renders. | ✅ — pinned by a 1024-history sweep, not a fixture |
| 6 | Keep `isLate`/`lateBy` on `Moment` | **Revised from "remove them."** With no badge they drive no UI, but the streak needs to know whether a day counted, and Phase 9's busiest-hour stat is the same data. They are read by the calculator, so they are not dead. Derivable from `capturedAt` + `DayRecord` if ever wanted elsewhere. | ✅ — kept on the model, and **removed from `MomentState`**, which is where they were doing harm |
| 7 | Fix the onboarding copy | The untrue sentence becomes true. Worth reading aloud before it ships. | ✅ |
| 8 | PRD F3, F9; TRD §8; AGENTS.md §2 rule 10 | Rule 10 is already struck in `AGENTS.md`; F3 and F9 are now wrong. | ✅ — plus F12, TRD §9's degradation note, and the token table |

**One consequence nobody had costed: the amber lost its jobs.** Items 3 and 1 took both uses of
`#FFD60A` — the badge and the sub-30s countdown — leaving the "Reminders off" row as the only
thing in the app that is amber. That is **ADR-025**, and it is why the token is now `accent`
rather than `late`.

**Tests to change, not just add.** `StreakCalculatorTests` asserts a late-only day returns zero
("A late-only day returns zero, not the previous run", "A late day in the past breaks the walk",
"Consecutive late days are zero") — three tests pinning behaviour this decision reverses. They
should be **replaced**, not deleted, with the skip rule. `MomentStateTests` pins the six states
including "`scheduled` refuses capture". The FR-5 early-post refusal in `TodayViewModelTests`
must be inverted. A test that keeps asserting the old behaviour is a plausible account of how
this shipped in the first place. **All done — sixteen tests replaced across four files, none
deleted without replacement.**



### Progress as of 2026-10-01 — the loop closes

Phase 5's last task is done. The daily loop is end to end, and the reason
this took as long as it did is the thing worth recording.

**The loop did not close, and 163 tests passed throughout.**
`MomentStore.record` had **zero call sites in the app target**. `commit()` wrote
both photographs to Photos and stopped, so the archive row was never written,
`todayMoment` was permanently `nil`, the `captured` and `capturedLate` states
were unreachable, the streak never moved, and dismissing the camera returned you
to "It's time". Every existing test was about a piece of that flow. None of them
was about the flow.

The seam is a `MomentRecorder` closure built in `AppEnvironment` — the one place
that can see both the store and the derived window. `Services` may not import
`Persistence` (AGENTS.md §3), so the camera screen cannot do this itself, and a
`Services`-level protocol for it would have had no seam that improved anything.
The window is resolved *inside* the recorder rather than passed in, because
lateness is derived from it in `MomentStore.record` and the whole point of that
derivation is that no caller can disagree with it. See **ADR-022** for the
ordering, and for why the tidier-looking alternative is the one that lies.

**Three defects found while closing it.**

- **`retry()` destroyed the photographs.** It cleared `captured` on every
  attempt, so a retryable *library write* failure threw both halves away — the
  exact case its own test comment called "nothing was lost, the photographs are
  still in memory". The test passed because it only asserted
  `phase != .permissionDenied`, a statement about permissions rather than about
  the pair. That test is now strengthened: it asserts the photographs survive,
  and that the retry re-runs the commit rather than the shutter.
- **The retry rule needed a flag, not just a memo.** `writtenAssets == nil`
  cannot tell a failed *write* from a failed *capture* — both leave it `nil` with
  the pair intact — and answering "re-arm the shutter" for a failed commit sends
  the user back to the camera with photographs already on disk.
- **The moment's time is the second shutter press, not the commit.** The pair is
  two photographs up to half a minute apart while the user composes the selfie,
  and it stops being a moment at the second one. Using commit time would make
  lateness depend on how long someone stared at the review screen.

**The Today screen now shows today's moment**, read back out of the user's own
library — the first thing in the app that *reads* from Photos. Everything before
it only writes. This is TRD §6.5's read path meeting its first consumer, and
Phase 6 inherits it rather than rebuilding it. `MomentFacts` carries the two
`PHAsset.localIdentifier`s, which is why it is the only `Sendable` boundary
between SwiftData and a view.

**Two testability defects that only surfaced once a test existed.**

- `TodayViewModel` took a `now: Date` in its initialiser and then overwrote it
  with `Date()` on the first `reload()`. A test could construct the exact state
  it wanted and watch the real clock replace it a line later. It now holds a
  clock, like `CameraViewModel` and `UserNotificationService` already did. A
  test problem today; a correctness problem the moment a timezone changes.
- `InMemoryPhotoLibraryService.image(for:)` returned `nil` unconditionally, with
  a comment saying tests assert the call rather than the result. True while
  nothing consumed it. The Today composite does, so every one of its states would
  have been unreachable in a test — and a double that cannot exercise the code it
  stands in for is a double that hides bugs.

**Also closed here.** There was no `UNUserNotificationCenterDelegate` at all,
which was two broken features rather than one missing one: iOS *suppresses* a
notification arriving while the app is foreground, and a tap did nothing but
launch the app. The tap is now routed in-process, with no URL scheme — there is
none, deliberately. See TRD §9. Re-capture is confirmed before the tap, because
add-only authorisation means the earlier pair is never removed. And the
no-networking assertion that TRD §13 and AGENTS.md §10 have both promised now
exists.

**Still outstanding for this phase's exit criterion:** the device run.

### Progress as of 2026-10-01 — the state machine got smaller, and that was the point

ADR-023's implementation list had eight items. Seven shipped in the commit above; item 3
("collapse `lateAvailable`") did not, and shipping seven of eight left the app contradicting
the decision it had just made. This is the rest of it.

**`MomentState` is now four payload-free cases**: `captured`, `scheduled`, `open`,
`windowPassed`. The payloads are the interesting part, because they were what the bad UI read.
`captured` carried `late`/`lateBy`; the view turned those into an amber *"posted 12m late"*
badge above *"Your photo is in your library. The streak did not grow."* `scheduled` and `open`
carried countdown values, and nothing read them — the view model computed its own — so they
existed only for tests to assert on.

**The fix was to delete the data rather than the branches.** ADR-023 decision 3 says an
off-window moment must look exactly like an on-time one, and the way to make that true rather
than merely intended is for the state to stop carrying the distinction. A view that *cannot*
render the badge cannot leak it. This is the same argument as the FR-5 refusal being built
structurally rather than as a disabled button — the codebase's own idiom, and the reason the
original refusal was elegant and also wrong.

**`missed` is deleted, and it was already dead.** `endOfDay(containing: now)` is always later
than `now`, so the `now < dayEnd` guard that selected it always held and the branch never
executed. A test reached it by injecting a `dayEnd` in the past, which is the shape of a test
that verifies a function rather than an app: the case had a green test and no callers. The
resolver's `dayEnd` parameter went with it, and the only DST behaviour it carried — local
midnight across a transition — is already covered at the `DayIdentifier` layer where it
belongs.

**Eleven tests replaced, none deleted outright.** The three that mattered most assert the
absence rather than the presence: that an on-time and an off-window moment resolve to the same
state; that a day's moment beats the clock at 00:00, 13:00, 14:00, 15:00 and 23:00; and that
the four states the resolver can produce are exactly the four that exist.

**`windowPassed` needed copy that did not plead.** The old `lateAvailable` said *"The window has
closed"* and *"The streak will not grow"* — the second sentence is precisely what ADR-023
rejected. It now says *"Today's moment has passed"* and *"You can still photograph whenever you
like."* A fact and an invitation, no amber, nothing about what it cost.

**And the amber ran out of jobs, which is ADR-025.** `#FFD60A` existed for the late badge and
the sub-30s countdown. Both died with the window, leaving one use: the "Reminders off" row. The
token is renamed `accent` rather than re-documented, because a token whose name contradicts its
only use is the same mistake the badge was. Seven dead symbols went with it — `LateBadge`,
`CountdownDisplay.isUrgent`, `PrimaryButton.Style.amber`, `lateDescription`,
`Theme.Typography.countdown`, `Theme.Typography.badge`, and five `MomentState` predicates.

**`missedDays` is the number that got more honest.** It counts days with *no moment at all*,
which is now the only thing that breaks a streak, so its doc comment no longer has to explain
the difference between a late day and a missed one.

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

> **Superseded 2026-10-01.** All three are done. See *Progress as of 2026-10-01 —
> the loop closes* below.

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

### Progress as of 2026-10-01 — code complete, and the cache was never there

Done: the grid, the detail view, delete, the empty state, the Settings screen, the two header
icons, and today's composite is now tappable into the archive. 239 tests in 28 suites.

Three things in this phase were decided against the table above, and each is worth the argument.

**The grid shows the rear photograph, not the composite.** The table said 3:4 cells and did not
say which image, and the composite is the obvious answer because it is what the Today screen
shows. It is wrong here. Across 500 cells, composites put 500 faces in a grid of scenes — a
gallery of selfies rather than a record of days. The inset belongs in the detail view, where
there is room to read it as *your* moment, and where `MomentComposite` gets to be the geometry
it is.

**A missing photograph is reported, not tombstoned.** The table said *"Tombstone and render
'missing from Photos'"*, and `AGENTS.md` §8 says orphans are "tombstoned, not repaired". Both
were followed literally at first and the result is wrong: tombstoning during a grid read deletes
archive entries because the user tidied their camera roll, which is a write triggered by a
*read* and is irreversible from the user's side. So the cell says *"Not in Photos"*, the moment
stays in the archive, and `delete()` remains the only tombstone path. Reporting is the honest
state and the user can still remove it themselves.

**No coordinates on the detail screen.** The table asked for them and `Moment` has carried
`latitude`/`longitude` since Phase 1 — but nothing has ever *written* them. There is no location
prompt anywhere in the app and `makeMomentRecorder` passes no location, so the fields are
permanently `nil` and a coordinate row would be a control that can only ever read "—".
Collecting location is a new permission and a new product decision, so it is deferred rather
than faked. When it happens, `MomentFacts` has to gain the field, because a screen cannot hold a
`Moment` and cross an isolation boundary with one.

**The defect this phase was always going to find.** `PhotoKitLibrary.image(for:targetSize:)`
constructed a fresh `PHCachingImageManager` on every call — and **the cache lives on the
manager**, so a per-call manager caches nothing. Invisible behind the one composite on the Today
screen, which is why twelve capture tests and several phases never met it. A 500-cell grid
re-requests every image on every scroll. Now one manager for the service's life, plus a
two-tier `ArchiveThumbnailCache`: an `NSCache` of decoded images keyed by
`identifier + size`, and `startCachingImages` for the rows on screen.

**The size is part of the cache key, and that is the whole subtlety.** Photos returns a
different decode for a thumbnail and for a full-screen image, so a key that omitted the size
would hand the detail view a 96pt thumbnail — a bug that renders as a blurry photograph and
reads as a Photos problem rather than a cache one.

**And a second miss, one layer up.** Writing the prefetch test found that the grid never called
`prefetchThumbnails` at all. `loadImages` fetched each image, so the grid looked correct in every
test and in a screenshot of the first screen — and would have shown grey rectangles the moment
anyone scrolled quickly. The decoded cache makes the *second* draw free; only Photos' own cache
makes the *first* one cheap, and the two are different calls. Two of the three "done" claims in
the table above were true of the first screen only.

**Still to close this phase on hardware:** the exit criterion is a 500-moment scroll, and there
is no UI test target in this project. Two options and neither is free: add a UI test target
(a larger decision than this phase deserves), or add a DEBUG launch argument that seeds 500
synthetic rows and record a manual scroll. **Not yet done, and it is the only thing between this
phase and closed.**

### Progress as of 2026-10-01 (later) — the seeder, and three defects only a screenshot found

`-MemoreeSeedMoments 500` now works, and the seeded archive renders: 500 rows, three across,
3:4, lazily built, no hang. The rows carry **no asset identifiers on purpose** — seeding real
photographs would write 500 pairs into the user's actual camera roll, and Memoree has add-only
authorisation and can never clean them up (ADR-008).

**Three defects that no test could have found, all in one afternoon of screenshotting.**

- **Settings rendered at the `.medium` sheet detent**, about half the screen, with its last
  section cut off mid-sentence. The view compiled, every string was present, and all 239 tests
  passed. `.presentationDetents([.large])` was then tried in **both** places a modifier can go —
  on the `NavigationStack` inside `SettingsView`, and on the content at the `.sheet` — and was
  **silently ignored both times**. The drag indicator appeared, which is evidence the modifier
  was applied, and the sheet stayed at `.medium`. A modifier that does nothing while showing
  evidence of having been applied is worse than one that is obviously missing.

  The fix was not another modifier. Settings is now a **`fullScreenCover`**, and the reasoning is
  the design point rather than the workaround: four sections with a title and a Done button is a
  *task*, not a peek, and a full-screen cover has no detent to get wrong. It also matches the
  camera, so there is one convention instead of two. **The archive stays a sheet** — a grid you
  flick through and dismiss is exactly what a sheet is for.

- **Settings had no title and no dismiss button**, which is *why* it wanted to be a short sheet.
  Built as a sheet with a drag handle and nothing else, a settings screen most people will not
  find their way out of. Both were added.

- **A black void filled the top half of Settings.** `CanvasBackground()` was a *sibling* of the
  `ScrollView` rather than its background, so it claimed vertical space that only it wanted and
  pushed the first section more than half way down the screen. As a `.background` it paints
  behind the content and competes for nothing.

**A second DEBUG affordance, for the same reason as the seeder.** `simctl` cannot tap, so a new
screen cannot be *looked at* without a human holding a phone:

```
-MemoreeOpen archive
-MemoreeOpen settings
```

The first version parsed the destination out of the flag's own string, and `simctl launch`
delivers arguments as a list — so the flag silently did nothing. Which is the worst possible
failure for a diagnostic: it looks like the screen is broken rather than the flag. It now reads
the *next* argument.

**Three defects in a row, none of them reachable by a test, and all three found in about ten
minutes** with no device, no signing, and no twenty-minute wait. This is the strongest argument in
the project for keeping a way to see a screen — and the strongest argument against treating the
device run as the only instrument that counts.

### Progress as of 2026-10-01 (later still) — the archive could not be searched

An accessibility and design pass found the grid's real gap, and it was not a contrast ratio or a
tap target. **The archive had no dates anywhere.** 500 photographs in an unbroken block of squares
with no month and no day. You could count them; you could not find last Tuesday in them, you could
not tell six weeks ago from yesterday, and you had no way to tell whether the archive had quietly
stopped filling. An archive you cannot locate things in is a contact sheet.

**Month headers, pinned.** `ArchiveGrid` is now a `ScrollView` of `Section`s in a
`LazyVStack(pinnedViews: .sectionHeaders)`, each section carrying its own `LazyVGrid`. The header
is opaque against `canvas` — a pinned header with a transparent background shows photographs
scrolling *through* the text, and these cells are full-bleed photographs, so there is always
something behind it to see.

**A day badge on every cell**, because the month header cannot answer "which one was last Tuesday"
— thirty squares under "October" all read October. A black pill at 60% carries a white day number
top-left; the scrim is not decoration, since photographs are the one thing in the app whose colours
are not under its control. It is `accessibilityHidden` because the cell's own VoiceOver label
already reads the full date in words.

**`ArchiveSection` is a value type in `Models`, and that is the point.** The grouping is the whole
of the feature's logic and every one of its failure modes is invisible: a duplicate header, a
section out of order, a moment under the wrong month. Thirteen tests, and the ones that earned their
keep are the boundaries —

| Case | What it pins |
| --- | --- |
| `13:00Z` on 31 Aug, in Auckland | Groups to **September** locally. The same instant is 31 August in UTC, which is how a photograph lands under the wrong header. |
| `06:30Z` on 1 Sep, in Los Angeles | Groups to **August**. The mirror image, so the rule is not "always prefer the later month". |
| 28–31 March, Europe/London | DST inside the month does not split it. |
| Sept, Oct, Sept, Oct | **One** section per month. The case a dictionary-shaped grouping gets wrong, and it shows as two "September 2026" headers. |
| Any input | Every moment appears exactly once. A photograph silently absent from the user's own archive is the worst bug this app could have. |

The section key is a **year/month pair, not a `"2026-09"` string and not a `Date`.** Both
alternatives fail later: a string is not an instant so it sorts lexicographically, and a `Date`
start-of-month has to be manufactured from `dateComponents` that quietly fill in day and hour from
the calendar's defaults.

**The first Auckland test asserted September and failed, and the fixture was wrong.** Auckland is
UTC+12 in August, not +13 — NZDT does not start until 27 September — so 11:30 UTC is 23:30 on
31 August locally, and correctly August. A test that pins a timezone has to pin the offset too:
"Auckland in January" and "Auckland in August" are two different timezones.

---

## Phase 7 — Stats ✅

> **Reordered ahead of share and BTS, and it is cheaper than it looks:**
> `StreakCalculator.summary` already computes every number this phase displays —
> `currentStreak`, `longestStreak`, `daysCaptured`, `lateMoments`,
> `onTimePercentage`, `averageRetakes`, `btsCount`, `busiestHour`, `missedDays`.
> Phase 2 built the whole of it. **This phase is a view plus test coverage for
> fields nothing has asserted on yet.**

**One copy decision this phase forces, and it is not optional.** With the late badge removed
(ADR-023), `onTimePercentage` and `lateMoments` are the *only* place the two-minute window's
significance is ever visible to a user. Nothing on the Today screen says why a streak did not
move — that was accepted knowingly — so this is where the explanation lives, if anywhere.

Recommendation: **show it, as an aggregate.** *"7 of 12 on time"* describes a number. A badge on
a photograph described the user. The distinction is the whole of ADR-023 and it survives the
reorder intact.

| Task | Notes |
| --- | --- |
| Stats view | Total moments, days captured, current + longest streak, on-time %, average retakes |
| Busiest hour | Histogram of `capturedAt` — already computed, never displayed |
| Streak history | Current and past streaks, in place of BeReal's Memories calendar |
| Empty states | Zero moments, one moment |
| BTS count | **Added 2026-10-04**, when Phase 10 gave it something to count. A count, not a percentage, and hidden at zero — the omission's stated reason ("BTS has no recorder, so the row would always read 0") is still true for every user who has not turned it on, and is the majority |

**Exit:** numbers match the archive by hand-check on three days of data.
**Estimate:** 1 day.

### Progress as of 2026-10-01 — the numbers were already computed; this is where they were going

Reached by tapping the streak. The header already carries three things and a fourth icon would be
one too many — but the number the user cares about is the obvious door to its own history, and
"tap the number to see the numbers" needs no explanation.

**The debt was the coverage, not the view.** `StreakCalculator.summary` has computed every field
on this screen since Phase 2 and `StreakSummary` is a `Sendable` value with a plain initialiser,
so for five months there was a whole statistics layer with nothing asserting on most of its
output: `onTimePercentage` could have been returning nonsense and no test would have noticed.
Eighteen tests across two files — the arithmetic, and the decisions.

**The phase's one forced copy decision, and it is the answer to a risk ADR-023 accepted knowingly.**
With the late badge gone, an off-window moment is indistinguishable from an on-time one on every
screen and the streak silently does not move. ADR-023 said: *"A user who has not read this ADR
will experience that as a bug in the first week."* The answer is **"375 of 500 on time" describes a
number; a badge on a photograph described the user.**

**"2 missed" would be both a reprimand and wrong**, so the row is "days with nothing" — and only
an empty day breaks a streak. `missedDays` counts days *after* your first moment, because you
cannot have missed a day before you started; my test expected the two preceding days to count and
was wrong, and the alternative is defensible-looking and wrong — a user who installed last week
would open this screen to "several days with nothing" on their first launch.

**Two time formats on one screen**, found by screenshotting: "Most often at 8pm" above "11.38"
below, because the busiest hour used a hardcoded `"ha"` while the history list followed the device
locale. Both follow the locale now, and the test compares against the same formatter the list uses
rather than a literal — a test hardcoding "4pm" fails on a 24-hour device and passes on a 12-hour
one.

Rows that read zero are hidden rather than shown: a user who has never retaken anything is not
being told they scored zero.

---

## Phase 8 — Polish ✅

> **The Settings screen already exists** — window picker, reminders status, the reinstall
> warning, the camera-reset hook, pending-count diagnostics — shipped with Phase 6 because the
> window picker could not honestly exist anywhere else. So this phase is no longer "build
> Settings"; it is the accessibility and motion pass, plus the two remaining settings rows.

| Task | Notes |
| --- | --- |
| Save-to-album toggle | **Done.** `settings.saveToAlbum` existed since Phase 2 and defaulted off; nothing surfaced it |
| BTS toggle + duration | **Cut — see below.** There is no `BTSRecorder`, so the toggle would be the dead control `Models.swift` explicitly warns against |
| Data export | Needs Phase 9's `MomentExporter` |
| Dark-mode audit | **Done.** Asserted, not intended — and it found a real layering violation on its first run |
| Dynamic Type | **Done.** "Verify" turned out to mean "the app had none of it" |
| VoiceOver | **Done.** Camera, archive, detail, settings |
| Reduce Motion | **Done.** The camera-switch animation it named does not exist; the four that do are wrapped |
| Reduce Transparency | **Verified N/A**, and asserted so it stays true |
| Haptics | **Done**, two events — see the note on the camera switch below |

**And one design-system decision lands here.** ADR-025 renamed the amber and gave it one
reserved job. If a second load-bearing use ever appears it is a new ADR, not a reinterpretation
— the point of the rename was to make a silent second meaning impossible.

**Exit:** Settings does everything; accessibility pass complete.
**Estimate:** 2 days.

### Progress as of 2026-10-01 — "verify Dynamic Type" meant "there is none"

**The plan's row said "Dynamic Type | Verify the countdown and metadata at accessibility sizes."
Verified. Every one of the eight tokens in `Theme.Typography` was `Font.system(size:)` — a fixed
point size, which does not scale.** Not "scaled a little": not at all. A user at the largest
accessibility setting saw a pixel-identical screen. Found by screenshotting the same screen at two
sizes and comparing, which produced the same picture twice.

The ramp is now text styles, and **the point sizes did not move** — `.title2` *is* 22, `.headline`
*is* 17 semibold, `.subheadline` *is* 15, so the two roles one point apart are still one point
apart. The two big numerals (64 and 56) have no text style and are the third option: `@ScaledMetric`
honours the base exactly and applies the user's setting as a multiplier, capped at 2.5× so a numeral
grows into its space instead of clipping.

**Fixing the fonts exposed four layout bugs that had been invisible for the project's whole life.**

- `MetadataRow` was a two-column `HStack`. At AX5 the label got a fraction of the width — too
  narrow for any single word, which is when iOS breaks a word *mid-word*. "Photographs" rendered
  as "**Pho-tographs**".
- The countdown truncated to `4:53:…`. A `HH:MM:SS` string cannot wrap, so it truncates, and a
  countdown to nothing is worse than a small one.
- Today's column is a `VStack` with `Spacer`s, which centres. **A centring stack taller than its
  screen overflows off *both* ends at once**, so the streak's "375" was sliced through by the
  status bar and "Next moment at 17:59" read "Next mome…". A `ScrollView` does not help: the
  column still centres, so half its content is still above the scroll view's top edge. The layout
  is now replaced at accessibility sizes rather than the existing one wrapped.
- The two flame icons sat at a fixed 20 and 28 while the numbers beside them grew to 140.

**`ViewThatFits` was the obvious answer for `MetadataRow` and it was wrong.** It worked on Stats,
then chose the *row* on Today for labels that did not fit and truncated them — inside a
`ScrollView` the proposal it measures against is not the screen width. **A branch driven by a
measurement that does not hold is worse than no branch**, because it looks like it is handling the
problem. `isAccessibilitySize` measures nothing. Both failed attempts are recorded on the type,
including a `fixedSize` that traded hyphenation for clipping.

**The album toggle, which existed in the model since Phase 2.** `PhotoKitLibrary.ensureAlbum`
carries a comment saying it: *"Two layers of 'not shipped' hid a defect that the first real
invocation exposed."* The album add runs **after** the commit and cannot fail it — the photographs
are what the user asked for and they are already on disk; an album is an organisation of them. It
is still reported (on the Today footer, because the camera screen is gone by then) and in grey,
not amber. Turning it off deletes nothing, and the guarantee is structural: `PhotoLibraryService`
has no delete method at all.

**Haptics: two events, not three.** A haptic describes something *the user did*, not something
the app did internally — and one shutter press photographs *and* swaps, so buzzing for both would
tell the user two things happened when they pressed once. `cameraSwitched` has no call site and
the protocol says so. **The plan's "Capture, and the camera switch" should be read as one event.**
Writing the tests also found that `shutterPressed`'s doc comment says the *second* press switches
and the code switches on the first — the behaviour is right and the comment is wrong, recorded
rather than fixed because it is a product change to ADR-021.

**Reduce Motion's "camera-switch animation" does not exist.** There is no cross-fade; the four
animations that do exist all go through `.appAnimation`, which substitutes `nil` — removing the
animation rather than shortening it. A scan enforces it, because a `.animation` that bypasses the
wrapper is identical in review and ignores the setting silently.

**VoiceOver: the countdown was announcing itself once a second.** A `Text` is an accessibility
element by default, and one whose value changes every second is one VoiceOver may re-announce.
Hidden — and defensible, because the same fact is already in the footer as a static row that
announces once. Also: two of the three composites announce as buttons and one should not.

**The dark-mode audit found a layering violation on its first run.** `OnboardingView` has imported
AVFoundation and Photos since Phase 0 and called `AVCaptureDevice.requestAccess(for: .video)`
directly, breaking `AGENTS.md` §3; `Photos` was never used at all. The request now goes through
`captureService`, which has had `requestAuthorization()` since Phase 1.

### Progress as of 2026-10-01 (later) — a second pass, and it found a different class of defect

The first pass took the plan's word "verify" at face value and found missing type. This one was
given a brief of defects only — contrast, tap targets, glyph scaling, locale, dead code — and the
defects it found were mostly *real but wrong in magnitude*, plus two that had nothing to do with
accessibility at all.

**Two of the numbers I wrote down were wrong, and only a screenshot settled them.**

- I claimed the 52pt primary button lost ~11pt of its title from `accessibility-x-large` up. Screenshots
  at **every** accessibility category in turn show nothing wrong through `accessibility-extra-large`,
  and at `accessibility-extra-extra-large` the "p" of "Capture" is clipped by the capsule's bottom
  edge — descender on the boundary, zero padding. Not eleven points of title: a descender. The
  measurement cost four screenshots and saved a comment that would have been confidently false.
- `textTertiary` is 3.51:1 on the canvas and 2.84:1 on a card, against AA's 4.5:1. Raising it to
  `#848486` — 5.63:1 and 4.56:1, the faintest grey that passes on the harder background — **costs the
  ramp a tier.** Secondary is 6.44:1, so the step between them is 13%, down from 46%. Thirteen percent
  does not read as a tier.

  That is the price of the other option. Three distinct tiers that all pass AA on black *do* exist —
  `#848486` / `#B0B0B8` / `#FFFFFF`, with a 73% step — but they require brightening every piece of
  secondary text in the app. Tone kept, tier given up: **legibility is not negotiable and a third
  shade of grey is.** On a pure black canvas a third distinct passing tier does not exist without
  changing what the app feels like.

**Three tests were actively protecting bugs.** `displayBounds == "11:00 – 23:00"`,
`== "00:00 – 09:00"` and `momentClockTime == "14:00"` all enforced a 24-hour clock on every user
regardless of Settings, while reading as though they were testing *that the time is 14:00*. All
three now compare against what the device itself renders, which is what surfaced two facts worth
pinning: **en_GB midnight is `0:00`, not `00:00`** (CLDR's h23 pattern), so a British user sees `0:00`
and `24:00` in one window; and **`en_US` puts U+202F before the meridiem**, so `"12:00 AM"` in a test
is not the string the device produces.

`StatsViewModel` had already been through the 24-hour bug. The fix was never carried across to the
other two files that had it — the same shape as the twenty-moment capture fix: a correct change made
where the symptom appeared and nowhere else.

**Six design tokens were deleted, and one of them contradicted its own comment.** `surfaceElevated`
and `divider` were the same `#2C2C2E` under two names, so someone would eventually pick the other and
wonder why the app has two greys. `Elevation.card` shipped a shadow two lines under a comment
reading *"on a black canvas a shadow does not read as darkening — it reads as opacity. Prefer
omitting shadows entirely."* `Typography.caption` had no call site and a doc comment describing a
role no view was doing; deleting it orphaned the comment, which claimed a 16pt level the app does
not have, so that went too. Six tokens each named a capability the app does not have.

**`Theme.Size` now exists** because twelve numeric dimensions were literals in view files. The
invariant that enforces it excludes `0` and `1` deliberately — a `VStack(spacing: 0)` and a 1pt
divider are literals by nature, and a scan with no exceptions is a scan that gets switched off.

**And two concurrency warnings that had been there the whole time.** `CameraViewModel` is
`@MainActor` and stores its album callbacks as `@Sendable`, which makes them *non-isolated* — so
`CameraHostView` could not build one touching the `@MainActor` `AppEnvironment`, and the only way past
the warning was a `MainActor.run` hop for a value already on the main actor. Dropping `@Sendable`
fixed both warnings and deleted the hop. Earlier builds here grepped for `error:` only, so they were
never seen; **`AGENTS.md` §12 asks for zero warnings and the grep was not asking that.**

### Four design calls, none of them defects

| Call | Change | Argument |
| --- | --- | --- |
| Archive had no dates | Month headers, pinned; day badge per cell | You could count your archive but not search it |
| Escalation inverted | **Shutter above the countdown** | The countdown was 64pt and the button 52pt, so the screen said *watch the clock* when it meant *you can capture now*. It also contradicted ADR-023: no moment is late, so a big ticking number above the shutter reads as pressure to act now |
| Camera had no exit | Labelled outlined "Cancel", top-trailing | The only route back was an edge swipe the app never claimed — and the review state *did* have a visible Cancel, so the exit appeared only after you had committed to a photograph |
| Export outranked the window | Solid white pill → outline | `AGENTS.md` §11: "White is the verb." On black, a solid white control is the loudest thing available and it was spending that on the feature nobody opens twice. The screenshot settled it: the amber "Open Settings" button — ADR-025's one reserved use — sits two sections below, and the two were competing |

The last one is now an invariant: **no view outside `Components.swift` may paint a control
`Theme.Color.textPrimary`.** Verified by replaying the scan against the reverted row (0 offences
now, 1 with the pill back).

**Deliberately not done.** `btsAssetIdentifier` is written and never read. Removing it is a
SwiftData schema change against a store holding real captures, so it is recorded rather than done
quietly. And the review screen's "Post" became "Save" — that is copy, which is the user's call.

### Progress as of 2026-10-02 — a photograph should be saved the way it was taken

Two defects, both invisible until you hold the phone sideways.

**Nothing set an orientation.** Not the preview connection, not the photo
connection, on either API. Everything sat at the AVFoundation default, which
assumes a landscape-held device — so on a portrait phone the live preview was a
sideways image and the framing composed was not the framing saved.

`DeviceOrientation` (a domain enum, so `Services/` never names a UIKit type to
describe something it owns) and `CaptureOrientation`, a pure table. Applied in
**three** places, each covering a case the others miss: at session start, so the
*first* frame is upright rather than visibly rotating; inside `applyFormat`,
hence **on every input swap**, because front and rear are separate connections
with independent state and ADR-021 swaps mid-moment; and on each rotation live.

`videoRotationAngle` over `videoOrientation` — the latter has been deprecated
since iOS 17, which is the floor. Preview and photo get **separate** fields,
because AVFoundation applies them differently: a transform on the preview layer,
an **EXIF tag** on the photo.

`faceUp`/`faceDown` return `nil`, and that is the point: a phone on a table has
no orientation to report, so the camera keeps what it has rather than rotating
the preview under someone who has done nothing.

### The front camera was right before, and I broke it

I derived a half turn for the front sensor from its mounting relationship,
tested that the derivation was internally consistent, and shipped it. The front
preview came out rotated. **It had been correct before this feature, because
nothing set any orientation and the AVFoundation default was already right for
it.**

So the front is now never touched, and the test that asserted the opposite has
been replaced by one asserting *absence*. The old test passed because the
arithmetic was correct — **it was checking that a diagram matched itself.** A
test can pin what someone actually saw; it could only ever have confirmed the
theory.

The lesson is the one this file keeps recording: a derived invariant is not a
measured one, and a device is available.

### Landscape, which the plist had been forbidding the whole time

`UISupportedInterfaceOrientations` declared portrait only. **A landscape
photograph could not be taken no matter what the connections were told** — so
"saved the way it was taken" was unreachable for half the claim. Portrait,
landscape left and landscape right are now declared; portrait upside down is
deliberately excluded, because it is a video affordance and in a camera app it
means saving photographs the user did not mean to take.

Allowing it exposed four things that were latent, and all four are fixed:

| Place | Was | Now |
| --- | --- | --- |
| **Share renderer** | Canvas forced to `width × 4/3`, so a landscape photograph was **stretched a quarter in one axis** — the distortion AGENTS.md §2.8 forbids | Canvas is the photograph's own size. For a portrait moment the two are identical, so nothing that used to be right changed |
| **Composite inset** | A square sized from the canvas **width**, so it grew about a third in landscape | Sized from the **short** side, so the inset does not change size because the picture turned |
| **Archive cell** | `scaledToFill` into a fixed 3:4, **cropping 44% of every sideways moment** off the screen you use to find things | `scaledToFit` over `surface`. Portrait renders identically; landscape keeps all of it with two thin bars that read as a mat |
| **Today column** | `VStack` that centres, with **no scroll unless the text size was huge** — so in landscape the shutter fell off the bottom | Scrolls when `isAccessibilitySize` **or** `verticalSizeClass == .compact` |

The Today fix is the one that matters most and the least obvious: the
`Spacer`-centred column **cannot fit a landscape phone**, and what leaves the
screen is the app's only action. The trigger is a **size class rather than a
measurement of the content**, for the same reason `MetadataRow` abandoned
`ViewThatFits` — a branch driven by a measurement that does not hold is worse
than no branch, because it looks like it is handling the problem. A size class
is a system classification of the viewport, and it holds.

**And a test that took ten minutes.** The inset test scans for the front
colour's bounds rather than recomputing the code's own formula — but its first
version called `colour(...)` inside a nested loop, re-fetching
`CFDataGetBytePtr` 480,000 times, and took the suite from nine seconds to **604**.
A slow test is not a harmless test; it is a test people stop running. The buffer
is decoded once now.

### Orientation: four attempts, and the answer was never in my code

Worth writing up in full, because **every wrong turn here was mine and every one
of them looked reasonable.** Landscape photographs saved as portrait ones. The
symptom never changed across four fixes, which is what finally made it obvious
that the diagnosis — not the arithmetic — was the problem.

| # | What I did | Why it was wrong |
| --- | --- | --- |
| 1 | Added a hand-written table from held orientation to rotation angle, unit-tested | **No table knows how a phone's sensor is mounted.** That is per-model hardware |
| 2 | Derived the front camera's angle from the mounting relationship | It was already right. Broke a working camera, and the test passed because the arithmetic was right |
| 3 | Read `UIDevice.orientation` instead of a hardcoded `.portrait` | **It returns `.portrait` forever when rotation lock is on.** A setting, so no test could ever reproduce it |
| 4 | Guarded the coordinator's construction on `state == .running` | It is built *before* `startRunning()`, so it was **never built**, and every photo got a default quarter turn |

**The coordinator** — `AVCaptureDevice.RotationCoordinator`, which *"monitors the
physical orientation of a capture device and provides adjustment angles to keep
images level, relative to gravity"* — was in attempt 4. The bug was not the
coordinator. It was one guard clause in the same commit.

### Why a wrong rotation looks like a mapping bug

A sensor is natively **landscape**. Rotating its buffer a quarter turn produces a
**portrait** image — which is precisely what a portrait-held photograph needs. So a
permanent 90° makes:

- **portrait shots correct**, by accident
- **landscape shots wrong**, since those need no rotation

"Portrait works, landscape doesn't" reads like a bad angle for one case. It is a
default applied to all cases. **And it is why three fixes to the mapping changed
nothing: the mapping was never reached.**

### The rule this cost four attempts to learn

**Asserting a rotation nobody asked for is worse than applying none.** With no
rotation the photograph keeps the sensor's native orientation — a real,
self-consistent image, and the right answer for one of the four ways a phone can
be held. With a wrong rotation it displays as something the user never
photographed, and nothing anywhere reports an error.

This codebase made that mistake **three times in three commits**: `startup`
defaulted to 90°, `lastReportedOrientation` defaulted to `.portrait`, and
`configureOrientation` fell back to a quarter turn. Each was invisible, each was
locally reasonable, and together they held the bug in place. There is now a test
asserting the start-up rotation is `nil`.

### Verified on a phone

Landscape photographs now save landscape. Portrait, landscape, front and rear
all correct.

### Still unverified: landscape layout, on every screen

**The Simulator GUI is not installed on this machine**, so the simulator cannot
be rotated and no landscape screenshot was taken. The four fixes above are
asserted in tests and reasoned about; the *layouts* of Today, the camera, Stats,
Settings and the archive **have not been looked at sideways**.

Camera, Stats, Settings and the archive all use `ScrollView` or size fluidly and
should be fine. The camera review screen is the one to watch — it pairs a
full-bleed composite with three controls — and the shutter row's fixed vertical
padding in a 430pt-tall viewport.

### Midnight found two tests with an expiry date

The suite went red at 00:00 on 2026-10-02 with **no code change**, and both failures were real.
Worth writing down because nothing about them looks like a date bug from the failure message:

- `MomentCommitTests` — *"An on-time capture is not late, and grows the streak"* expected
  `currentStreak == 1` and got 0.
- `MomentWindowChangeTests` — *"A window change re-derives tomorrow onward"* expected the new
  window's hour and got the old one.

**The cause is a split clock.** `makeModel` pins the *model's* clock with a `StepClock`, but
`MomentStore.summary()` derives `today` from the **real** one. Both tests captured on a hardcoded
day — `2026-09-30` and `2026-10-01` — and `StreakCalculator.currentStreak` walks backwards from
the real today. A capture on a literal therefore lands inside the walk only while that literal is
today or yesterday. **The tests had a two-day expiry, and it expired at midnight.**

`AppEnvironment.updateWindow` has the identical shape: it discards and re-derives from
`DayIdentifier(date: Date()) + 1` — the real clock — while the test's `tomorrow` came from its own
literal. Once the real date passed it, the pinned row stopped being in range and the assertion had
nothing left to be about.

**One of them had gone green for the wrong reason, which is worse.** The late-capture test also
asserted `summary().currentStreak == 0`, and a stale day produces 0 *because of the gap* rather
than because the capture was late. The assertion was passing and proving nothing. It now passes
`today:` explicitly and asserts `daysCaptured == 1` alongside, so the zero can only come from the
lateness.

The fix is to derive the day rather than pin it — the claims are "an on-time capture **today**
grows the streak" and "a window change re-derives **tomorrow**", so today and tomorrow have to be
today and tomorrow. `StreakCalculatorTests` and `StreakSummaryTests` already do this correctly by
passing `today:` as an argument, which is what made them the only two streak tests that survived
the rollover.

**The generalisable rule: a test that pins a date *and* derives "today" from the real clock has
written a test with an expiry date.** Any such test is green until the day it was authored. Two in
~350, found by waiting, not by reading.

### Progress as of 2026-10-03 — landscape, finally looked at

**Fourteen screenshots, five screens, both orientations, with real photographs in the
grid.** The open item that read *"the layouts of Today, the camera, Stats, Settings and
the archive have not been looked at sideways"* is now closed, and closing it took a
DEBUG affordance rather than a device.

**Why it had never been done, and why it was not a missing afternoon.** Rotating a
simulator needs the Simulator GUI, which is not installed on this machine — and
**there is no `simctl` subcommand for orientation.** `simctl io … screenshot` captures
whatever the device is showing, and nothing available can change what that is. So the
app asks the window to rotate itself: `-MemoreeForceLandscape` calls
`requestGeometryUpdate`, the supported way, DEBUG-only like the other three flags.

**And the archive needed real pixels before any of it meant anything.**
`-MemoreeSeedMoments` writes no asset identifiers so a debug launch cannot put
photographs into a user's camera roll (ADR-008) — and the consequence is that every
cell is an empty rectangle, which exercises none of the geometry that matters: the
`scaledToFit` mat, the front inset sized from the short side, the composite renderer.
`-MemoreeSeedWithPhotos` attaches identifiers **already in the simulator's library**.

**One guard is a runtime check rather than a `#if`, and that is the point.**
`targetEnvironment(simulator)` is a *compile-time* answer, so it cannot gate a runtime
flag: the same Debug build is what a device run installs. The check reads
`SIMULATOR_DEVICE_NAME` at runtime, behind a `precondition` on the simulator and a
hard no-op on hardware — because pointing a user's archive at assets they never
captured is the most literal possible violation of ADR-008.

#### What the screenshots show: all five screens are sound

| Screen | Portrait | Landscape | Verdict |
| --- | --- | --- | --- |
| **Archive** | 3 across, matted | 2 across, matted | **Landscape photos keep all of their width** with two thin bars. The `scaledToFit` fix holds. |
| **Today** | Shutter visible, centred | Scrolls; shutter visible | The size-class fix holds — nothing falls off the bottom. |
| **Stats** | Full column | Full column, scrolls | Scrolling as designed; the `Recent` list is reachable. |
| **Settings** | Full column | Full column, scrolls | Window pickers and both sliders intact at 2622pt wide. |
| **Onboarding** | Full | Full, centred | First run is the one screen that had never been seen in either orientation. |

**Four latent layout bugs were fixed by reasoning before any of this existed**, and
none of them reappeared. That is a good result for the fixes and **no evidence at all
that reasoning was sufficient** — it is four bugs that were found, not four that were
the total.

#### And building Release found a class of defect every gate here had missed

The audit's own flags **did not compile in Release**, and nothing noticed for an hour
because **every gate this project has ever run was a Debug gate** — the test suite, the
device runs, the lint. `allImageAssetIdentifiers()` and
`attachPhotographsForSeeding` are DEBUG-only, and the two helpers calling them were
sitting outside the DEBUG block. Debug built clean. Release failed.

**`AGENTS.md` §12 asks for zero warnings; it does not say "in the configuration you
usually build."** A configuration nobody builds is a configuration nobody checks. The
fix for that is a gate rather than a promise, and the honest statement today is that
**Release compilation is verified by hand and not by anything automatic** — which is
exactly how the Release-only `try` warning in `InMemoryPhotoLibraryService` survived
earlier the same day.

That is now **three times in one day** that a claim of completeness turned out to be
scoped to whatever happened to be checked: a test named "every capture error" missing
one, "zero warnings" measured only in Debug, and "landscape has not been looked at"
turning out to need an affordance that did not exist. Worth naming as a pattern rather
than as three coincidences. `Scripts/layout-matrix.sh` should build both
configurations; until it does, the gap is recorded here.

#### Two things the audit could not do, recorded rather than hidden

**The camera screen's *review* state was not captured.** The review screen needs a
capture, and the simulator has no camera — so its landscape layout remains the one
place this document singled out as most at risk ("a full-bleed composite paired with
three controls, and a shutter row's fixed vertical padding in a 430pt-tall viewport")
and is still unverified. **The live capture screen *was* verified** in both
orientations, with its Cancel, shutter and zoom row intact.

**`simctl` cannot tap, so a permission alert blocks every screenshot behind it.** The
first four attempts were all photographs of an alert. `xcrun simctl privacy` fixes it
*if granted before the first launch* — and granting `photos` alongside `photos-add`
makes Photos escalate to a full-access prompt that then covers the app for the rest of
the session. That cost about twenty minutes and is now a comment at the top of the
script, because the next person will otherwise rediscover it exactly as I did.

`Scripts/layout-matrix.sh` runs the whole matrix.

### The BTS toggle: cut, and why that is a decision rather than an omission

The plan offered it "only if Phase 7 is built". Phase 7 turned out to be Stats, so the
condition never held. **It still should not be surfaced**, and the reason is already written
into `Models.swift`:

> Both defaulted to on and true, which made the settings row describe a feature the app does not
> have until Phase 7 — *a toggle that says "save your Behind the Scenes clip" and then silently
> does nothing.*

**There was no `BTSRecorder`.** `btsEnabled` and `saveBTS` were model fields with nothing on
the other end; `saveBTS` on the library wrote bytes nobody produced. Surfacing the toggle
would have been exactly the dead control the comment describes, and it would have been the
app's first dead control. **The flag stayed in the model, where it was inert and cost
nothing, and the row waited for a recorder that exists.**

**Superseded 2026-10-03, and now inverted.** BTS was re-adopted as Phase 10, and a
`BTSRecorder` protocol, the trim arithmetic and a test double exist — but there is still no
recording implementation, no session wiring and no playback. So the reasoning above holds
*exactly as written*: the row still waits, and now it waits on Phase 10 rather than on a
phase number that was reassigned underneath it. The row ships with the feature or not at
all.

---

---

## Phase 9 — Share and export ✅

> **Reordered last of the three cheap phases, 2026-10-01.** Sharing is genuinely useful and
> genuinely unlike BeReal — the company cannot get your photos out, and this is the answer to
> that. It is also the least load-bearing thing left, because nothing in the daily loop depends
> on it and no defect in it costs a streak.
>
> It is **not** the last phase any more: BTS was re-adopted as Phase 10 on 2026-10-03, and
> release readiness is Phase 11.
>
> The onboarding warning in this table is **already done** — it ships in the Settings screen,
> where "If you delete Memoree" states the asymmetry outright.

**Status: complete.** `MomentExporter`, `SharedImageFile`/`SharedArchiveFile` and
`MomentCompositeRenderer` all ship, wired to two live `ShareLink` surfaces — the moment
detail view (both photographs, and the combined picture) and Settings (the JSON archive).
32 tests. The optional import/restore stretch is not done, and nothing depends on it.

**One defect this phase shipped and its own tests did not catch.** `SharedFile` hardcoded
`exportedContentType: .image`, so the **JSON** export left the app advertised to the share
sheet and to every receiving app as `public.image` while carrying a `.json` filename. The
tests asserted the filename suffix and never looked at the declaration. Fixed 2026-10-03 by
splitting the type — `Transferable.transferRepresentation` is `static`, so a declared
content type is a property of the *type*, and one type can only declare one. A `contentType`
property would not have helped: it would have been unreadable from the one place it has to
be used. See `SharedArchiveFile`'s documentation.

| Task | Notes |
| --- | --- |
| Share sheet | Both originals as two files |
| Composite renderer | Optional combined image, rendered on demand, **never** written to Photos |
| `ShareLink` | Straight from Photos via `PHAsset` image requests — never from app storage |
| `MomentExporter` | All metadata → single Codable JSON |
| Export via share sheet | Filename `memoree-export-<date>.json` |
| Import/restore | Optional stretch: read an export back |
| ~~Onboarding warning~~ | **Done** — Settings, "If you delete Memoree" |

**Exit:** sharing produces two clean, unwatermarked originals and a correct JSON export.
**Estimate:** 1 day.

---

## Phase 10 — Behind the Scenes · **building it**

> **Numbering, and why this was Phase 7 until 2026-10-03.** The document carried two
> sections numbered 7 — this one and Stats — because BTS was renumbered to 7 when it was
> cut-and-reconsidered, and Stats was never renumbered back. The sequence diagram at the
> bottom already had BTS at 10, which is where it belongs: 7, 8 and 9 were executed in
> that order and are done. **The duplicate was only ever a heading**, so nothing that
> reads this document by number was misled — but a document whose own contents page
> disagrees with its body is one nobody can navigate.
>
> **Reordered 2026-10-01, and this was the phase most likely to be deleted rather than built.**
> The rest of the roadmap moved ahead of it — Stats, then polish, then share — and the reason is
> in ADR-023: the premise narrowed from *forced spontaneity* to *a daily photo journal with a
> reminder*. BTS is the most BeReal-residual feature in this document, and it is the only one
> that adds a second media type, a second permission, a new playback surface and a new failure
> mode (a video that will not play) to a product whose entire claim is one unretouched
> photograph a day.
>
> "Prefer removing code to adding it" (`AGENTS.md` §13) applies to phases, not only to lines.
> The decision was deferred to the end of polish for exactly that reason.
>
> **Decided 2026-10-03: build it.** The user chose to keep it, so the case for cutting it —
> which this header still argued — is recorded here and not acted on. `AppSettings` has carried
> `btsEnabled`/`btsDuration`/`saveBTS` defaulted **off** since Phase 2, specifically so no toggle
> in the app described a feature that did not exist; that reasoning stands, and the fields stop
> being inert with this phase.
>
> **Sequenced after Phase 4's gate on purpose.** BTS attaches an `AVCaptureMovieFileOutput` to
> the same `AVCaptureSession` whose lifecycle the twenty-moment gate is stress-testing, and the
> daemon death behind that gate is still uninvestigated. Perturbing the highest-risk code in the
> project in order to add a feature to it, before the thing being perturbed is known-good,
> inverts the order this document has argued for since Phase 0.

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

### Progress as of 2026-10-03 — the arithmetic, the seam, and the double

The foundations of three tasks are in. **No capture session is touched yet**, for the reason in
the note above.

- **`BTSTrim`** — the whole decision of *which part of a continuous recording survives*, as a
  pure function over `TimeInterval` with no `CMTime` in it. `AVAssetExportSession` speaks in
  `CMTimeRange`, but every rule that can go wrong is arithmetic on seconds, and a plan in
  seconds is testable on a simulator with no asset, no export session and no camera. The same
  split `CaptureFormatSelector` makes between its arithmetic and its one-line wrapper.
- **`BTSRecorder`** — a protocol, on the same terms as `CapturePhotoService`: microphone
  authorisation is a *supported state* rather than an error, no `BTSRecorderError` case is
  retryable (the opposite of `CaptureError.isRetryable`, and the difference is the point — the
  user has already taken the photograph), and trimming returns `nil` rather than throwing when
  there is nothing to keep.
- **`InMemoryBTSRecorder`** — the test double, so the path is testable off-device. It records
  what it was *asked* to do, which is how the assertions are written: a test checks the clip was
  trimmed to the configured duration, not that nothing threw.

**The guard is a floor as well as a clamp, and the floor was the interesting half.** "Clamp the
trim range at zero" prevents an *inverted* range, which `AVAssetExportSession` rejects with no
error a caller can act on. It cannot prevent a range that is merely tiny: open the camera, press
twice inside half a second, and the recording is around 0.4s — exportable, storable, and a
frozen frame behind a play button. Below `minimumRecordedDuration` there is no clip, and the
moment is photographs only.

**The write-up caught a bug in its own first draft, which is the reason to write them.** The
first `validatedClipDuration` guarded on `isFinite`, which handles `NaN` at the cost of two
wrong answers: an infinite setting became the *default* rather than the end of the range it
names. `NaN` fails every comparison, so `min`/`max` pass it straight through — and that is the
one input the clamp exists to catch. Guarding on `isNaN` instead makes both infinities clamp
correctly through the same arithmetic that handles every other value, with no branch of its own.

**Sixteen tests, table-driven.** The ones that earn their keep are the boundaries: the floor
asserted from *both* sides (0.5s yields a clip, 0.4999s does not), a recording one millisecond
either side of an exact length, and a floating-point sweep asserting the *relationship* —
`duration <= recorded`, `end >= start` — rather than a literal, because a literal asserts the
representation error instead of the behaviour. Two of them failed against the implementation as
first written.

**Not done, deliberately:** the `AVCaptureMovieFileOutput` attachment, the microphone prompt,
playback, and the Settings toggle. The toggle especially — surfacing it before the recorder
works is precisely the dead control `Models.swift` warns against, so it arrives with the
feature or not at all.

### Progress as of 2026-10-04 — wired end to end, and three defects that only wiring finds

The feature works from camera-open to playback. Five commits, `33a0cf3` through `27ff180`.

**Nothing called `enableMovieOutput`.** The recorder existed and no production code ever invoked
the method that attaches its output, so `controller.movieFileOutput` was permanently `nil` and
every real `startRecording` would have thrown `outputUnavailable` — which ADR-013's design
correctly swallows. The app would have shown BTS as on and recorded nothing, forever, with
nothing to report. **This is the third silent failure of the same shape this session**, after the
`videoOutput` migration defect and the Release-only `try` warning, and it is why each is now
guarded rather than merely fixed.

**Ordering is the whole feature and nothing on screen reveals it.** The controller attaches a
movie output only to sessions configured *after* `wantsMovieOutput` is set, so the request must
precede `startSession` while the recording must follow it — two acts, two methods, and
`InMemoryCaptureService` grew an event log so the order is assertable. "Both happened" passes on
the broken version; only an ordered log does not.

**A re-take permanently lost the clip.** `reshoot` and `startOver` closed the recording and
returned to `.shooting` without reopening it, so the second attempt at a moment had no clip and
no on-screen sign of it. Found by tightening one assertion from `savedBTSCount <= 1` to
`startedRecordings.count == 2` — the loose version passed a view model that recorded nothing.

**`try? stopRecording()` + `discard` wedged the recorder.** When the stop throws — which is what
ADR-027's session rebuild causes — the path is never handed back, so the bytes cannot be released
*and* `isRecording` stays `true`, which makes every later `startRecording` throw
`alreadyRecording`. Swallowed, the symptom is "BTS stopped working" with nothing to report.
`BTSRecorder.abandon()` cannot fail that way.

**Playback needed a decision, not just code.** A clip the app writes and cannot open is half a
feature. `ADR-029` records where `AVPlayer` lives, and `DesignSystemInvariantTests` now keeps the
exception table honest in both directions — an entry naming a deleted file fails, and an entry
granting an unused import fails. Both verified by breaking.

**The app icon, which had blocked submission, was the same shape of defect.** The
`AppIcon.appiconset` directory had been in the repository since day one with a `Contents.json`
naming no file; every build and every suite passed. `Scripts/make-appicon.swift` now draws it from
the design system's own geometry, and `AppIconTests` found a real one immediately: the first
render had an alpha channel, which App Store Connect rejects outright.

**Still outstanding:** the Stats `btsCount` row (Phase 7's table has carried "omitted, BTS has no
recorder" since Phase 2, and that reason has now expired), and re-running the Phase 4 gate with
BTS enabled. **That re-run is the reason to trust any of this on hardware** — a third output is
attached to the session the gate stress-tests, and no amount of unit testing substitutes for the
twenty-moment run.

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
                                   ├──► Phase 5 ──► Phase 6 ──┬──► Phase 7 ──► Phase 8 ──► Phase 9
                     Phase 3 ──────┤      Today      Archive   │     Stats     polish      share
                     photos         │         │         │     │
                                   │         └── Settings ───┘
                     Phase 4 ──────┘      (done)    │
                     capture                   BTS · now building ──► Phase 11
                                                                             release
```

**Reordered 2026-10-01**, from 7 → 8 → 9 → 10 into 7 (stats) → 8 (polish) → 9 (share), with
BTS moved to last and flagged as the phase most likely to be cut. The reasoning is ADR-023: the
premise narrowed, and the phases that serve *a daily photo journal* were ahead of the ones that
serve *an imitation of BeReal*.

Note what the diagram also shows: **the Settings screen is no longer a phase.** It shipped
inside Phase 6, because a window picker that is not reachable after onboarding is a promise the
app cannot keep — and the picker itself is meaningless unless the change re-derives the future
horizon, which was a defect waiting for a Settings screen to expose.

Phases 2 and 3 are independent and can overlap. Phases 7, 8 and 9 are largely independent of each
other once Stats is out of the way.

**Critical path:** 0 → 1 → 4 → 5 → 6, which is complete. **Roughly 3–4 days of focused work to
a shippable app** — stats, polish, share — with BTS as an optional 1.5 days on top.

---

## Test matrix

| Target | Coverage |
| --- | --- |
| iPhone 15/16/17 | Primary development device |
| An older device, if you have one | Format selection, thermal behaviour, multi-format edge cases |
| iOS 17.0 | The deployment floor — test the oldest supported OS first, it breaks in the best ways. **Note:** `onScrollVisibilityChange` is iOS 18, which is why the grid prefetches from per-cell `onAppear` |
| ~~iPad~~ | **Cannot be run as written.** `project.yml` sets `TARGETED_DEVICE_FAMILY: "1"` — iPhone only. The row said "universal build should not crash" and there is no universal build. Either the row or the setting is wrong; the setting is deliberate (PRD §6.3) so the row goes |
| Airplane mode | The full loop must work. This is a product requirement, not a test |
| Permission denied (each) | Camera, notifications, photos, mic, location — every single one. **Location is listed and does not exist**: no screen requests it and `makeMomentRecorder` never passes one, so there is nothing to deny |
| Low storage | Photo write fails cleanly; moment not silently lost |
| DST transition day | Moment resolution, day identity, streak |
| Timezone change mid-day | Day re-anchoring, **and the window boundary** — a window of 23:00–01:00 crosses midnight, and `TimeWindow.validated` explicitly does not support wrapping |
| 500+ moments | Archive scroll performance. **No UI test target exists**, so this is a DEBUG seed plus a manual scroll until one does |
| App kill mid-capture | No partial moment written |
| Window changed mid-horizon | Today keeps its moment; tomorrow onward re-derives. `MomentWindowChangeTests` |

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
