# Memoree

**One unfiltered photograph of your actual life, taken at a random moment you cannot predict, saved to the photo library you already own.**

Nothing to sign up for. Nothing to share. Nothing that isn't yours.

---

## What this is

Memoree is a native iOS app that keeps one part of BeReal and deletes the rest.

Every day, at a random moment inside a window you choose, your phone notifies you. You photograph
the scene with the rear camera and yourself with the front one. Both images are written to your
Photos library as ordinary, full-quality photos. A photograph taken within two minutes of your
moment moves the streak.

Capture is never blocked. Photograph whenever you like — an off-window moment is saved exactly
like an on-time one, and the streak simply does not move.

There is no account. There is no server. There is no feed.

It is the BeReal mechanic with the social network removed and the photo-ownership problem
solved in the architecture.

## Why

BeReal's mechanic is genuinely good. A random notification you cannot plan around removes the two
things that make social media compulsive: the ability to curate, and the ability to choose the
moment. What keeps its teeth in Memoree is narrower than the original two-minute gate and is
stated plainly rather than pretended: one unretouched photograph a day, and no library upload to
fake one with (ADR-023).

But adopting it means accepting the company behind it, which today runs in-feed ads, operates
RealBrands and RealPeople programmes, and documents — in its own Privacy Policy — inferring your
visual interests from your photographs and your gender from your name, "as internal targeting
criteria."

And the sharpest problem: **BeReal will not export your archive.** Its own help centre says it
is not possible to download all your Memories at once. The photos are leased, not owned. People
have responded by writing scrapers, a browser-extension theme, and three separate bulk-download
tools.

Memoree stores nothing on a server because there is no server. Your photographs are in your
Photos library. Delete this app tomorrow and they are still there.

## What it does not do

Not a shorter list than it looks. Every one of these is a deliberate deletion, not a missing
feature.

| | |
| --- | --- |
| No server | No sync, no accounts, no telemetry, no network calls at all |
| No feed | No friends, no followers, no strangers, no discovery |
| No engagement | No comments, no reactions, no likes, no reshares, no tagging |
| No chat | No DMs, no groups |
| No commerce | No ads, no brands, no influencers, no subscriptions, no IAP |
| No watermark | On any surface, ever |
| No filters | No LUTs, no retouching, no crop-to-perfect |
| No library upload | You cannot fake a moment with an old photo |

If you want any of those, BeReal is right there and Memoree is not trying to replace it.

## Requirements

- **iOS 17.0 or later**
- iPhone. iPad builds but is not optimised.
- A physical device. **The simulator has no camera** — the capture path cannot be developed
  there.

## Building

Requires Xcode 16 or later with the iOS SDK, and a free or paid Apple ID for signing.

If `xcodebuild` reports that it "requires Xcode", your developer directory is pointed at the
Command Line Tools:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

Then:

```sh
git clone https://github.com/<you>/memoree.git
cd memoree
open Memoree.xcodeproj
```

Select your development team under **Signing & Capabilities**, pick your device, and run.

A committed `.xcodeproj` is included so XcodeGen is optional. If you edit `project.yml`
instead, regenerate with `xcodegen generate`.

## How it works

**The window.** A random time is derived inside your chosen window (default 11:00–23:00 local, so
it never fires at 3am) from an HMAC over the day and a per-install secret held in the Keychain. It
is scheduled as a local notification over a rolling 45-day horizon, comfortably inside iOS's
64-request pending limit.

**The two minutes, and what they do.** Two minutes from your moment is how long a photograph counts
toward the streak. It is **not** a deadline: the shutter is always available, an off-window
photograph is indistinguishable from an on-time one on every screen, and only a day with no
photograph at all breaks the streak (ADR-023). Nothing anywhere tells you when your moment was —
the notification is the alert, and showing a clock beside it would spend the surprise twice. Turn
notifications off and the time reappears, because it is then the only way you could ever know
(ADR-024).

**The capture.** Rear, then front, sequentially, in a single `AVCaptureSession`, roughly half a
second apart. This is what production BeReal appears to do. It works on every supported iPhone,
and it avoids the thermal cost and debugging surface of `AVCaptureMultiCamSession`. Retake as
many times as you like — only the final pair is kept.

**The save.** Both images are written to Photos as two separate assets in one atomic change,
with the capture EXIF intact. Memoree requests **add-only** photo permission: it never deletes
from your library, and it never reads it. A moment you delete from the archive leaves both
photographs exactly where they are — they are yours (ADR-008).

**The streak.** Consecutive days with a moment. A photograph taken within two minutes of your
moment counts; one taken later does not move the streak, and does not break it either. Only a
day with no photograph at all ends the run, and a day that has not ended yet never does — your
streak does not reset every morning. Nothing on screen says which kind of day you had; the
Stats screen reports the split as a number.

## Privacy

Memoree requests at most three permissions, each for a specific stated purpose:

| Permission | Why | Deniable? |
| --- | --- | --- |
| Camera | The only thing this app does | Yes — the app will not work |
| Notifications | To tell you it is time | Yes — you can still capture from the app |
| Photos (add-only) | To save your moments | Yes — moments stay in the app |

Behind-the-Scenes video, when it exists, asks for the microphone on first use. A denial yields a
silent clip rather than a blocked moment (ADR-013).

There is no location permission and no location collection. `Moment` carries `latitude` and
`longitude` fields and nothing ever writes them, because collecting location is a product decision
that has not been made — an opt-in that prompts for something on every capture is not a small
feature, and a permission the app asks for and never uses is worse than an absent one.

There are no third-party dependencies. No analytics. No crash reporting. No advertising
identifier. No `URLSession` is constructed anywhere in the codebase.

The app works in airplane mode. That is not a limitation — it is the product.

## Documentation

| Document | What it covers |
| --- | --- |
| [`docs/PRD.md`](docs/PRD.md) | Product requirements, scope, flows, risks |
| [`docs/TRD.md`](docs/TRD.md) | Technical design, module contracts, algorithms |
| [`docs/IMPLEMENTATION_PLAN.md`](docs/IMPLEMENTATION_PLAN.md) | Eleven phases, sequenced by risk |
| [`docs/DECISION_LOG.md`](docs/DECISION_LOG.md) | Twenty-six ADRs with alternatives and reversal triggers |

[`AGENTS.md`](AGENTS.md) covers the conventions any contributor or coding agent must follow.

## Status

Pre-release. 387 tests in 44 suites on the simulator; two of them fail there by design, because a
skipped device test that reports as passed is worse than a red suite.

One exit criterion is unmet: the twenty-capture reliability gate on hardware, parked at 18/20 with
an uninvestigated capture-daemon death behind it. Release readiness is Phase 11 and has not been
done. See `docs/IMPLEMENTATION_PLAN.md` for the current phase and its reasoning.

## Licence

MIT — see [`LICENSE`](LICENSE).

---

Memoree is an independent reimplementation. It contains no BeReal code or assets and is not
affiliated with, endorsed by, or connected to BeReal SAS.
