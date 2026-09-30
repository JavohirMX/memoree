# Memoree — Product Requirements Document

**Status:** Draft v1 · **Date:** 2026-09-30 · **Licence:** MIT · **Platform:** iOS 17.0+, native Swift/SwiftUI

---

## 1. Problem statement

BeReal's mechanic works because it destroys the two things that make social media compulsive:
the ability to curate, and the ability to plan. A random daily notification opens a two-minute
window; you shoot your front and back cameras at once; you cannot go back and try again after
the fact. The result is an accidental, honest record of your life.

But adopting BeReal means accepting the company behind it. As of 2026 that means:

| Problem | Evidence |
| --- | --- |
| Ads and paid placement | Voodoo acquired BeReal for ~$537M (Jun 2024); in-app ads launched Apr 2025; a US ad platform with 400+ advertisers |
| Influencer and brand accounts | RealPeople / RealBrands / RealFans programmes |
| Your photos are used for ad targeting | Privacy Policy §1.2: visual interests derived from your photos, and gender inferred from your name and bio, "used as internal targeting criteria" |
| Everything lives on someone else's server | Firebase, Vonage SMS, OneSignal, Amplitude, Datadog |
| Engagement mechanics you did not ask for | comments, RealMojis, reshares, tagging, Friends-of-Friends, friend suggestions, DMs, group chats |
| **You cannot get your photos out** | "It is not possible to download all your Memories at once" — one at a time, forever |

That last one is the sharpest. BeReal will not export your archive. The photos are effectively
leased, not owned. Users have responded by writing GDPR-export scrapers, a browser-extension
theme that unblurs the feed, and three separate "download all my BeReals" tools.

**Memoree is the app BeReal should have been: the same forced-spontaneity ritual, with the
social network deleted and the photo ownership problem solved in the architecture.**

## 2. Product thesis

> One unfiltered photograph of your actual life, taken at a random moment you cannot predict,
> saved to the photo library you already own. Nothing to sign up for. Nothing to share.
> Nothing that isn't yours.

Three commitments follow from this, and they are non-negotiable:

1. **No server.** No account, no sign-up, no telemetry, no network calls of any kind. The app
   works in aeroplane mode. There is nothing to breach, because there is nothing to breach.
2. **You own the pixels.** Every capture is written to Photos as standard assets, at full
   quality, with EXIF intact. If you delete Memoree tomorrow, your photographs are still there.
3. **No social graph.** One user. One device. One streak, belonging to you and nobody else.

## 3. Target user

A single, sharply-drawn persona:

> Someone who liked BeReal's idea and hated its business model. Comfortable installing a build
> from Xcode or TestFlight. Aware of what "no server" means and happy to live without it. Uses
> their phone's photo library as their actual memory, not a feed.

Secondary: anyone who wants a low-pressure daily photo journal and finds Instagram's
engagement loops corrosive.

Explicitly **not** a target: teams, families sharing a device, people who want to see a friend
post from a device they did not capture it on. Every one of those requires a server.

## 4. Scope

### 4.1 In scope for v1

| # | Capability | Notes |
| --- | --- | --- |
| F1 | Daily moment window | Random time per day, computed on-device, inside a user-set window |
| F2 | Local notification | Fires at the moment time. No APNs, no server |
| F3 | Two-minute capture window | Countdown shown as `mm:ss`, computed client-side |
| F4 | Sequential front + back capture | Rear shot, then front selfie, ~0.3–1s apart |
| F5 | Composite preview | Rear full-bleed, front inset top-left; tap to swap which is primary |
| F6 | Unlimited retakes | Counted and stored; the count is a private stat, never social |
| F7 | Photos save | Front and back written to Photos as **two separate assets**, original quality, EXIF preserved |
| F8 | Behind the Scenes | Rolling ~5s buffer of the primary camera, optionally saved to Photos and shareable |
| F9 | Late posting | Allowed after the window, badged, does not grow the streak |
| F10 | Streaks | Counts consecutive days with an **on-time** moment |
| F11 | Optional location | Per-moment opt-in, coordinates only, written to EXIF, never leaves device |
| F12 | Today screen | Streak, countdown / state, today's capture |
| F13 | Grid archive | All moments, thumbnails streamed from Photos |
| F14 | Moment detail | Full-bleed view, metadata, BTS playback, share, delete |
| F15 | Stats | Days captured, streaks, on-time %, average retakes, busiest hour |
| F16 | Share sheet | Both originals + an optional combined composite, no watermark |
| F17 | Export | App metadata as JSON; photos via share sheet |

### 4.2 Explicitly out of scope

Every item below is a deliberate deletion, not a deferral. See `DECISION_LOG.md` for the
reasoning on each.

