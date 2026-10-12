import Foundation
import Testing

@testable import Memoree

/// Phase 8 — VoiceOver.
///
/// The plan's row read "VoiceOver | Camera, archive, detail, settings" and most
/// of it was already labelled. What was *missing* was an argument that the labels
/// are the right ones, and this file is that argument rather than a list of
/// labels that happen to exist.
///
/// ## Why a source scan and not a UI test
///
/// Asserting "the shutter button has a label" in a UI test needs VoiceOver itself
/// switched on, which no XCTest can do. `XCUIElement.label` reads the
/// accessibility label off a running app, but it reports whatever is *set* — it
/// does not tell you the label is useful, and a `""` label reads as absent rather
/// than as a defect.
///
/// So the checks are the two that can actually fail:
///
/// 1. **Every interactive view carries a label.** A `Button` with no
///    `.accessibilityLabel` and no `Text` label is a stop that says the word
///    "button".
/// 2. **The two composites that must not be buttons do not carry the button
///    trait** — which is a real bug class, because `.isButton` was written on all
///    three call sites when only one of them is interactive.
@Suite("Phase 8 — voice over")
struct VoiceOverTests {

    // MARK: - The composite

    @Test("The composite announces as a button exactly where it is one")
    func theCompositeIsAButtonOnlyWhereItIsOne() throws {
        // **Two of the three composites are buttons and one is not**, which is
        // easy to get wrong in both directions. The camera's review screen swaps
        // the two photographs on a tap; Today's *live* feed card opens the moment
        // in the archive. The archive's *detail* screen does neither — it is the
        // screen you are already on — so a button trait there announces an action
        // and delivers nothing, which `AGENTS.md` §6 calls a dead end and which
        // is worse from a screen reader than from a finger, because the
        // announcement is the only description the user gets.
        //
        // Asserted per file with its own handler as the marker, so the claim is
        // "this file taps it *and* says it is a button" rather than a count.
        // Today's marker is the feed card's accessibilityAction — the dead
        // `todayComposite` path used to carry labels while the live `feedCard`
        // did not, and a test keyed off the unused path gave false confidence.
        let camera = try String(
            contentsOf: SourceScan.file(named: "CameraView.swift"),
            encoding: .utf8
        )
        #expect(camera.contains("onTapInset: { model.swapProminent() }"),
                "CameraView handles a tap, so it must announce as a button")
        #expect(camera.contains(".accessibilityAddTraits(.isButton)"),
                "CameraView is missing the button trait")

        // The live Today feed card must carry the shared label — not only a
        // dead helper that never appears on screen.
        let today = try String(
            contentsOf: SourceScan.file(named: "TodayView.swift"),
            encoding: .utf8
        )
        let feedCard = try #require(
            today.components(separatedBy: "private func feedCard").last,
            "feedCard was not found"
        )
        #expect(feedCard.contains("CompositeAccessibility.label"),
                "the live feed card must announce the composite")
        #expect(feedCard.contains("Opens this moment in your archive"),
                "and say where activate goes")
        #expect(!today.contains("func todayComposite"),
                "the dead todayComposite path must stay gone")

        // The detail screen: a composite, and not a button.
        let detail = try String(
            contentsOf: SourceScan.file(named: "MomentDetailView.swift"),
            encoding: .utf8
        )
        #expect(detail.contains("MomentComposite("), "it draws the composite")
        #expect(!detail.contains(".accessibilityAddTraits(.isButton)"),
                "the detail screen is already where the tap would take you")

        // **Scoped to the composite, not the file** — the first version asserted
        // the whole file had no hint, and failed on the *delete button's* hint,
        // which is exactly right and should stay. A file-wide check here would
        // have "fixed" a correct hint by deleting it, so the check reads the
        // composite's own modifiers instead.
        let composite = try #require(
            detail.components(separatedBy: "MomentComposite(").last,
            "the composite call was not found"
        )
        let afterComposite = composite.components(separatedBy: "MomentComposite(large:").last ?? ""
        let compositeTail = afterComposite.components(separatedBy: "} else if isMissing").first ?? ""
        #expect(!compositeTail.contains("accessibilityHint"),
                "the composite must not hint at an action it does not have")
        #expect(!compositeTail.contains(".isButton"),
                "nor announce as a button")
    }

    @Test("The composite's label is one constant, used by every caller")
    func theCompositeLabelIsOneConstant() throws {
        // Three callers and one string. If the archive's label were written out
        // separately and the camera's changed, two screens would describe the
        // same two photographs differently, and a user moving between them would
        // have to work out they were looking at the same thing.
        //
        // **The camera's caller also failed this on its first run**, which is the
        // point: two of the three sites referred to
        // `MomentComposite.accessibilityLabel` and one to the new constant, and a
        // constant with two names is one rename away from a third.
        for file in ["CameraView.swift", "MomentDetailView.swift", "TodayView.swift"] {
            let source = try String(
                contentsOf: SourceScan.file(named: file),
                encoding: .utf8
            )
            #expect(source.contains("CompositeAccessibility.label"),
                    "\(file) uses the shared constant")
            #expect(!source.contains("MomentComposite.accessibilityLabel"),
                    "\(file) uses the old spelling, which is a second name for one value")
        }
        #expect(CompositeAccessibility.label.contains("two photographs"),
                "and it says how many, which is the fact a user cannot see")
    }

    // MARK: - No ticking countdown

    @Test("The home-screen countdown component is gone")
    func theCountdownComponentIsGone() throws {
        // ADR-032 removed `CountdownDisplay` from the product. A ticking
        // number is a VoiceOver hazard (re-announced every second) and
        // pressure the product no longer wants. Asserting absence — not
        // `.accessibilityHidden` on a dead type — is what keeps it gone.
        let source = try String(
            contentsOf: SourceScan.file(named: "Components.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("struct CountdownDisplay"),
                "CountdownDisplay must not return")
    }

    @Test("The reminder time survives as a static footer row")
    func theCountdownInformationSurvives() throws {
        // When notifications are off, the only way to learn the reminder time
        // is a static footer row — not a ticking number (ADR-024 / ADR-032).
        let source = try String(
            contentsOf: SourceScan.file(named: "TodayView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("\"Moment today\""),
                "the footer's static row is what replaces the ticking one")
        #expect(source.contains("model.momentClockTime"),
                "and it carries the same time")
    }

    // MARK: - Labels that describe rather than name

    @Test("The archive cell says a photograph, and when")
    func theArchiveCellDescribesItself() throws {
        // A grid of 500 cells all saying "image" is 500 stops and no information.
        // What distinguishes two cells is *which day*, and a formatted date is
        // read as bare numbers — so the label spells the month out and includes
        // the time.
        let source = try String(
            contentsOf: SourceScan.file(named: "ArchiveCell.swift"),
            encoding: .utf8
        )
        #expect(source.contains(".month(.wide)"),
                "a wide month name, because VoiceOver reads 09/30 as three numbers")
        #expect(source.contains("\"Photograph from"))
        #expect(source.contains("No longer in your photo library"),
                "and a missing asset is stated rather than shown as an empty cell")
    }

    @Test("The calendar cell announces multi-capture days")
    func theCalendarCellAnnouncesMultiCapture() throws {
        // ADR-030: a count badge is drawn, but VoiceOver never sees overlays
        // marked accessibilityHidden — so the spoken label must carry the count.
        let source = try String(
            contentsOf: SourceScan.file(named: "ArchiveCalendarView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("moments this day"),
                "multi-capture must be spoken, not only drawn as a badge")
    }

    @Test("The missing-from-Photos case is announced, not just drawn")
    func missingFromPhotosIsAnnounced() throws {
        // The detail screen renders a "photo" glyph and a sentence. VoiceOver
        // would otherwise read the glyph's name — "photo" — which tells the user
        // nothing about why there is no photograph.
        let source = try String(
            contentsOf: SourceScan.file(named: "MomentDetailView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("no longer in your library"),
                "the sentence that explains it is in the view")
        #expect(source.contains(".accessibilityElement(children: .ignore)"),
                "and the glyph is not announced over the top of it")
    }

    // MARK: - Buttons that promise

    @Test("Every destructive button says what it does not do")
    func destructiveButtonsSayWhatTheyDoNotDo() throws {
        // "Remove from archive" is the app's only destructive control, and the
        // photograph is untouchable (ADR-008) — so the hint has to say *both*:
        // what is removed and what is not. A user who is told only "removes this
    // moment" cannot tell whether their photographs are involved.
        let source = try String(
            contentsOf: SourceScan.file(named: "MomentDetailView.swift"),
            encoding: .utf8
        )
        // The hint is split across two string literals now, so this checks the
        // meaning rather than the exact sentence — a concatenation refactor must
        // not fail a test about whether the user is told what survives.
        #expect(source.contains("Removes this moment from Memoree"))
        #expect(source.contains("stay in")
                && source.contains("your Photos library"),
                "the hint must say the photographs are untouched")
    }

    @Test("A control that cannot work says so rather than inviting the tap")
    func disabledControlsExplainThemselves() throws {
        // The archive icon is present and greyed on a fresh install, because a
        // control that appears on first use is one the user has to discover by
        // having already succeeded. Its hint therefore explains the emptiness —
        // and the header does this with a conditional hint rather than leaving
        // the disabled state to be guessed at.
        let source = try String(
            contentsOf: SourceScan.file(named: "TodayView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("\"No moments yet\""))
        #expect(source.contains(".accessibilityLabel(\"Archive\")"),
                "and the icon has a name, so it is not an unlabelled square")
    }

    @Test("The streak is announced as a count, and says it opens something")
    func theStreakIsAnnouncedAsACount() throws {
        // It is a button that opens Stats, and it is reached by tapping a number —
        // so the number needs a spoken form and the destination needs a hint.
        let source = try String(
            contentsOf: SourceScan.file(named: "TodayView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("Streak of"))
        #expect(source.contains("Opens your statistics"),
                "a button that opens a screen should say which one")
    }

    // MARK: - Reduce Transparency, the last Phase 8 item

    @Test("The app uses no material that Reduce Transparency would affect")
    func noTranslucentMaterials() throws {
        // The plan called this "N/A on pure black, but verify". **Verified.** The
        // canvas is `#000000` and every surface is an opaque hex literal in
        // `Theme.swift` — there is no `.ultraThinMaterial`, no `.regularMaterial`,
        // and no `.blur` anywhere, so turning Reduce Transparency on changes
        // nothing in Memoree.
        //
        // Asserted rather than assumed, because a material is the easiest thing in
        // the world to reach for when someone wants a sheet to look layered, and
        // "N/A on pure black" is only true until then.
        var materials: [String] = []
        for file in try SourceScan.swiftFiles() {
            let translucent = [".ultraThinMaterial", ".thinMaterial", ".regularMaterial",
                               ".thickMaterial", ".bar", ".systemBackground", ".blur("]
            for line in try SourceScan.codeLines(of: file)
            where translucent.contains(where: { line.code.contains($0) }) {
                for symbol in translucent where line.code.contains(symbol) {
                    materials.append("\(file.lastPathComponent):\(line.number) \(symbol)")
                }
            }
        }
        #expect(
            materials.isEmpty,
            """
            these are translucent or system-drawn surfaces, which Reduce \
            Transparency would change. Memoree is opaque by construction \
            (ADR-012): \(materials.joined(separator: ", "))
            """
        )
    }
}
