# Memoree — Decision Log

Every significant decision, the alternatives that were genuinely considered, and what would
make us reverse it. Decisions are numbered and immutable; changing one means superseding it with
a new entry rather than editing history.

**Status key:** `Accepted` · `Superseded by ADR-nnn` · `Revisit when <condition>`

---

## Context: the starting position

Before any decision was made, the workspace was empty and the brief was "an open-source local
BeReal without the social media part that saves to your photos". Two facts shaped everything:

1. **BeReal will not export your archive.** Officially: *"It is not possible to download all
   your Memories at once."* The photos are leased, not owned. A local save is not a nice-to-have
   — it is the product's entire reason to exist.
2. **BeReal is now an advertising business.** Voodoo acquired it for ~$537M in June 2024, ads
   launched April 2025, and its own Privacy Policy documents inferring your visual interests and
   gender from your photos and name "as internal targeting criteria" for ad selection. The
   "no AIs allowed" homepage line is a brand claim, not a description of the product.

The counter-evidence matters too, and it shaped what we *kept*: BeReal's mechanic is genuinely
good, its design language is genuinely correct, and its information architecture is worth
learning from even where we delete the features.

---

## ADR-001 — No server, ever

**Status:** Accepted · **Date:** 2026-09-30

**Context.** The brief said "local". That word is ambiguous: local-first, LAN-only, self-hosted,
or "just my friends". The four have very different architectures.

**Decision.** No server. Not self-hosted, not optional, not "added later". The app makes zero
network requests at runtime.

**Consequences.**
- No accounts, no sign-in, no usernames, no server-side password reset. Ever.
- No synchronisation. If you capture on iPhone, it does not appear on your iPad.
- NFR-1 becomes mechanically testable: airplane mode must pass the full loop.
- Notifications must be local, which means the app knows the moment time in advance. That is a
  real loss of the surprise element, and it is the price of the commitment.
- Device loss loses streak history. Mitigated by JSON export; accepted.

**Alternatives rejected.** Self-hosting reintroduces the entire operations surface for zero
user-visible benefit. LAN-only limits you to one household. CloudKit is not "no server", it is
"Apple's server" — a weaker promise than the one being made here.

**Reversal trigger.** If a genuine use case emerges that cannot be served by a single device —
and given the deliberate removal of every social feature, it is hard to construct one — revisit
as ADR-0xx. Do not drift into it incrementally.

---

## ADR-002 — Delete the entire social layer

**Status:** Accepted

**Context.** BeReal's features divide into capture mechanics (the daily window, the dual
camera, the retake limit) and social mechanics (comments, RealMojis, Friends-of-Friends,
reshares, tagging, pins, discovery, Nearby, RealPeople/RealBrands, RealChat, RealGroups).

**Decision.** Delete every social mechanic without exception. Keep the capture mechanics.

**Consequences.** The app has exactly one user and no friends. Comments, RealMojis,
Friends-of-Friends, friend suggestions, reshares, tagging, pins, DMs, groups, discovery,
Nearby, and brand/creator programmes are all out of scope — not deferred.