- Discovery, public feeds, Moments, Nearby, interest-based recommendations
- Friend requests, contacts sync, friend suggestions, Friends-of-Friends
- Comments, RealMojis, reactions, likes, reshares, tagging, pins
- DMs, chat, groups, group notifications
- Accounts, sign-in, usernames, profiles as social objects
- Blocking, muting, reporting, moderation
- Ads, brands, influencers, subscriptions, in-app purchases
- Streak Restore paywall
- Watermark
- Filters, LUTs, cropping, retouching, beauty modes
- Uploading from the photo library in place of a capture
- Background photo upload / sync / "other devices"
- Any analytics, crash reporting, or network transmission of any kind

### 4.3 Non-goals

Memoree is not a BeReal client, not a federated social network, and not a photo backup
service. It is a single-device capture ritual with a durable archive.

## 5. Core user flows

### 5.1 First run

1. **Welcome** — one screen, states the thesis. No account screen, because there is no account.
2. **Notification permission** — requested immediately, with a plain explanation of why.
   Declining is survivable: the app falls back to an in-app "it is time" state.
3. **Camera permission** — required for the core loop.
4. **Photo-add permission** — add-only. The app never asks to *read* your library.
5. **Moment window** — default `11:00`–`23:00`, adjustable. Explains that earlier is more random.
6. **Done.** The first moment is already scheduled.

### 5.2 The daily loop

```
        ┌──────────────────────────────────────────┐
        │  notification fires at the moment time   │
        └───────────────────┬──────────────────────┘
                            ▼
              ┌──────────────────────────┐
              │  tap → camera opens      │
              │  "1:47" counting down    │
              └────────────┬─────────────┘
                           ▼
              ┌──────────────────────────┐
              │  shutter → rear capture   │
              │  → session switches      │
              │  → front capture         │
              └────────────┬─────────────┘
                           ▼
              ┌──────────────────────────┐
              │  composite preview       │
              │  [retake]  [swap]  [send]│
              └────────────┬─────────────┘
                           ▼
              ┌──────────────────────────┐
              │  → write 2 assets to     │
              │    Photos                │
              │  → record moment         │
              │  → streak +1             │
              └────────────┬─────────────┘
                           ▼
              ┌──────────────────────────┐
              │  saved.  tomorrow.       │
              └──────────────────────────┘
```

Retake loops back to the camera at any point before Send, and only the final pair is persisted.

### 5.3 Missed the window

The Today screen moves to a **Late** state. The camera is still available. Capturing produces a
late-marked moment: saved to Photos, saved to the archive, badged amber, and **the streak does
not grow**. Late moments are first-class archive entries, not failures to be hidden.

### 5.4 Archive

Grid, newest first, 3:4 thumbnails read from Photos via `PHAsset`. Tapping opens detail:
full-bleed image, `on-time` / `late 2h14m` badge, timestamp, coordinates if captured, retake
count, BTS playback if present, and Share / Delete.

Deleting a moment removes the archive entry. It does **not** remove the assets from Photos —
those are the user's files and Memoree does not reach back and destroy them. The archive entry
is tombstoned and the streak recomputes. This is stated plainly in the UI, because a "delete"
that leaves the photo behind will otherwise read as a bug.

## 6. Requirements

### 6.1 Functional

| ID | Requirement | Priority |
| --- | --- | --- |
| FR-1 | Compute one random moment time per local calendar day, uniformly distributed within the user's configured window | Must |
| FR-2 | The moment time for a given day must be stable across app launches, reinstalls of the data, and clock changes | Must |
| FR-3 | Schedule a local notification at the moment time for a rolling horizon of upcoming days | Must |
| FR-4 | Respect the 64-request pending-notification limit; refill the horizon on every launch and foreground | Must |
| FR-5 | Refuse to capture before the moment time | Must |
| FR-6 | Allow capture after the window; mark late; compute `lateBy` | Must |
| FR-7 | Capture one rear and one front photo per attempt, sequentially, in a single capture session | Must |
| FR-8 | Allow unlimited retakes before send; persist the final retake count | Must |
| FR-9 | Write front and back to Photos as two separate assets within a single change block | Must |
| FR-10 | Preserve EXIF from capture; inject GPS only when the user opted in for that moment | Must |
| FR-11 | Store moment metadata locally, referencing Photos by `PHAsset.localIdentifier`; store no image copies | Must |
| FR-12 | Compute current and longest streak from on-time moments only | Must |
| FR-13 | Support optional BTS capture and optional BTS save to Photos | Should |
| FR-14 | Share two originals plus an optional combined composite, without a watermark | Should |
| FR-15 | Export all app metadata as a single JSON document | Should |
| FR-16 | Provide a Stats screen | Should |
| FR-17 | Request only add-only Photos authorisation | Must |
| FR-18 | Make no network requests at runtime | Must |

