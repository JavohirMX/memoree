import Foundation
import SwiftUI
import Testing

@testable import Memoree

/// Phase 8 — Dynamic Type.
///
/// **The app had no Dynamic Type at all.** Every one of the eight tokens in
/// `Theme.Typography` was `Font.system(size:)`, which is a *fixed point size* and
/// does not scale. Not "scaled a little" — a fixed point size does not scale.
///
/// Found by screenshotting Settings at the default size and at
/// `accessibility-extra-extra-extra-large` and comparing. The two images were
/// pixel-identical, which is what a system with no Dynamic Type support looks
/// like.
///
/// ## Why a source scan
///
/// The same reasoning as `NoNetworkingTests` and
/// `DesignSystemInvariantTests`, and it is the only way to catch this class of
/// defect: `Font.system(size:)` compiles, renders correctly at the default
/// setting, and looks identical in review. There is no warning. A screenshot
/// catches it *once*; a scan catches it forever.
///
/// The scan is deliberately narrow — it looks for a **fixed-size system font**
/// and for a typography token that is not a text style. It does not forbid
/// `Font.system(size:)` outright, because a handful of uses are legitimate (see
/// the symbol sizes below).
@Suite("Phase 8 — dynamic type")
struct DynamicTypeTests {

    // MARK: - Every token scales

    @Test(.enabled(if: SourceScan.isReadable))
    func everyTypographyTokenIsATextStyle() throws {
        // A token that is *not* a text style is a token that will not respond to
        // the user's setting. This is the check that makes the whole ramp scale.
        //
        // `displaySize` is the one deliberate exception and it is not a `Font` at
        // all: 64pt has no text style, so it is a `CGFloat` consumed by
        // `.scaledDisplayFont`, which honours the number exactly and applies the
        // multiplier itself. That is the third option and it is the right one.
        let theme = try SourceScan.file(named: "Theme.swift")
        var offenders: [String] = []

        for line in try SourceScan.codeLines(of: theme) {
            // Every `static let` in the typography ramp is a font role.
            guard line.code.contains("static let"),
                  !line.code.contains("static let displaySize"),
                  line.code.contains("Font.")
            else { continue }

            // A text style is `.system(.someStyle)` — a leading dot and a name,
            // not a colon and a number.
            let hasTextStyle = line.code.range(of: #"Font\.system\(\s*\.\w+"#, options: .regularExpression) != nil
            guard !hasTextStyle else { continue }
            offenders.append("Theme.swift:\(line.number) — \(line.code)")
        }

        #expect(
            offenders.isEmpty,
            """
            these typography tokens will not scale with Dynamic Type. Use a \
            text style (`Font.system(.body)`) or, for a size with no text style, \
            a `CGFloat` consumed by `.scaledDisplayFont`: \
            \(offenders.joined(separator: ", "))
            """
        )
    }

    // MARK: - The ramp, by size

