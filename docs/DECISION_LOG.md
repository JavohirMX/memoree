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

**Status:** Accepted · **Flagged as the most likely thing to feel wrong**

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

**Status:** Accepted

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
| Random daily window | The mechanic. Without it there is no reason for the app to exist. |
| Two-minute duration | Long enough to compose a frame, short enough that you cannot curate. |
| The countdown | Client-side `mm:ss`, exactly as BeReal does it — there was never a server countdown to begin with. |
| Front + back framing | The whole point of the format. |
| The late marker | Truthfulness about when something happened matters more than a clean-looking grid. |
| 3:4 portrait geometry | Matches the camera roll and BeReal's own published spec. |
| Black canvas, white type, amber only for late | A genuinely excellent design system for a photograph-first app. |
| No filters, no library upload | The authenticity guarantee, preserved. |
| Unlimited retakes before commit | Trying until the moment is honest is not cheating. |

Everything else was removed.