This is why the product is coherent rather than merely small: the reciprocal gate ("you can't
see friends until you post") exists to make posting compulsory. Remove the feed and the gate
becomes meaningless, so the gate goes too. What remains is the mechanic, not the network.

**Alternatives rejected.** A stripped-down "friends-only" BeReal would still need a server, a
social graph, and a trust model — the majority of the complexity for a fraction of the value.
A "keep the feed but make it private" variant needs the same infrastructure by another name.

**Reversal trigger.** None anticipated. This is the product definition.

---

## ADR-003 — Sequential capture, not `AVCaptureMultiCamSession`

**Status:** Accepted · **Supersedes the default assumption** that true simultaneity is required

**Context.** The front-back phenomenon is BeReal's signature. `AVCaptureMultiCamSession` is the
only iOS API that delivers genuinely simultaneous capture with ISP-level hardware timestamp
synchronisation. It sounds mandatory.

Research changed the picture:

- **BeReal does not appear to use it.** User reports describe "only one camera works properly at
  a time… whichever camera takes a picture second ends up really dark" — the signature symptom of
  a single session reconfiguring between inputs. Press coverage independently describes the
  selfie landing "a few seconds later". A multi-cam session streams both previews live; users
  would not describe that as a dark second camera.
- **The API carries real cost.** `addInput`/`addOutput` fail outright — you must use
  `addInputWithNoConnections` and hand-wire `AVCaptureConnection` objects. `sessionPreset` is
  unusable; only `.inputPriority` is accepted. Format selection is restricted to
  `isMultiCamSupported` formats. `hardwareCost` is a post-commit gate with no dry run — exceed
  1.0 and the session dies, so every change must be change → commit → measure → roll back.
- **It cannot be tested in the simulator.** `isMultiCamSupported` is permanently `false` there.
- **It costs thermals.** Two sensors, two ISP paths, a Metal composite per frame, an encoder —
  during a two-minute window, on a device that is already warm.
- **No seamless zoom**, and lens availability differs from the stock camera.

**Decision.** Sequential: capture rear, reconfigure the session to front, capture front, restore
rear. Target gap ≈ 0.3–1.0s.

**Consequences.** Genuinely matches production BeReal, works on every supported iPhone, is
debuggable in far less time, and avoids the entire multi-cam failure surface. The cost is real:
the two frames are not simultaneous, and the gap is visible.

**Alternatives rejected.** `AVCaptureMultiCamSession` — the thermal and debuggability cost is
not justified when the thing being copied apparently does not use it either. A staged hybrid
(multi-cam with a sequential fallback) was offered and declined as unnecessary complexity for a
single-device app targeting iOS 17+ hardware.

**Reversal trigger.** If the sequential gap is judged too visible *and* a real device
demonstrates multi-cam is thermally stable within a two-minute window, revisit. Branch on the
runtime `isMultiCamSupported` flag — never on a device model list.

---

## ADR-004 — Two separate assets in Photos

**Status:** Accepted

**Context.** The brief said "saves to your photos". BeReal's composite is a single image with the
front inset overlapping the rear. Photos natively supports multiple resources on one `PHAsset`,
which would let a single asset flip between front and back when swiped.

**Decision.** Write **two separate `PHAsset`s** — one rear, one front — inside a single
`performChanges` block so the pair is atomic. Both at original quality with EXIF intact.

**Consequences.** Every moment doubles the user's library volume: roughly 3–5 MB per moment at
1500×2000 HEIC, so ~2.5–4 GB per year. That is disclosed in onboarding rather than hidden.
In exchange: each image is individually usable, shareable, editable and searchable in Photos;
there is no proprietary composite format; and a user who dislikes one half can delete just that
half without breaking the record.

**Alternatives rejected.** A single `PHAsset` with two resources — nicer when swiping, but it
makes both images indivisible, so deleting one means deleting both. A pre-composed single image
— convenient, but it destroys the original data, which is precisely the problem this app exists
to solve.

**Reversal trigger.** None. Splitting is the safer default and matches the ownership thesis.

---

## ADR-005 — No watermark

**Status:** Accepted

**Context.** BeReal stamps `bere.al/<username>` on images shared out of the app. Its purpose is
attribution and growth. It also means the shared file differs from the original.

**Decision.** No watermark, ever, on any surface.

**Consequences.** Nothing forces a username, so there is no profile, no `bere.al` link, and no
attribution mechanism. Shared files are byte-identical to what is in Photos.

**Alternatives rejected.** Watermarking — it is a social-growth feature for a social product we
do not have.

---

## ADR-006 — Local notifications, accepting the lost surprise

**Status:** Accepted · **Cost:** explicitly acknowledged

**Context.** BeReal's moment time is unknowable in advance: their help centre says "we truly do
not know when it's sent", and in practice the server pre-creates a moment per region and clients
poll it every five seconds. Memoree has no server, so the app must compute the time itself and
therefore always knows it.

**Decision.** Schedule local notifications via `UNCalendarNotificationTrigger` with explicit
wall-clock components, over a rolling 45-day horizon.

**Consequences.** iOS caps pending local notifications at 64; a 45-day horizon leaves headroom
and the horizon is refilled below 20 pending. Wall-clock components rather than an interval
trigger, so DST and timezone travel resolve correctly against the user's current zone. The app
knows its own moment time — a determined user could read it out of the notification list.

**Alternatives rejected.** APNs remote push — preserves the surprise but requires an always-on
server, which ADR-001 forbids. A hybrid (schedule locally, confirm with a server) — same
infrastructure problem. No notifications at all — destroys the ritual.

**Reversal trigger.** If ADR-001 is ever reversed, revisit in favour of a server-scheduled push
and recover the surprise.

---

## ADR-007 — Metadata only; reference Photos by identifier

**Status:** Accepted

**Context.** The photos go to Photos. The question is whether Memoree keeps its own copies.

**Decision.** Memoree stores metadata only — timestamps, lateness, retake count, coordinates,
`PHAsset.localIdentifier` — and streams thumbnails back out of Photos on demand. Zero duplicated
image storage.

**Consequences.** The app is a few hundred kilobytes, not gigabytes. Nothing to sync, nothing to
back up, nothing to lose on reinstall. The trade-off is that deleting Memoree loses the metadata
but not the photographs — which is precisely the intended outcome. The failure mode is a user
deleting an asset in Photos and orphaning an archive row; handled by tombstoning on load.

**Alternatives rejected.** Full local copies — redundant with Photos, doubles disk use, and
weakens the ownership story. Metadata plus local thumbnails — a real optimisation, but a
premature one for a few thousand rows.

**Reversal trigger.** If grid scrolling ever struggles with `PHCachingImageManager` at very large
counts, add a thumbnail cache. Do not move the originals.

---

## ADR-008 — Delete the Photos asset? No.

**Status:** Accepted · **Controversial; deliberately so**

**Context.** "Delete this moment" from the archive.

**Decision.** Deleting removes the **archive entry only**. The photos in the Photos library are
left untouched.

**Consequences.** A user who taps delete may expect the photos to go. They do not. This is
stated explicitly in the confirmation copy, because a delete that leaves the photo behind reads
as a bug and undermines trust. The streak recomputes immediately.

**Rationale.** These are the user's files, in the user's own library, obtained by an
add-only permission. An app granted write-only access has no business destroying them. Delete is
about Memoree's record, not about the user's photographs.

**Alternatives rejected.** Deleting the Photos assets too — technically easy with
`PHAssetChangeRequest`, and it would make "delete" mean what people expect. It also means a
mis-tap destroys data the app never owned. Reversing this is a one-line change; do not make it
casually.

---

## ADR-009 — A late-only day breaks the streak

**Status:** **Superseded by ADR-023** · **Flagged as the most likely thing to feel wrong**
**Reversed:** an off-window day no longer ends a streak — it neither grows it nor breaks it. The
decision below is preserved unedited. Its reasoning is still the best argument in this log for
*why* a streak has to mean something, which is the same question ADR-023 had to answer.

**Context.** The brief specified "late posts don't grow the streak". That leaves open whether a
late day *breaks* the streak or merely leaves it flat.

**Decision.** A day with only a late moment **breaks** the streak (resets to zero). The late
moment is still saved, archived and badged — it is a record, not a failure to be hidden. Only
an on-time moment grows the streak.

**Consequences.** The streak means "consecutive days you were on time", which is a single
coherent idea. BeReal's own monetised Streak Restore exists precisely because a single missed day
zeroes the counter.

**Alternatives rejected.** Late days leaving the streak flat — produces a streak that silently
survives a missed day and then continues, which is incoherent. "Forgiving" late days — removes
the meaning of the two-minute window entirely.

**Reversal trigger.** If this proves harsh in real use, the change is localised to
`StreakCalculator.currentStreak` and is a one-line reversal. It is the first thing to revisit
after thirty days of use.

---

## ADR-010 — Streak does not break until the day has actually ended

**Status:** Accepted

**Context.** A subtle bug that this kind of app invites.

**Decision.** At 09:00, with a moment window of 11:00–23:00, an unposted *today* is **not** a
miss. Only strictly past days break the streak.

**Rationale.** Without this rule the streak visibly resets every single morning and silently
rebuilds by evening. It would look broken, be reported as broken, and destroy trust in the
number.

**Consequences.** Pinned by an explicit unit test. Slightly more complex than "count back from
today" but the complexity is contained in one function.

---

## ADR-011 — Unlimited retakes, no deletion limit

**Status:** Accepted

**Context.** BeReal allows unlimited retakes before posting, shows friends the retake count, and
caps you at **two deletions per day** before locking you out until the next notification. It
also sells Streak Restore for $0.99.

**Decision.** Unlimited retakes, with the count stored as a private statistic. **No deletion
limit.** Deleting is unrestricted and recomputes the streak (ADR-009).

**Rationale.** The retake counter and the two-delete cap both exist to make the post *costly to
curate* and to *protect the archive's value to other viewers*. With no feed and no other
viewers, both mechanisms are vestigial. Unrestricted deletion is more honest and simpler.

**Consequences.** The retake count becomes an interesting personal statistic rather than a
social signal — a high count means a busy or awkward moment, which is arguably more interesting
than the original framing.

**Alternatives rejected.** Matching BeReal exactly (two deletes/day) — pure mimicry of a
mechanic whose purpose has been removed.

---

## ADR-012 — Dark only

**Status:** Accepted

**Context.** BeReal ships no appearance setting whatsoever — a fact confirmed across all 66
articles of its help centre. Its app is black-on-black; its 2026 *website* went light/white,
and the two have diverged.

**Decision.** Dark only. Pure `#000000` canvas. No `colorScheme` branch anywhere in the codebase.

**Consequences.** Photographs are the only saturated content on screen, which is the entire
point of the aesthetic. Half the SwiftUI design work disappears. **Pure black, never
near-black** — `#0A0A0A` reads as dark grey and breaks the effect.

**Alternatives rejected.** Following the system appearance — photographs need a different surface
treatment on a light canvas, and a light Memoree would not be Memoree.

---

## ADR-013 — Behind the Scenes: single continuous recording, trimmed

**Status:** Accepted · **Decided to build 2026-10-03**, after the implementation plan flagged
this as the phase most likely to be cut

**Context.** BTS records the few seconds before the shutter. BeReal uses a rolling buffer with a
server-reported max of 6.42 seconds, and records **only the first camera selected**.

**Decision.** Record the primary camera continuously with `AVCaptureMovieFileOutput` to a temp
file while the camera screen is open; on commit, trim to the last N seconds (default 5) with
`AVAssetExportSession(timeRange:)`. Primary camera only, matching BeReal.

**Alternatives rejected.** A segmented ring buffer with composition stitching — the correct
approach for an indefinite recording, and far more failure modes, for a session that lasts
seconds. A fixed-duration pre-roll restarted per shutter — fails if the user composes the shot
slowly.

**Consequences.** Because capture is sequential, the BTS file contains the rear stream up to the
camera switch and nothing after. That is correct and expected, not a defect. Audio requires
microphone permission, requested lazily; a denied permission yields a silent clip rather than a
blocked moment.

**2026-10-03 — the cut case was argued and rejected.** The implementation plan carried BTS as
"last, and possibly cut", for reasons worth preserving rather than deleting: it is the most
BeReal-residual feature in the document, and it is the only one that adds a second media type, a
second permission, a playback surface, and a new failure mode — *a video that will not play* — to
a product whose entire claim is one unretouched photograph a day. `AGENTS.md` §13 says to prefer
removing code to adding it.

The user chose to build it, so this ADR stands as written. **What that costs is stated here so
nobody has to infer it later:** a new failure surface enters an app that has none, and every one
of them must have a recoverable state (`AGENTS.md` §6) — no dead ends, no silent clips. The
decision also stays subordinate to Phase 4's gate: BTS attaches an output to the same
`AVCaptureSession` the twenty-moment reliability gate is still failing at 18/20, so the session
work waits until that gate is understood.

**Reversal trigger.** If playback cannot be made reliable on device — a clip that will not play
after a restart, or a session that degrades the photo path — cut the phase and delete
`btsEnabled`/`btsDuration`/`saveBTS` rather than leaving them inert. A toggle that describes a
feature which does not work is worse than no toggle, which is why those fields have sat at
`false` since Phase 2.

---

## ADR-014 — No third-party dependencies

**Status:** Accepted

**Decision.** Apple frameworks and SwiftUI only. No package manager dependencies in the app
target.

**Rationale.** Given that "no server" is the product's central claim, the supply chain is an
extension of it. A dependency tree is attack surface, licence surface, and a supply-chain
liability in a project whose entire value proposition is trustworthiness. SwiftData, SwiftUI,
AVFoundation, PhotoKit, UserNotifications and CryptoKit cover everything needed.

**Consequences.** Some things are written by hand that a package would have provided — day
identifier arithmetic, the notification horizon manager, the HEIC/EXIF round-trip. All of these
are small, testable, and were going to need custom logic anyway.

**Reversal trigger.** A dependency that is genuinely load-bearing, licence-compatible, and
worth the trust cost. Today: none.

---

## ADR-015 — Keep the streak, drop the Streak Restore paywall

**Status:** Accepted

**Context.** Streak Restore at $0.99 is the only real in-app purchase in BeReal today. Removing
all commerce was part of ADR-002; keeping the streak was not.

**Decision.** Keep the streak as a personal statistic. No paywall, no IAP, no subscription, no
ads — ever.

**Consequences.** A broken streak is a number that changed, not a loss. The streak is displayed
neutrally: a flame and a count, no "don't break it!" copy, no notification when it breaks.

---

## ADR-016 — Open questions carried into the build

**Status:** Open · **Need an answer before Phase 5**

Four items were not settled in research and are being implemented as stated assumptions:

| # | Assumption taken | Default if unconfirmed |
| --- | --- | --- |
| Q1 | Per-moment free-text note | Included; trivially removable |
| Q2 | Bundle identifier `com.javohirmx.memoree` | Derived from the local username; rename before shipping |
| Q4 | "Save to Memoree album" defaults **off** | Off; one-line change |
| — | Moment window default `11:00`–`23:00` | Replicates BeReal's observed delivery band |

---

## ADR-017 — Tombstone is a date, not a boolean

**Status:** Accepted · **Date:** 2026-09-30 · **Worked around a toolchain defect**

**Context.** `Moment` carried both `isDeleted: Bool` and `deletedAt: Date?`. Phase 2
added a test asserting that deleting a moment tombstones the row, and it failed — but not
the way a store bug usually fails. The write saved without error, `deletedAt` persisted
correctly, and `isDeleted` read back `false`.

Isolating it took several passes, each ruling the next hypothesis out:

| Hypothesis | Result |
| --- | --- |
| In-memory container limitation | Reproduced against a file-backed store |
| My `MomentStore.save()` guard skipping the save | `deletedAt` on the same object saved fine |
| A `#Predicate` on a stale value | The predicate `$0.isDeleted` matched a row whose value read `false` |
| Two `@Attribute(.unique)` properties | A model with two uniques persisted correctly |
| Property count | A 14-property model persisted correctly, a 16-property one did not |
| `TimeInterval` / optional `Double` members | A model with neither still failed |
| An optional never assigned in `init` | The simpler model without one also failed |

**The decisive test.** Two structurally identical `Bool`s in one model, differing only in
name:

```swift
@Model final class TNames {
    @Attribute(.unique) var id: UUID
    var plain: Bool      // persisted correctly
    var isDeleted: Bool   // never persisted
    var when: Date?
}
```

`plain = true` survived the save and read back `true` from a fresh `ModelContext`.
`isDeleted = true` on the same object, in the same save, read back `false`.

This is a defect in the Xcode 27 / iOS 27 SDK's SwiftData schema handling, keyed on the
property name. Nothing in Memoree causes it.

**Decision.** Store only `deletedAt` and derive `isDeleted` as a computed property. The
stored boolean is gone.

**Consequences.**
- `#Predicate` blocks must test `deletedAt == nil` / `!= nil`; SwiftData predicates cannot
  call computed properties. Four call sites updated.
- The model is smaller and, more importantly, has no duplicated state — two fields meaning
  the same thing is one more thing that can disagree with itself.
- A regression test asserts the tombstone from a **fresh `ModelContext`**, because reading
  the in-memory instance can mask this class of failure entirely.

**Alternatives rejected.** Renaming the property — it would work around one spelling rather
than remove the duplication, and the bug would return under the next name. Forcing a write
via `context.rollback()` then re-assigning — treating a symptom.

**Reversal trigger.** If Apple fixes the defect and a future toolchain persists booleans
correctly, the derived property remains the better model. No reason to restore the field.

---

## ADR-018 — The camera preview crosses the layer boundary as a `CALayer`

**Status:** Accepted · **Date:** 2026-09-30

**Context.** Two rules in AGENTS.md are in tension once a camera exists:

- §3: "`Features/` contains SwiftUI views and view models only. No AVFoundation, no PhotoKit."
- §7: a live preview must be on screen, because a camera you cannot see is not a camera.

Both are load-bearing. Dropping either is unacceptable: the first is what keeps camera *logic*
out of the view layer, the second is the product.

The naive resolutions both fail. A `UIViewRepresentable` in `Features/Camera/` that constructs
an `AVCaptureVideoPreviewLayer` violates the import rule outright. Moving the representable into
`Services/` to preserve the import rule violates §3's other half — `Services/` must not import
SwiftUI — and leaves a service returning views, which is the exact inversion the layering exists
to prevent.

**Decision.** The service owns the `AVCaptureVideoPreviewLayer` and exposes it as a plain
`CALayer`. `Features/` wraps that layer in a `UIViewRepresentable` that imports only SwiftUI and
QuartzCore. AVFoundation never crosses into `Features/`; SwiftUI never crosses into `Services/`.

```swift
// Services/Capture — imports AVFoundation, not SwiftUI
protocol CapturePhotoService: AnyObject {
    /// The live preview surface. Typed as `CALayer` so that Features can
    /// install it without importing AVFoundation.
    var previewLayer: CALayer { get }
}

// Features/Camera — imports SwiftUI and QuartzCore, not AVFoundation
struct CameraPreview: UIViewRepresentable {
    let layer: CALayer
    func makeUIView(context: Context) -> PreviewContainer { PreviewContainer(layer: layer) }
}
```

`PreviewContainer` overrides `layerClass` so the captured layer is installed directly rather than
copied — a `CALayer` cannot be reparented, so this is the only way to display it.

**Consequences.**
- The layering rule survives with no exception carved out, unlike the `PhotoKitLibrary` and
  `SequentialCaptureService` carve-outs already in AGENTS.md §3.
- The service decides `videoGravity` and mirroring, because those are capture concerns.
  The view only decides where the layer sits.
- `UIViewRepresentable.updateUIView` does nothing. The layer is a live capture surface; swapping
  or reparenting it mid-session is a bug, not an update.

**Alternatives rejected.** A representable in `Features/` importing AVFoundation — a blanket
exception to §3 that would license importing any framework anywhere. A service returning a SwiftUI
view — inverts the dependency and makes the capture layer untestable without a view host. A
snapshot-based "preview" polled into an `Image` — discards the live surface, adds a frame-copy
per tick, and is not a preview at all.

**Reversal trigger.** If Apple introduces a preview API that is itself layer-agnostic, revisit
the wrapper. The ownership rule — the service owns the surface — does not change.

---

## ADR-019 — A camera's native landscape format is the correct 3:4 format

**Status:** Accepted · **Date:** 2026-09-30 · **Found by running on hardware, not by a test**

**Context.** Phase 4's first device run failed five tests with
`noInputAvailable(.back)` on a healthy iPhone 17 — while the test immediately
before them, which calls the same device lookup, passed. The contradiction was
the clue. A `CameraDiagnostics` suite printed the state:

```
DIAG authorizationStatus(for: .video) = 3      // authorized
DIAG wideAngle back  = present
DIAG AVCaptureDeviceInput opened OK; ports = 7
DIAG formats total=57 threeByFour=0
DIAG distinct dimensions (14):
DIAG   1024x768   1280x720   1440x1080   1920x1080
DIAG   1920x1440  192x144    2592x1944   3264x2448
DIAG   352x288    3840x2160  4032x3024   480x360
DIAG   640x480    960x540
```

**Every format is landscape. There is not one portrait format among the 57.**

**The defect.** `CaptureFormatSelector.isThreeByFour` required
`width < height`, rejecting landscape formats on the reasoning that accepting
one "would yield a photo whose stored orientation disagrees with its pixels."

That reasoning was exactly backwards. A sensor is natively landscape; portrait
orientation is applied at capture and recorded as the **EXIF orientation tag**,
which `fileDataRepresentation()` carries and Photos applies on display. The
stored orientation is *supposed* to disagree with the raw sensor grid — that is
precisely how a portrait photograph emerges from a landscape sensor. So the
selector rejected every format on every real iPhone, and `selectFormat` returned
`nil` for all 57.

**Why twelve passing tests did not catch it.** The pure function was the right
design — it is testable without a camera, which is the only way to test it at
all. But its fixtures were hand-written `CMVideoDimensions` with portrait
values, so they encoded the same wrong assumption the function was written from,
and confirmed it. A test suite built entirely from invented fixtures cannot
falsify an assumption about a real device's conventions. The split made the
logic testable; it did not make the assumption testable.

**Decision.** Compare **short side over long side** against 0.75, which is
orientation-agnostic. 4032×3024 and 3024×4032 both reduce to 0.75; 1920×1080
reduces to 0.5625 and is rejected just as firmly. Widest-qualifying wins, so
4032×3024 is selected on this device.

**Consequences.**
- `CaptureError.noThreeByFourFormat` is a **distinct case** from
  `noInputAvailable`. The two demand opposite responses — no camera, versus a
  camera that cannot honour the geometry — and conflating them sent the
  diagnosis towards permissions and hardware when the fault was a ratio test.
  A misleading error message is a defect, not a cosmetic issue.
- `CaptureFormatSelectorTests` now contains the **real device's format list**
  verbatim, so the assumption is pinned against observed hardware rather than
  against imagination. A test suite that only ever sees invented data is a
  description of what someone believed.
- `CameraDiagnostics` is retained as a suite. It is not part of any exit
  criterion; it exists because the next unexplained hardware failure will want
  the same five lines of state, and reconstructing them took a device run.

**Alternatives rejected.** Accepting only portrait formats — that is what was
there, and it means no supported device can capture. Falling back to the widest
format of any ratio when none qualifies — silently producing moments at the
wrong aspect ratio, which is the failure this whole selector exists to prevent,
and unrecoverable after the fact. Relying on `sessionPreset(.photo)` to handle
geometry — unreliable across an input swap (TRD §5.3), and it would have
masked the same defect a second way.

**Reversal trigger.** If a device ever reports portrait-native formats, the
orientation-agnostic test still selects correctly, so nothing needs reversing. If
a device ships with **no** 3:4 format in either orientation, the correct response
is to reconsider the geometry, not the test — and `noThreeByFourFormat` already
reports that distinctly.

---

## ADR-020 — Deadlines live in the capture controller, not in a racing sibling task

**Status:** Accepted · **Date:** 2026-09-30

**Context.** The first hardware reliability run hung for ten minutes producing
no output. The frame-wait is a `CheckedContinuation` resumed only by an
`AVCaptureVideoDataOutput` callback; if that callback never arrives, the
continuation never resumes and the wait has no timeout at all.

The obvious fix is to race the wait against a sleep in a `ThrowingTaskGroup` and
cancel the loser. **That is unsound here, and it was tried before it was
understood.** Cancelling the capture task abandons a continuation that only the
AVFoundation delegate can resume — the task is gone, so nothing will ever resume
it — and the controller keeps `photoWait` set, after which every subsequent
capture fails with "a capture is already in flight". The controller ends up
permanently wedged rather than merely slow, so a timeout intended to *diagnose*
a hang becomes the cause of one.

**Decision.** Deadlines are scheduled **on the session queue, inside the arming
block**, and they resume the same continuation:

```swift
queue.async {
    self.frameWait = FrameWait(generation: self.generation, continuation: armed)
    queue.asyncAfter(deadline: .now() + Self.frameWaitTimeout) {
        guard let wait = self.frameWait, wait.generation == armedGeneration else { return }
        self.frameWait = nil
        wait.continuation.resume(throwing: .noDeliveredFrame(self.activePosition))
    }
}
```

Whichever of frame or deadline lands first clears the stored wait, so the other
becomes a no-op. The captured `generation` is what stops a late deadline from
stealing a *subsequent* wait's continuation. `capturePhoto` has the same
deadline, because the photo delegate is an equally external callback and
"normally prompt" is not a guarantee.

**Consequences.**
- A lost callback becomes a named, retryable error instead of a hang. The first
  run after this change reported `noDeliveredFrame(.front)` in 12.8 seconds
  where before it produced nothing at all — which is precisely what made the
  *next* bug diagnosable.
- The test keeps its per-iteration prints but no longer wraps captures in a task
  group. The progress output was worth keeping; the cancellation was not.
- A hung test and a slow device are now distinguishable, which they were not.

**Alternatives rejected.** Racing task group — described above; it converts a
diagnosable hang into a permanent wedge. A detached `asyncAfter` with no
cancellation, which is the whole problem. Letting a hang hang — a suite that can
stall indefinitely is a suite nobody trusts to report.

**Reversal trigger.** None foreseeable. If AVFoundation grew a first-class
completion-handler timeout, the manual deadline could be replaced by it.

---

## ADR-021 — Sequential capture is user-paced, and the order is random

**Status:** Accepted · **Date:** 2026-09-30 · **Supersedes the *ordering* in ADR-003**

**Context.** ADR-003 chose sequential capture over `AVCaptureMultiCamSession`, and that choice
stands. What it also specified, by way of describing the implementation, was an **order**:
capture rear, reconfigure, capture front, restore rear. The first build took that literally and
exposed it as one method — `capturePair()` — so a single shutter press produced both photographs
automatically, in sequence, with the user watching a progress spinner.

That is not the mechanic. The sequence is something the user performs:

1. The camera opens on **one** camera.
2. They compose, and press the shutter. That photograph is taken.
3. The **other** camera comes up.
4. They compose, and press again. The moment is complete.

Two shutter presses, and the second is what switches the camera. The user sees the switch
happen and composes with what they see next.

**Decision.** Capture is user-paced and the opening camera is **random per moment**.
`capturePair()` is deleted rather than kept as a convenience.

**Rationale for deleting it.** A single call that captures both halves hides the only
interesting part of the sequence — the swap is a user-visible event with a live preview on the
far side of it — and it makes "reshoot just this one half" inexpressible, because an atomic
pair has no halves to reshoot. Both properties are load-bearing, so the convenience was not
worth it.

**Rationale for randomising the order.** The product's premise is that you do not know when the
moment arrives: the delivery time is random, the window is two minutes, and the photograph is
unretouched. Fixing which camera you start on would reintroduce exactly the kind of
predictability the rest of the design removes, for no gain — the user gets both halves either
way.

**Consequences.**
- `startSession(on:)` and `switchCamera(to:)` are on the protocol. The swap is no longer hidden
  inside a higher-level call, which is how it got skipped the first time.
- The view model owns the sequence: which camera opened, which is live, and what has been
  captured. The service answers one question at a time.
- **The reliability gate became a real test.** It previously swapped the camera forty times in
  about twenty seconds and reported 18/20 then 15/20, with an AVFoundation internal assert in
  the log. That was not a product defect — it is a stress pattern the app never produces, and
  the isolated measurement of the same mechanism was 0 failures in 40 at half a second each.
  User pacing gives the sensor the settle time it wants, and the 5s frame deadline now has real
  headroom rather than being the thing under test.
- While shooting, the large view is the **live** camera and the photograph already taken sits in
  the top-left square. It is not tappable there: the large view has to stay live to compose
  with. Tap-to-swap is the review behaviour, where both slots are photographs.
- Reshooting one half is a **separate control** from the swap tap, because that tap is already
  taken. Overloading one target with two meanings would make the common action unpredictable.
- **ADR-013 needs revisiting.** Behind-the-Scenes records only the primary camera, which was
  "the rear" by definition. It is now whichever camera the user shot first.

**Alternatives rejected.** Keeping `capturePair()` as a convenience wrapper — see above. Always
opening on the rear — reintroduces predictability the rest of the design avoids, and the
instruction was explicit. Letting the user pick the opening camera before shooting — a control
for something the product deliberately does not let you plan. Randomising per shutter press
rather than per moment — the order would flicker while composing.

**Reversal trigger.** If a user reports wanting to know in advance which camera opens, that is a
product change rather than a bug, and it should be a new ADR rather than an edit to this one.
BTS following the random order is a Phase 7 decision.

---

## ADR-022 — Write to Photos first, record second, and never repeat a step that succeeded

**Status:** Accepted · **Date:** 2026-10-01 · **Found by reading a shipped code path that did nothing**

**Context.** A moment is two steps, and until now they were one:

```
capture → photoLibrary.saveMomentPair(…)   ← the whole of commit()
```

`MomentStore.record` had no call sites in the app target. The photographs
reached the user's library and the archive was never written, so `todayMoment`
was permanently `nil`, the `captured` and `capturedLate` states on the Today
screen were unreachable, the streak never moved, and dismissing the camera
returned the user to "It's time". 163 tests passed throughout — nothing
asserted that a capture became a moment.

Closing that gap raised a question the code had been avoiding by being
incomplete: **which step comes first?**

**Decision.** Photos first, then the archive row. And the two are tracked
separately, so a failure in the second never re-runs the first.

```swift
writtenAssets = try await photoLibrary.saveMomentPair(…)   // step 1
try await recordMoment(pair)                              // step 2
```

`CameraViewModel` memoises `writtenAssets`, and `retry()` re-runs only the step
that failed.

**Rationale for the ordering.** The two orderings fail differently, and one
failure is recoverable while the other is a lie.

- **Photos first** (chosen). A crash between the steps leaves two photographs
  in a library the user already owns, made by an **add-only** permission that
  physically cannot delete them. Inert. The user has two images they did not
  intend to keep, in an app whose entire thesis is that those images are
  theirs.
- **Record first** (rejected). A crash between the steps leaves an archive row
  whose `localIdentifier`s point at assets that do not exist. It renders as
  "missing from Photos" — which tells the user a moment was saved when nothing
  was. One is untidy; the other is a false statement, in exactly the direction
  the user cannot check for themselves.

Record-first looks tidier, because the moment exists before the riskier
operation. That appeal is worth naming, because it is the argument for the
version that lies.

**Rationale for tracking the steps separately.** A commit is idempotent only if
you know how far it got. Retrying the whole thing after step 2 fails writes a
*second* pair to Photos — permanently, because add-only authorisation means
Memoree can never take it back (ADR-008). A user who hit one flaky disk write
would silently accumulate duplicate pairs with no way to clean them up.

**Consequences.**
- `retry()` no longer clears `captured`. An earlier version did, on every
  attempt, which destroyed both photographs after a library write failed — the
  one case where nothing had been lost. Its test only asserted
  `phase != .permissionDenied`, which is a statement about permissions rather
  than about the pair, so it passed throughout.
- `isCommitting` exists because `writtenAssets == nil` cannot distinguish a
  failed *write* from a failed *capture*: both leave it `nil` with the pair
  intact, and answering "re-arm the shutter" for a failed commit sends the user
  back to the camera with photographs already on disk.
- `CommittedCapture.capturedAt` is the **second shutter press**, not the commit.
  The pair is two photographs up to half a minute apart while the user composes
  the selfie, and it stops being a moment at the second one. Using commit time
  would make lateness depend on how long someone stared at the review screen.
- The recorder is an injected closure, not a `Services` type. `Services` may not
  import `Persistence` (AGENTS.md §3), so a service that needed the store could
  not honestly exist; and a protocol with one production implementation and no
  seam that improved anything is an abstraction, not a boundary.
- **Re-capture orphans the previous pair, permanently, and says so.** The Today
  screen confirms before the tap, naming the consequence. This is not damage —
  it is what add-only authorisation means — and the user is entitled to know it
  before they commit rather than discovering four assets later.

**Alternatives rejected.** Record first (above). Retrying the whole commit and
accepting duplicates — a photo library that silently doubles is worse than a
moment that needs two taps. Deleting the first pair on a failed record, which
add-only authorisation cannot do and which would reverse ADR-008 if it could.
Persisting a "pending" row and reconciling it on launch: a reconciliation pass
running on every launch to fix a failure that a boolean already fixes.

**Reversal trigger.** If Memoree ever moved off add-only authorisation — a
reversal of ADR-008 in its own right — the orphan becomes cleanable and the
confirmation copy should change with it. Nothing about the *ordering* depends on
the permission level, so that alone would not reopen this.

---

## ADR-023 — The window is a reminder, not a deadline

**Status:** Accepted, **revised before implementation** · **Date:** 2026-10-01
**Supersedes:** `AGENTS.md` §2 rule 10, TRD §8's "`scheduled` has no CTA", and **ADR-009**
**Found by:** a person opening the app

**Context.** Until now, capture was refused before the moment time. `MomentState.allowsCapture`
returned false for `scheduled`, and `TodayView` renders the shutter only when
`allowsCapture` — so before your moment there was no button at all. That was deliberate:
`AGENTS.md` §2 rule 10 read *"Capture must not be possible before the moment time"*, it shipped
as `FR-5`, and Phase 5 built the refusal into the view rather than into a disabled control, so
the affordance was structurally absent.

**The defect was that the app contradicted its own first-run copy.** The onboarding notification
step says:

> Once a day, at a random moment inside your window, Memoree will ask for a photo.
> **Without this you can still open the app and capture whenever you like** — you will just
> have to remember.

The second sentence is false, and it is false whether or not the user accepted notifications. At
09:34 on a day whose moment was at 16:00, the app was a countdown with no shutter and no way to
photograph anything.

**Found by someone opening the app.** No test covered it, because the behaviour was correct as
written and asserted as correct in three places. The person using it was the first to notice that
the promise and the behaviour disagreed.

**Decision.**

1. **Capture is permitted at any time on any day.** The shutter is always available; the Today
   screen never withholds it.
2. **An off-window moment is transparent.** It does not grow the streak and it does not reset
   it. An on-time moment grows the streak; a day with **no moment at all** breaks it.
3. **No badge, and no explanation.** An off-window moment looks exactly like an on-time one. The
   streak simply does not move.

**Revised the same day, before implementation.** The first draft of this ADR said an off-window
capture *counts* — flatly, no penalty. That was rejected in review and the decision reversed:
capture is unrestricted, but only in-window photographs grow the streak. The reasoning for the
revision is below; the contradiction that started all of this is unchanged.

**The streak rule, stated exactly** — because "flat" has two readings and one of them is ADR-009
wearing a different hat:

> Walk back from today. An on-time day counts. An off-window day is **skipped** — neither
> counted nor treated as an end. A day with no moment at all **ends the walk**.

So `[on-time, on-time, off-window, on-time]` read from today backwards is a streak of **3**. A
day with no photograph is a genuine miss and still breaks it, and ADR-010 stands unchanged: an
unposted *today* is not a miss until the day has actually ended.

**`longestStreak` must change too, or the Today screen will show a lie.** It currently counts
runs of strictly-consecutive on-time days. Under this rule `currentStreak` *skips* off-window
days, so it can exceed `longestStreak` — a history of on-time, on-time, off-window, on-time
would display a streak of 3 beside "best 2". A footer whose best number is lower than the current
one is a bug users report within a day.

**Resolution: `longestStreak` becomes the longest run of consecutive days with *any* moment**,
on-time or not. That is a genuinely different and more interesting statistic — *your best run of
days you actually showed up* — it can exceed the current streak, and it is the number the footer
is actually for. Using the same skipping rule for both would make them equal whenever the user
has never missed a whole day, which is the common case for anyone still using the app.

**What this costs, stated plainly.** The two-minute window stops being the mechanic. It becomes
the thing that decides *when the phone interrupts you* and nothing else.

This decision log's own "What we deliberately kept from BeReal" table lists, first:

> **Random daily window — The mechanic. Without it there is no reason for the app to exist.**

That claim is now false, and it should be struck rather than quietly reinterpreted. What survives
is still a coherent product: *one unretouched photograph of your actual life per day, that lands
in a library you own.* That is a daily photo journal with a reminder, not a forced-spontaneity
ritual. It is a smaller and more honest thing, and the user chose it having been shown both.

The practical consequence: with any capture counting, a photograph can be made at whatever time
is convenient. The window no longer prevents curation; it only declines to *ask*. What still has
teeth is that there is one moment per day and it is unretouched.

**Consequences, in the order they will bite.**

- **`MomentState` collapses.** `lateAvailable` existed only to say "the window closed and you may
  still post". With capture always allowed it merges with the ordinary not-yet-captured case.
  `scheduled`, `open` and `captured` remain — the state machine gets *smaller*.
- **The countdown becomes decoration, which is a copy problem.** A `mm:ss` reading "1:47
  remaining" implies a deadline that does not exist. Either it goes, or it is reframed as a
  countdown to the *reminder* rather than to a closing door. **Open sub-decision.**
- **`isLate` and `lateBy` become dead.** Neither affects the streak, and there is no badge.
  Keeping a stored field that nothing reads is the same mistake as `StreakRecord`, which was
  deleted this month. Remove them from `Moment`, or keep them only if Phase 9's stats have a
  concrete use — they are derivable from `capturedAt` against the persisted `DayRecord`.
- **`StreakCalculator` changes shape, and the signature already fits.** `currentStreak` takes
  both `onTimeDays` and `capturedDays`, so the walk can skip rather than stop — the harder
  decision (how to count) was made once, at the product level, and the arithmetic follows from
  data that is already there. `ADR-009` — *a late-only day breaks the streak* — is **reversed**,
  not merely made moot: an off-window day no longer ends the run.
- **The streak is now genuinely hard, and that is the accepted cost.** One random two-minute
  slot per day, inside an eleven-hour window. A day counts only if you were ready, by luck, at
  the right moment. ADR-009 was already flagged as *"the most likely thing to feel wrong"*; this
  makes it the load-bearing rule rather than a side effect. It is defensible — the streak
  becomes a real signal of attention, and with the paywall deleted (ADR-015) there is nothing to
  monetise it with, so harsh is free. It is recorded here so that if the number sits at zero for
  a month, that is a known trade rather than a surprise.
- **Nothing on screen says why the streak did not move.** This is a deliberate choice, and it is
  the one consequence most worth watching. ADR-010's rationale was that a streak which resets for
  no visible reason *"would look broken, be reported as broken, and destroy trust in the
  number."* That risk is accepted knowingly: the user photographs, sees "Saved", and the streak
  sits still. A user who has not read this ADR will experience that as a bug in the first week.
- **The notification permission matters more than it did.** The window's only remaining job is
  deciding when to interrupt, so declining notifications no longer costs a mild degradation — it
  removes the only thing the window does. The app stays fully usable (AGENTS.md §9), and the
  "Reminders off" indicator becomes load-bearing copy.
- **PRD F3 and F9 need rewriting.** "Two-minute capture window" is no longer a capture
  constraint, and "late posting is allowed after the window" is no longer a distinction.
- **The Streak Restore paywall stays deleted (ADR-015), and now looks obviously right.** With
  capture unrestricted there is nothing to restore.
- **Less resemblance to BeReal, not more.** A one-a-day unretouched photo with a random reminder
  is a thinner imitation than a forced two-minute window, which slightly eases the Phase 11
  concern about looking like the original.

**Alternatives rejected.** *Keep the gate, fix the copy* — the smallest change, and it leaves a
09:00 user staring at a countdown. *An off-window day breaks the streak (ADR-009 as originally
written)* — the hardest rule available, and it makes a two-minute daily lottery the price of a
number; the chosen middle keeps the requirement and softens only the punishment. *A quiet line on
the Today screen saying the moment fell outside the window* — genuinely more informative, and
declined: the user chose to hear nothing rather than be told. *Two separate numbers, days
captured and current streak* — answers the problem without a display contradiction, at the cost
of a second statistic nobody asked for.

**Reversal trigger.** Two, and the first is the more likely. *If the streak reads zero for a
sustained period while the user keeps photographing*, the rule is too harsh and the badge or the
explanatory line should come back — that is the ADR-010 failure mode arriving through a different
door. *If thirty days of use show the reminder being ignored and photographs being taken at
convenient times*, the forced window was doing the work and unrestricted capture with a soft
penalty was the wrong shape entirely. Both are measurable from data the app already stores.

---

## ADR-024 — The moment time is a secret, unless you have turned off notifications

**Status:** Accepted · **Date:** 2026-10-01
**Resolves:** the blocking sub-decision in ADR-023's implementation list
**Supersedes:** TRD §8's `scheduled` → "Big countdown to the moment; 'Next moment at 14:37'"

**Context.** ADR-023 made the window a reminder rather than a deadline, which left one thing
stranded: the countdown. `TodayView` rendered a large `mm:ss` and the heading *"Next moment at
16:00"*, inherited from the era when the window closed and missing it cost something. After
ADR-023 it means nothing — you can photograph at any time — and it is worse than decoration,
because a number that ticks like a deadline now sits above a rule where missing the window costs
you the streak.

**Decision.** The moment time is not displayed while notifications are authorised.

- **Notifications on** → no countdown, no clock time, anywhere. The heading states the fact and
  stops: *Memoree will ask you once today.* The notification is the alert, and the surprise
  survives.
- **Notifications off** → the time **is** shown, because it is then the only way the user could
  ever know when the moment was. Without it, declining notifications would mean keeping the app
  open all day hoping, which is a dead end (AGENTS.md §6).

This is the one place in Memoree where the UI changes shape based on a permission, and it is
worth being explicit that the reason is not convenience. It is that the notification and the
clock are the *same information* delivered twice, and showing both spends the surprise for
nothing.

**Three places leaked the time, all now closed.** The `scheduled` heading ("Next moment at
16:00"), the countdown display, and the "Moment today" footer row.

**Consequences.**

- The Today screen is quieter, and the moment is genuinely a surprise. A user who wants to know
  the time has to turn notifications off — which is a real trade, and is the mechanism by which
  the product states its preference.
- `TodayViewModel.countdown` returns `nil` unconditionally and `CountdownDisplay` has no call
  site. `Theme.Typography.countdown` becomes unused; removing it is a separate sweep, not part of
  this decision.
- The "Reminders off" row in the footer stops being an amber warning about a *missing* thing and
  becomes the explanation for why a clock is now visible. Same copy, different job — worth
  re-reading the surrounding strings together when it is done.
- The notification permission is load-bearing in a way it was not before. It is the only channel
  by which a moment ever arrives, and it is now also the switch that determines whether the app
  tells you when. ADR-001 has no server to fall back on, so this is the price of the promise.

**Alternatives rejected.** *Show the time always* — simplest, and spends the surprise. *Show the
countdown, hide the clock* — an incoherent pair; the countdown is the clock. *Never show the time
regardless* — strands anyone who declined notifications, which AGENTS.md §9 explicitly forbids
("the ritual degrades; it does not die").

**Reversal trigger.** If users report missing moments they were awake for, the notification is
not doing its job and the time should come back unconditionally. The notification is the only
channel, so that failure has no other remedy.

---

## ADR-025 — The amber is an accent, not a warning about being late

**Status:** Accepted · **Date:** 2026-10-01
**Consequence of:** ADR-023 and ADR-024, implemented together
**Supersedes:** `AGENTS.md` §11 and TRD §10's "`late` — **only** amber: late badges,
sub-30s countdown"

**Context.** The design system had exactly one non-white colour, `#FFD60A`, and it had
exactly two jobs: the amber "posted 12m late" badge, and the countdown turning amber in its
last thirty seconds. Both were reserved for the window, and both died with it — ADR-023 made
an off-window moment deliberately indistinguishable from an on-time one, and ADR-024 removed
the countdown because a number ticking like a deadline above a rule with teeth is worse than
no number.

That left `#FFD60A` with a single remaining use: the "Reminders off" row in the Today footer.
A permission the user declined, which they can only restore in the system Settings app.

**Decision.** Keep the hex. Rename the token `late` → `accent`, and give it one reserved job:
**a permission the user declined and cannot fix inside the app.** That is the Today footer's
"Reminders off", and whatever Settings grows later. Nothing else.

**The reasoning, which is really about naming.** The alternative was to leave the token called
`late` and re-document it, on the argument that amber will mean lateness again once the Stats
screen exists and can honestly report on-time percentage. That argument is not wrong, and it is
also exactly the shape of thing this codebase keeps deleting. A token whose name contradicts
its only use is the same mistake the badge was, and the codebase's own rule is that persisted
or exposed names must not lie: `Moment.dayIdentifier` rather than `day` because `id` is the
primary key, `deletedAt` rather than a parallel `isDeleted` boolean because two fields meaning
the same thing is one more thing that can disagree with itself.

If amber should mean lateness again, that should arrive as a **new** decision with a new
reserved job written down — not as a token quietly reinterpreting itself the first time a
screen wanted a colour.

**What was deleted alongside it**, all of it dead once the badge went, and all of it recorded
because the count is the point: `LateBadge`, `CountdownDisplay.isUrgent`, `PrimaryButton
.Style.amber`, `CountdownFormatter.lateDescription`, `Theme.Typography.countdown`,
`Theme.Typography.badge`, and `MomentState.isLate` / `showsLateBadge` / `allowsCapture` /
`countsForStreak` / `isAwaitingMoment`. None of it had a caller afterwards.

**A note on what `PrimaryButton.Style.outlined` is not.** It also has no caller. It was left
in place deliberately: it is a component variant rather than a rule, it is plausibly wanted by
the Archive and Settings screens, and deleting a variant is not the same as deleting a colour
that has lost its meaning. That distinction is the reason this ADR exists at all.

**Alternatives rejected.** *Leave it called `late`* — documented above. *Delete the amber
entirely and let the app be pure black and white* — genuinely tempting, and it would have cost
the one thing the footer has to say. "Your reminders are off, and only you can fix that" is
worth exactly one colour, and one colour that appears once is not a brand hue. *Make the
"Reminders off" row white* — it removes the need for the token at all, and it also removes the
app's ability to draw attention to anything, ever, which is a worse thing to commit to than a
single documented accent.

**Reversal trigger.** If a second genuinely load-bearing use for amber appears, this decision
is not wrong — it is just outgrown, and the honest move is a new ADR naming both jobs. What
*would* be wrong is a third use arriving by accident, which is what the reserved-job line is
there to prevent.

---

## ADR-026 — Legibility outranks the third text tier, and white fill outranks convenience

**Status:** Accepted · **Date:** 2026-10-02
**Consequence of:** ADR-025, and the `AGENTS.md` §11 rule that white is the verb

**Context.** A design pass found six defects, and two of them turned out to be about *how much*
something was allowed rather than *whether it existed*.

**1. `textTertiary` was `#636366` — 3.51:1 on the canvas, 2.84:1 on a card, against WCAG AA's
4.5:1 — and it carried real words.** "best 500", the retake counts, "Wider is more random". Not
decoration that could be argued about; content.

**2. Settings' export row was a solid white capsule.** On a black canvas there is no other
emphasis available, so a filled white control is the loudest thing a screen can say — and it was
saying it for the feature nobody opens twice, two sections above the amber "Open Settings" button
that ADR-025 gave exactly one job.

**Decision.**

**`textTertiary` becomes `#848486`, and the ramp is two tiers.** `#848486` is 5.63:1 on black and
4.56:1 on a card: the faintest grey that passes on the harder of the two backgrounds it is used
on.

**The cost, stated rather than buried.** Secondary is 6.44:1 and tertiary is now 5.63:1 — a 13%
step, down from 46%. Thirteen percent does not read as a tier. This decision gives up a tier.

**That is not a compromise between two goods.** On a pure black canvas a third *distinct* tier that
passes AA does not exist. Three passing tiers do exist — `#848486` / `#B0B0B8` / `#FFFFFF`, with a
73% step — but they require brightening every piece of secondary text in the app, which changes
what the thing feels like. **Legibility is not negotiable and a third shade of grey is.** Tone
kept, tier given up.

**A filled white control is now reserved for `PrimaryButton`, and an invariant enforces it.** The
export row is outlined. This is the `AGENTS.md` §11 rule promoted from a sentence in a design
system section to a mechanical constraint, because the rule had already been broken once and the
breakage compiled, linted, and passed every test.

**Both are now measured, not asserted.** An invariant computes the WCAG ratio from the hexes in
`Theme.swift` rather than from a copy in the test — the first version of it carried its own list
and therefore asserted about the values the app used *before* the fix. A second invariant fails
on any `background(Theme.Color.textPrimary)` outside `Components.swift`; it was checked against
the reverted row and reports zero offences now, one with the pill back.

**Why the two are in one ADR.** Neither is architectural, and AGENTS.md §12 only requires
architectural decisions to be written down. They are together because they are the same claim
twice: *a reserved token is a promise, and the design system's promises should fail a build when
they are broken.* `#848486` had been carrying text it could not read; white fill had been spent
on the wrong row. Both were found by audit rather than by test, which is the part worth recording.

**Alternatives rejected.** *Brighten `textSecondary` to `#B0B0B8` and keep three tiers* — produces
three passing tiers with a real 73% step, and changes the tone of the whole app. The user chose
the tone. *Delete `textTertiary` and promote its users* — simplest, and it makes "best 500"
compete with copy that matters. *Keep the white export pill and rely on position* — it is the
last thing on the screen and position is a weaker signal than weight on this canvas.

**Reversal trigger.** If a future screen needs a genuine third text level, that screen's need is
the argument — and it arrives by brightening `textSecondary`, not by dimming something else back
below 4.5:1. If the app ever gains a second white-filled control, it is either `PrimaryButton` or
the invariant is wrong; a screenshot will not decide it.

---

## ADR-027 — The capture path recovers from a dead capture subsystem, once, silently

**Status:** Accepted · **Date:** 2026-10-03
**Consequence of:** ADR-020 (deadlines live in the capture controller), TRD §5.5

**Context.** Phase 4's twenty-moment reliability gate has been parked at 18/20 since
2026-10-01, and five attempts at fixing it each failed differently. The sixth attempt's
log carried the answer, and it had been present in an earlier run and read as noise:

```
FigCaptureSessionRemote: storage->connectionDied
err=-16453
```

**The capture daemon itself died**, at moment 3 of 20. It does not raise an error and
fire a delegate callback — it stops answering. The photo callback never arrives, so the
next capture reports `photoDataUnavailable`, and because the session is gone every
attempt after it fails identically for the life of the process.

**The bug was not the daemon. It was the asymmetry.** `SequentialCaptureService.switchCamera`
has always rebuilt the session when a swap fails, on the reasoning that a session left
mid-swap is not reliably reusable. `captureCurrentPhoto` did not. And
`CaptureError.photoDataUnavailable` is `isRetryable`, so the camera screen showed a
**Try again** button — which re-captured against the same dead session and failed the
same way, indefinitely.

That is the dead end `AGENTS.md` §6 forbids, and it is a far worse failure than the two
flaked moments the gate was counting: a user whose capture daemon dies once loses the
camera until they kill the app, and is told to keep pressing a button.

**Decision.**

**A dead-subsystem capture failure rebuilds the session once, then rethrows the original
error.** The existing retry button then does the only thing it claims to do — retry the
capture — against a live session. No new view state and no new copy: the user is told
nothing about a rebuild they did not cause and cannot act on.

**The error set is narrow, and `CaptureError.indicatesDeadCaptureSubsystem` is where the
judgement lives.** Two cases fire: `photoDataUnavailable` and `sessionReset`.

**`noDeliveredFrame` is deliberately excluded**, which is the decision most worth arguing.
It is the *other* signature of a dead subsystem and it is very tempting to include. It is
thrown by the frame wait, which lives in the swap path — and that path already rebuilds on
every error, including this one. Rebuilding again would allocate two sessions for one
failure, and `rebuildSession()` is not free: it constructs an `AVCaptureSession`, which is
a synchronous XPC round-trip to the daemon that may be the thing that is unwell. The rest
are excluded because they either recover on their own (`interrupted`,
`inUseByAnotherApp`, `thermalStateCritical`) or are not transient at all (`noInputAvailable`,
`configurationFailed`, the permission errors).

**One rebuild per attempt, never a loop, and this is structural rather than a counter.** The
method does not retry — it reports and returns — so there is nothing to bound. Unbounded
rebuild-on-failure would manufacture the exact death it exists to fix, which is the failure
mode Phase 4 spent six device runs learning about: eight session allocations in one process
is enough to wedge the daemon.

**The gate now reports how many rebuilds happened, on every run.** This is the part that
keeps the fix honest. A run in which the daemon died and the camera came back is *green*,
and a green run that silently absorbed a subsystem death is worse than a red one — it reads
as evidence the daemon stopped dying when what happened is that recovery started working.
`SESSION-REBUILDS 0` is an honestly clean run; `SESSION-REBUILDS > 0` with no failures means
the recovery carried it. **Those are different results and must never be reported as the
same one.**

**Alternatives rejected.** *Rebuild on every capture failure* — throws away a working camera
to fix a single dropped callback, and pays a session allocation for it. *Stop offering the
retry after N failures* — a new terminal state and new copy, for a case the recovery now
handles; and it would be an admission that the button was a lie, which is worse than
fixing it. *Rebuild transparently and re-capture in the same call* — the user gets a delay
they did not ask for instead of a button they can see and choose, and a silent re-capture
is exactly the "the app did something you did not ask for" shape this project keeps
rejecting. *Do nothing and let the app die* — the status quo, and the bug.

**Reversal trigger.** If a device run shows the daemon dying *and* the rebuild failing to
revive it — the third case above becoming the common one — then a dead subsystem is not
recoverable by a new session and this ADR is wrong about the mechanism. The response is a
terminal state with copy that says the camera is unavailable, not a bigger retry loop.
**The measurement that would show it is `SESSION-REBUILDS > 0` with failures in the same
run**, which is exactly why the gate reports it unconditionally.

**What this decision does not establish, and the one risk in it.** It assumes a new
`AVCaptureSession` revives a dead subsystem, on the grounds that the daemon is restarted by
the system and a fresh session connects to the new one. **That is a plausible mechanism and
not a measured one.** The counter-argument is real: `AVCaptureSession.init()` is a
*synchronous* XPC round-trip, and Phase 4 measured `rebuildSession()` at **200.8 seconds**
when it ran against a session other tests had already started and stopped. A rebuild issued
*because* the daemon died is the worst possible moment to issue one — if the daemon is
unresponsive rather than restarted, this replaces a fast, honest failure with a slow one, on
every attempt, for as long as the daemon stays dead.

Nothing here bounds that. The rebuild is bounded in *number* — one per attempt, never a
loop — but not in *duration*, because `rebuildSession()` is not cancellable in any way that
would help. **If the gate comes back with a much longer wall time than its usual six
minutes and a non-zero `SESSION-REBUILDS`, that is this risk, not a regression**, and the
fix is a deadline around the rebuild rather than a larger retry budget. Recorded here
because `AGENTS.md` §13 asks for uncertainty to be flagged rather than presented as
established fact.

**The duration risk did not materialise; a different one did, and it was worse.** A second
device run rebuilt **twice** and came back 8/20 with
`configurationFailed("frame-signal output rejected")` for the remaining moments. The cause
was in `rebuildSession` itself: it replaced `photoOutput` and reused `videoOutput`, and
**an `AVCaptureOutput` belongs to exactly one session and cannot be migrated**. The
frame-signal output stayed attached to the doomed session, `canAddOutput` on the
replacement returned false, and because nothing ever replaced the object every later
`configureSession` threw — turning one dead subsystem into a permanently bricked camera.

That defect predates this ADR and was reachable before it through a failed swap. What
changed is that the capture path now rebuilds too, so it is reachable more often — and the
second rebuild is where it bites. **Both outputs are now replaced.**

**And the duration concern above was real after all. I retired it too early.** Two
runs in which the rebuild returned quickly were enough for me to write that the risk
was "retired rather than merely unproven", and a later run contradicted that within
the hour: the gate went silent for **18 minutes** on moment 13 and never printed its
summary. The hang is not in `rebuildSession` — it is in **`startSession`**, which calls
`session.startRunning()` on the session queue inside a continuation with **no
deadline**, and `startRunning()` blocks that queue against a wedged daemon. Every
other capture operation then queues behind it forever.

**So the risk was never about the rebuild being slow. It was about there being no
deadline anywhere on the path into a running session at all** — which is this
project's own established rule, written 50 lines above the defect in the same file:
`frameWaitTimeout` and `photoWaitTimeout` both exist because *"an un-resumed
continuation hangs the app rather than failing it."* `startSession` has neither, and
the comment explaining why the others are scheduled **inside** the queue does not
apply here — the queue is stuck inside the call the deadline would have to follow.

Not yet fixed. It is recorded here as the reversal of my own claim rather than left
to be rediscovered, because "retired" is exactly the kind of word that stops the next
person looking.

---

## ADR-028 — The capture gate retries once, because the product does

**Status:** Accepted · **Date:** 2026-10-03
**Consequence of:** ADR-027

**Context.** ADR-027 made the capture path survive a dead capture subsystem. The gate
went from 18/20 to **19/20** with `SESSION-REBUILDS 1` — and the remaining failure is a
daemon death *during* a capture, which no app-side code can prevent.

That left the gate and the product disagreeing about what a failure means.

**The gate records a failure and moves to the next moment.** The product shows **Try
again**, and the user presses it — and since ADR-027 that press runs against a live
session. So the gate counted a **self-healed** failure at exactly the same weight as an
unrecoverable one, and printed `SESSION-REBUILDS > 0` with a failure beside it, which
reads as "the recovery did not work" when the recovery demonstrably had.

**This ADR changes what the gate measures. It does not change the bar.**

**Decision.**

**A moment that fails with `indicatesDeadCaptureSubsystem` is retried once, from the
shutter, exactly as a person would.** The second attempt restarts the whole moment
rather than resuming the step that failed — a moment that died during its first
capture leaves a session in a different state from one that died after the swap, and
the user starts over from the shutter rather than from halfway.

**The retry is narrower than the retry button.** Only `indicatesDeadCaptureSubsystem`
earns a second attempt. A `noInputAvailable` or a `configurationFailed` will be
exactly as true on the next try, and retrying those would manufacture recoveries a
user would not get either.

**A moment that cannot be captured after the retry is still a failure, and the test
still fails.** The criterion — twenty real captures, all succeeding — is untouched. A
run that needs the retry on most moments to reach 20/20 is not a clean run, and the
output says so.

**How many moments needed the retry is printed unconditionally, on every run, pass or
fail.** This is the part that keeps the change honest. `needed the retry` sits beside
`SESSION-REBUILDS` beside `FRAME-WAITS summary`, and a run where twenty moments
succeeded *because the recovery worked* must not read like a run where twenty moments
succeeded first time. Those are different results, and a reader must not be left to
infer which one happened.

**Alternatives rejected.** *Report two numbers and assert neither* — honest, but it
leaves the gate with no verdict, and a gate that cannot fail is a printout. *Retry
unbounded* — a user pressing a button is not a loop, and a loop here would allocate
sessions against a daemon that may be the thing that is unwell. *Retry on every
retryable error* — retries things that are not transient, and inflates the recovery
count with successes no user would have got. *Lower the bar to 19/20* — the thing this
ADR exists to avoid doing, and it would discard the very distinction the retry count
provides.

**Reversal trigger.** If the gate ever reports 20/20 with `0` needing the retry and
`SESSION-REBUILDS 0` on three consecutive cold runs, the daemon death is not
reproducible on this hardware and this ADR — along with ADR-027's recovery — is
carrying weight it no longer needs. That would be a reason to *remove* the recovery, not
to keep it: code that never fires is code that will surprise someone the one time it
does.

**What is deliberately still open.** Whether a *user* experiences any of this as a
failure. A daemon death costs one moment and one tap, and the gate now models exactly
that — but whether that is an acceptable product is not a question this document can
answer.

---

## ADR-029 — `Features/` may render an `AVPlayer`, and only for that

**Status:** Accepted · **Date:** 2026-10-04
**Consequence of:** ADR-013, ADR-018

`AGENTS.md` §3 says `Features/` contains SwiftUI views and view models only, with no
AVFoundation and no PhotoKit. It has held without exception since it was written. Behind-
the-Scenes playback breaks it, and this ADR is the exception.

**Why playback forces the question at all.** A clip the app writes into Photos and cannot
open is half a feature, and "a video that will not play" was the failure most likely to
ship — silent, in exactly the way ADR-013's design makes everything else silent. So the
question was not whether to have playback but where `AVPlayer` lives.

**Three answers were available.**

*Put the player in `DesignSystem`.* That layer imports nothing internal, so it satisfies the
rule as written with no exception at all — and it is the wrong home for a control one feature
uses. A layer whose rule is never broken is a layer nobody has to think about, and the cost
of never breaking it is a video component living where colour tokens do.

*Put it in `Features` and write the exception down.* A view is presentation, and `AVPlayer` is
presentation. The half of the rule that was never about presentation — that a view model may
not name AVFoundation — holds untouched: `BTSPlaybackModel` in the same file does not import
it either. `VideoPlayer` is AVKit's and `AVPlayer` is AVFoundation's, so the file needs both,
and a rule listing one without the other is a rule that gets re-litigated by the next person
to hit it.

*Do not have playback.* Rejected above.

**What the exception is, precisely.** One file, two imports, named in `AGENTS.md` §3's table
and in `DesignSystemInvariantTests.featureFrameworkExceptions`. Two further tests keep that
table honest, because an exception list is where rules quietly stop applying: one fails when
an entry names a file that no longer exists, and one fails when an entry grants an import its
file does not have. Both were verified by breaking them.

**Alternatives rejected.** *The exception table without the two extra tests* — an entry whose
file has been deleted keeps its hole open for whatever comes next, and nobody remembers
granting it. That is already the failure this project's own `AGENTS.md` §3 table suffered,
which is why the table was extended there at all: it listed two files for most of the
project's life while six imported a capture framework, and it read as broken when it was
merely stale. *An `AVAsset` on `PhotoLibraryService`* — it drags AVFoundation into every
consumer of the protocol, is not `Sendable`, and its `url` for a library asset is an
implementation detail rather than a promise. `PhotoLibraryService.btsClipFile(for:)` returns a
`URL` instead.

**Reversal trigger.** If playback ever needs a second AVFoundation type that is not a view —
a custom `AVPlayerLayer`, an audio session, an export outside `LiveBTSRecorder` — this ADR
stops being an exception and becomes the first line of a much bigger hole. At that point the
right move is the `DesignSystem` wrapper, not a wider table.

**What is deliberately still open.** Whether anyone wants to play a five-second clip twice.
Mute is on by default because Memoree is a thing you open in a queue, in a lecture, and a
clip that starts audible is the failure most likely to annoy.

---

## ADR-030 — Multiple captures per day and full landscape responsiveness

**Status:** Accepted

**Context.** Users testing on physical devices found:
1. Re-capturing via "Capture again" cleared previous memory captures rather than appending them. Users should be able to take as many memories as they want in a day without losing earlier captures or resetting streaks.
2. Home and Archive screens failed to display properly in landscape orientation (home menu cut off, archive detail showing half black screen without ability to swipe between moments).
3. Tapping a photo on the home screen navigated to the archive grid rather than opening that specific moment's detail directly.
4. An redundant prompt text ("Your photo is in your library") cluttered the captured state.

**Decision.**
1. **Multi-capture:** Remove unique constraint on `Moment.dayIdentifier`. Subsequent captures on the same day append rather than overwrite or soft-delete earlier captures. Streak calculations credit the day if at least one capture on that day is on-time; additional captures never penalize streaks.
2. **Carousel & Direct Navigation:** The Today screen displays a carousel of today's captures with a `1/N` badge. Tapping any capture opens `MomentDetailView` directly.
3. **Interactive Detail & Swapping:** In `MomentDetailView`, tapping the inset switches between front-large and rear-large views. Moments in the archive can be swiped horizontally via `TabView`.
4. **Orientation Responsiveness:** Both Today screen and Archive detail views dynamically adapt between portrait and landscape orientations using `Theme.Size` tokens (`compositeLandscapeMaxHeight`, `detailLandscapeMaxHeight`), with adaptive columns in the archive grid.

**Consequences.** The database preserves all memories taken by the user. Photos written to the user's library remain 100% add-only. All screens function smoothly in portrait and landscape.

**Alternatives rejected.** Retaining the 1-moment-per-day restriction — frustrates users wanting to record spontaneous events throughout the same day.

---

## ADR-031 — Today Screen Feed, Native Camera Polish, Full-Screen Photo Inspector, and BTS Fix

**Status:** Accepted · **Date:** 2026-10-04

**Context.** Hardware testing and user feedback identified several friction points:
1. **Home Feed:** Instead of a single capture button or single day carousel, users wanted a continuous feed of all memories, starting from the last two days, sorted by decreasing date.
2. **Streak Header:** "Days in a row" and "best 4" text cluttered the header. Only the flame icon and streak count number were desired.
3. **Camera UX:** Cancel button replaced with a top-leading back arrow; front camera at 1× was digitally cropped (2× factor bug); 0.5× zoom text overflowed its circular control; camera flip button was inactive; inset preview collided with top-left navigation.
4. **Photo Inspection:** Users had no way to inspect high-resolution photographs up close with pinch/pan.
5. **Behind the Scenes (BTS):** BTS video was not saving to Photos library even when enabled, due to an environment initialization race and default settings mismatch.
6. **App Icon:** The app icon was an unstyled placeholder.

**Decision.**
1. **Memories Feed:** `TodayView` and `TodayViewModel` now feature a continuous vertical feed of all recorded memories sorted chronologically descending, with section headers for relative dates (e.g. "Today", "Yesterday", and formatted dates).
2. **Minimal Streak:** `StreakDisplay` displays only `flame.fill` and the streak number.
3. **Camera Precision:** Fixed `applyZoomOnDevice` in `CaptureSessionController` to ensure single/front cameras maintain their true 1× field-of-view; 0.5× zoom font token `Theme.Typography.zoomLabel` fits comfortably inside 34pt circles; camera flip button is fully operational beside the shutter; back arrow sits at top-leading.
4. **Full-Screen Photo Inspector:** Tapping large photographs opens `FullScreenImageViewer` with interactive pinch-to-zoom (1× to 5×), double-tap zoom toggle, panning, and swipe-down dismiss.
5. **BTS Video Persistence:** Fixed `AppEnvironment` to ensure `LiveBTSRecorder` is initialized properly on physical devices, and toggling BTS on enables `saveBTS` to automatically write the video to the Photos library.
6. **App Icon:** Generated and installed an aperture-inspired, dark-themed 1024×1024 app icon.

**Consequences.** All design system invariants pass cleanly, zero warnings, and full test suite passes.

---

## Non-decisions, recorded deliberately

Things that look like decisions but are not:

- **No account system.** A consequence of ADR-001, not a choice.
- **No profile.** A consequence of ADR-005 — nothing needs attribution, so nothing needs a
  public identity.
- **No feed.** A consequence of ADR-002.
- **No blocking, reporting or moderation.** All three exist to manage other people's content.
  There is no other people's content.

---

## What we deliberately kept from BeReal

A decision log that only records deletions is misleading. These were kept on purpose:

| Kept | Why |
| --- | --- |
| ~~Random daily window~~ | **Struck by ADR-023.** This was listed as *the mechanic* — "without it there is no reason for the app to exist." The window now decides when the phone interrupts you; capture is permitted at any time, and only in-window photographs grow the streak. What remains is one unretouched photograph per day, which is a smaller claim than the one this table used to make. |
| ~~Two-minute duration~~ | **Struck by ADR-023**, with the gate. It no longer bounds anything — it does not close a shutter, and nothing is lost when it elapses. It survives only as the width of the streak-qualifying window, and as the notification's arrival time. |
| ~~The countdown~~ | **Struck by ADR-024.** Client-side `mm:ss` it was, and there was never a server countdown to copy. But after ADR-023 a number ticking at a deadline nobody had, above a rule where missing the window costs the streak, was actively untrue. What survives is a countdown to the *reminder*, shown only when notifications are off. |
| Front + back framing | The whole point of the format. |
| ~~The late marker~~ | **Struck by ADR-023.** "Truthfulness about when something happened matters more than a clean-looking grid" was a good argument while the window closed and missing it cost you. It stopped being true at the moment the window stopped costing anything: an off-window photograph is now indistinguishable from an on-time one, on every screen, and the streak simply does not move. The distinction survives in `StreakSummary.onTimePercentage` and `lateMoments` — an honest aggregate, rather than a badge on the photograph itself. |
| 3:4 portrait geometry | Matches the camera roll and BeReal's own published spec. |
| Black canvas, white type, one amber accent | A genuinely excellent design system for a photograph-first app. The amber lost its two original jobs and is now reserved for a declined permission (ADR-025). |
| No filters, no library upload | The authenticity guarantee, preserved. |
| Unlimited retakes before commit | Trying until the moment is honest is not cheating. |

Everything else was removed.