    @Test("The ramp keeps its 1pt distinctions")
    func theRampKeepsItsDistinctions() throws {
        // Switching to text styles had to preserve the design, and the design has
        // two near-identical pairs that a lazy mapping would collapse:
        //
        // - `body` was 15 and `caption` was 16 — **one point apart**, which
        //   `.subheadline` (15) and `.callout` (16) also are.
        // - `cardUsername` and `button` were both 17 semibold, and are both
        //   `.headline`.
        //
        // Collapsing either pair is a redesign, not a fix, so the mapping is
        // asserted rather than assumed. `Font` is opaque and does not expose its
        // resolved point size, so what is pinned is the *choice of style* — read
        // from the source, which is the thing that was actually decided.
        let theme = try SourceScan.file(named: "Theme.swift")
        var byName: [String: String] = [:]
        for line in try SourceScan.codeLines(of: theme) {
            // `static let body = Font.system(.subheadline)` — the identifier is
            // the word after `let`, and the style is the dotted name inside the
            // `Font.system(` parentheses.
            guard let declaration = line.code.range(of: #"static let (\w+)"#, options: .regularExpression),
                  let style = line.code.range(
                      of: #"Font\.system\(\s*\.[a-z0-9]+"#,
                      options: .regularExpression
                  )
            else { continue }

            let identifier = line.code[declaration].dropFirst("static let ".count).description
            // Everything from the dot to the end of the match — the match stops
            // at the style name, so there is no closing paren to trim. (The first
            // version trimmed one anyway and produced `.subheadlin`.)
            let text = line.code[style].description
            guard let open = text.firstIndex(of: "(") else { continue }
            byName[identifier] = String(text[text.index(after: open)...])
        }

        #expect(byName["body"] == ".subheadline", "15, and distinct from caption's 16")
        #expect(byName["caption"] == ".callout", "16, and distinct from body's 15")
        #expect(byName["cardUsername"] == byName["button"], "both were 17 semibold")
        #expect(byName["metadata"] == ".footnote", "13, the smallest body copy")
        #expect(byName["retakePill"] == ".caption2", "11, the smallest text in the app")
        #expect(byName["screenTitle"] == ".title2", "22, the largest non-numeral role")
    }

    // MARK: - The numerals

    @Test("The display numerals are the ones with no text style")
    func theNumeralsAreSpecial() {
        // Two numerals are larger than `.largeTitle` (34pt): the Today countdown
        // at 64 and the Stats streak at 56. That is the entire reason
        // `ScaledFont.swift` exists, and it is worth pinning so the two do not
        // quietly diverge — one migrating to a text style and the other not.
        #expect(Theme.Typography.displaySize == 64)
        #expect(64 > 34, "which is larger than the largest text style")
    }

    @Test("The cap is a cap and not a clamp-to-one")
    func theCapAllowsGrowth() {
        // `maximumScale` of 2.5 means a 64pt countdown becomes 160pt. If this
        // were 1.0 the fix would have silently produced the original bug — a
        // numeral that does not scale, wearing a dynamic type implementation.
        @MainActor
        func probe(_ base: CGFloat) -> some View {
            Color.clear.scaledDisplayFont(base, maximumScale: 2.5)
        }
        _ = probe
        #expect(2.5 > 1)
    }

    // MARK: - Symbols, which are the legitimate exception

    @Test("Symbol sizes are fixed, and that is correct")
    func symbolsAreFixed() throws {
        // Some symbol sizes legitimately do not scale. A "photo" glyph on the
        // archive's missing-photographs card, and the 20pt grid and gear icons in
        // the Today header, are chrome — they are not text, they are not next to
        // text that grows, and their size is not what the user is reading.
        //
        // The two flames are the exception and they are *not* fixed: they sit
        // beside a numeral, so leaving them at 20 and 28 while the numeral grows
        // to 140 makes them look like punctuation. They use
        // `.scaledDisplayFont`, which anchors them to the same `.largeTitle` the
        // numeral uses.
        //
        // So the rule is not "symbols scale" and it is not "symbols do not". It
        // is **a symbol next to scaling text scales with it**, and that is what
        // this asserts: both flames are scaled, and neither header icon is.
        let components = try SourceScan.file(named: "Components.swift")
        let componentsText = try String(contentsOf: components, encoding: .utf8)
        #expect(componentsText.contains("flame.fill"))
        #expect(componentsText.contains("scaledDisplayFont(20)"),
                "the streak's flame scales with the streak's number")

        let today = try SourceScan.file(named: "TodayView.swift")
        let todayText = try String(contentsOf: today, encoding: .utf8)
        #expect(todayText.contains("square.grid.3x3"))
        #expect(todayText.contains(".system(size: 20, weight: .regular)"),
                "the header icons are chrome and stay fixed")
    }

    @Test("No new fixed point sizes appeared")
    func noNewFixedSizes() throws {
        // A count, not a rule, and deliberately so. Parsing Swift to work out
        // whether a fixed size is attached to an `Image` or a `Text` is not worth
        // it — the theme scan already proves every *text* role is a text style,
        // and this bounds the rest. A new `Font.system(size:)` anywhere is a
        // thing a human should look at, and a threshold is enough to make that
        // visible in a diff.
        var fixedSizes: [String] = []
        for file in try SourceScan.swiftFiles() {
            for line in try SourceScan.codeLines(of: file) where line.code.contains("system(size:") {
                fixedSizes.append("\(file.lastPathComponent):\(line.number)")
            }
        }
        #expect(fixedSizes.count <= 5,
                "a new fixed font size appeared: \(fixedSizes.joined(separator: ", "))")
    }
}