### 6.2 Non-functional

| ID | Requirement |
| --- | --- |
| NFR-1 | Zero network traffic. Verifiable by auditing the binary for networking symbols and by testing in airplane mode. |
| NFR-2 | No analytics, no crash reporting, no IDFA, no `NSUserTracking`. |
| NFR-3 | Camera session must never be configured on the main thread. |
| NFR-4 | Swift 6 strict concurrency. `Sendable` boundaries on all capture and scheduler types. |
| NFR-5 | Dark mode only. Pure black canvas (`#000000`) — never a near-black. |
| NFR-6 | App Store-safe: no private API selectors, no undocumented framework usage. |
| NFR-7 | Ships a `PrivacyInfo.xcprivacy` manifest declaring empty collected-data and tracking domains. |
| NFR-8 | Minimum deployment target iOS 17.0. |
| NFR-9 | All mutable state in a single store layer, testable without a device. |
| NFR-10 | Unit tests run in the simulator; capture logic is behind a protocol so it can be faked. |

### 6.3 Explicit non-requirements

- Simultaneous front/back capture (`AVCaptureMultiCamSession`) — rejected, see ADR-003
- Photo library upload as an alternative to capture
- iPad as a first-class target (universal build permitted, not optimised)
- macOS, watchOS, visionOS, Android, web

## 7. Design principles

1. **Black is the surface.** The canvas is `#000000`. Photographs are the only saturated content
   on screen. This is BeReal's actual design system, and it is correct.
2. **White is the verb.** There is no brand hue. Buttons are white fills with black labels;
   amber (`#FFD60A`) appears only for late/warning state. Nothing else is ever coloured.
3. **One number at a time.** The countdown uses tabular figures so digits do not jitter.
4. **No ceremony.** No confetti, no streak-loss guilt copy, no push notifications about your
   streak. The streak is a statistic, not a nag.
5. **The app is disposable; the photos are not.** Every screen should make the user confident
   that deleting Memoree costs them nothing.

## 8. Success criteria

Memoree succeeds if, after thirty days:

- the streak is long enough that the user notices when it breaks
- the archive contains thirty moments they actually want to keep
- the user has **not** once wondered where their photos are

Explicitly not a success metric: daily active users, retention curve, engagement, any network
effect. There is nothing to grow.

## 9. Risks

| Risk | Severity | Mitigation |
| --- | --- | --- |
| Two assets per moment doubles the user's library volume | Medium | Configurable; document typical size (~3–5 MB per moment at 1500×2000 HEIC) in onboarding |
| Sequential capture is visibly not simultaneous | Medium | Accepted. Matches real BeReal. Make the ~0.5s switch feel deliberate with a camera-switch animation and haptic |
| App reinstall loses streak history | Medium | JSON export; prominent warning on delete/restore |
| Photo deletion in Photos orphans archive entries | Low | Detect missing assets on grid load, tombstone and show a "missing from Photos" state |
| 64-notification limit silently starves the horizon | Low | Refill aggressively on launch/foreground; unit-test the refill invariant |
| DST spring-forward gap swallows a moment | Low | Wall-clock `UNCalendarNotificationTrigger` semantics fire at the first valid instant; document it |
| Local notification means the user can predict the window | Accepted | Inherent to the no-server commitment. The user already knows their own window |

## 10. Open questions

| # | Question | Status |
| --- | --- | --- |
| Q1 | Per-moment free-text note. Not requested. Included as an assumption because a photo archive with no caption field feels incomplete. | **Assumed in scope — confirm** |
| Q2 | Bundle identifier `com.javohirmx.memoree` derived from the local username. | **Placeholder — confirm** |
| Q3 | Whether a late-only day should *break* the streak or merely fail to grow it. Specified as breaking. | **Decided in ADR-009 — revisit if it feels harsh** |
| Q4 | Whether "save to a dedicated Memoree album" should default on. Currently defaults off. | **Assumed — confirm** |

## 11. Provenance

BeReal product behaviour was established from primary sources: the BeReal help centre
(`help.bereal.com`, all 66 articles enumerated via its Zendesk API), `bereal.com` legal pages
(Privacy Policy 2026-06-30, Terms 2026-09-11, Ad Guidelines), and the App Store listing.
Technical detail came from Shomil Jain's 2022 reverse-engineering write-up (`shomil.me/bereal`)
and the community reverse-engineering corpus. Where this document asserts BeReal behaviour, it
is either quoted from a primary source or labelled as inference.

Memoree is an independent reimplementation. It contains no BeReal code, no BeReal assets, and
is not affiliated with, endorsed by, or connected to BeReal SAS.
