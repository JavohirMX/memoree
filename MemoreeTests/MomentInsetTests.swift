import Foundation
import Testing

@testable import Memoree

@Suite("Composite inset placement and magnetic snapping")
struct MomentInsetTests {

    private let standardContainer = CGSize(width: 390, height: 520)
    private let standardInsetWidth: CGFloat = 96

    // MARK: - InsetCorner

    @Test("All four corners exist and have descriptive accessibility names")
    func cornerCasesAndAccessibility() {
        let cases = InsetCorner.allCases
        #expect(cases.count == 4)
        #expect(cases.contains(.topLeading))
        #expect(cases.contains(.topTrailing))
        #expect(cases.contains(.bottomLeading))
        #expect(cases.contains(.bottomTrailing))

        #expect(InsetCorner.topLeading.accessibilityName == "top leading")
        #expect(InsetCorner.topTrailing.accessibilityName == "top trailing")
        #expect(InsetCorner.bottomLeading.accessibilityName == "bottom leading")
        #expect(InsetCorner.bottomTrailing.accessibilityName == "bottom trailing")
    }

    // MARK: - Resting Positions (LTR)

    @Test("Resting positions in LTR without bottom chrome sit squarely in corners")
    func restingPositionsWithoutBottomChrome() {
        let margin = Theme.Spacing.m
        let half = standardInsetWidth / 2

        let topLeading = InsetPlacement.restingCenter(
            for: .topLeading,
            in: standardContainer,
            insetWidth: standardInsetWidth,
            hasBottomChrome: false,
            isRTL: false
        )
        #expect(topLeading.x == margin + half)
        #expect(topLeading.y == margin + half)

        let topTrailing = InsetPlacement.restingCenter(
            for: .topTrailing,
            in: standardContainer,
            insetWidth: standardInsetWidth,
            hasBottomChrome: false,
            isRTL: false
        )
        #expect(topTrailing.x == standardContainer.width - margin - half)
        #expect(topTrailing.y == margin + half)

        let bottomLeading = InsetPlacement.restingCenter(
            for: .bottomLeading,
            in: standardContainer,
            insetWidth: standardInsetWidth,
            hasBottomChrome: false,
            isRTL: false
        )
        #expect(bottomLeading.x == margin + half)
        #expect(bottomLeading.y == standardContainer.height - margin - half)

        let bottomTrailing = InsetPlacement.restingCenter(
            for: .bottomTrailing,
            in: standardContainer,
            insetWidth: standardInsetWidth,
            hasBottomChrome: false,
            isRTL: false
        )
        #expect(bottomTrailing.x == standardContainer.width - margin - half)
        #expect(bottomTrailing.y == standardContainer.height - margin - half)
    }

    @Test("Resting positions with bottom chrome leave clearance above controls")
    func restingPositionsWithBottomChromeClearance() {
        let bottomLeading = InsetPlacement.restingCenter(
            for: .bottomLeading,
            in: standardContainer,
            insetWidth: standardInsetWidth,
            hasBottomChrome: true,
            isRTL: false
        )
        let bottomTrailing = InsetPlacement.restingCenter(
            for: .bottomTrailing,
            in: standardContainer,
            insetWidth: standardInsetWidth,
            hasBottomChrome: true,
            isRTL: false
        )

        let half = standardInsetWidth / 2
        let bottomEdgeLeading = bottomLeading.y + half
        let bottomEdgeTrailing = bottomTrailing.y + half

        // Clearance between inset bottom edge and container bottom
        let clearance = standardContainer.height - bottomEdgeLeading
        let requiredClearance = Theme.Spacing.m + Theme.Size.tapTarget + Theme.Spacing.s

        #expect(clearance == requiredClearance)
        #expect(bottomEdgeTrailing == bottomEdgeLeading)
    }

    // MARK: - Resting Positions (RTL)

    @Test("Resting positions in RTL mirror leading and trailing horizontally")
    func restingPositionsRTLMirror() {
        let ltrTopLeading = InsetPlacement.restingCenter(
            for: .topLeading,
            in: standardContainer,
            insetWidth: standardInsetWidth,
            hasBottomChrome: false,
            isRTL: false
        )
        let rtlTopLeading = InsetPlacement.restingCenter(
            for: .topLeading,
            in: standardContainer,
            insetWidth: standardInsetWidth,
            hasBottomChrome: false,
            isRTL: true
        )
        let ltrTopTrailing = InsetPlacement.restingCenter(
            for: .topTrailing,
            in: standardContainer,
            insetWidth: standardInsetWidth,
            hasBottomChrome: false,
            isRTL: false
        )

        #expect(rtlTopLeading.x == ltrTopTrailing.x)
        #expect(rtlTopLeading.y == ltrTopLeading.y)
    }

    // MARK: - Nearest Corner Snapping

    @Test("Nearest corner maps quadrants correctly in LTR")
    func nearestCornerLTRQuadrants() {
        let midX = standardContainer.width / 2
        let midY = standardContainer.height / 2

        // Top-left quadrant -> topLeading
        #expect(InsetPlacement.nearestCorner(
            to: CGPoint(x: midX - 20, y: midY - 20),
            in: standardContainer,
            isRTL: false
        ) == .topLeading)

        // Top-right quadrant -> topTrailing
        #expect(InsetPlacement.nearestCorner(
            to: CGPoint(x: midX + 20, y: midY - 20),
            in: standardContainer,
            isRTL: false
        ) == .topTrailing)

        // Bottom-left quadrant -> bottomLeading
        #expect(InsetPlacement.nearestCorner(
            to: CGPoint(x: midX - 20, y: midY + 20),
            in: standardContainer,
            isRTL: false
        ) == .bottomLeading)

        // Bottom-right quadrant -> bottomTrailing
        #expect(InsetPlacement.nearestCorner(
            to: CGPoint(x: midX + 20, y: midY + 20),
            in: standardContainer,
            isRTL: false
        ) == .bottomTrailing)
    }

    @Test("Nearest corner maps quadrants correctly in RTL")
    func nearestCornerRTLQuadrants() {
        let midX = standardContainer.width / 2
        let midY = standardContainer.height / 2

        // Physical left (x < midX) is trailing in RTL
        #expect(InsetPlacement.nearestCorner(
            to: CGPoint(x: midX - 20, y: midY - 20),
            in: standardContainer,
            isRTL: true
        ) == .topTrailing)

        // Physical right (x > midX) is leading in RTL
        #expect(InsetPlacement.nearestCorner(
            to: CGPoint(x: midX + 20, y: midY - 20),
            in: standardContainer,
            isRTL: true
        ) == .topLeading)
    }

    // MARK: - Bounds Clamping

    @Test("Proposed center inside bounds is preserved")
    func clampCenterPreservesValidPoint() {
        let inside = CGPoint(x: 200, y: 250)
        let clamped = InsetPlacement.clampCenter(
            inside,
            insetWidth: standardInsetWidth,
            in: standardContainer
        )
        #expect(clamped == inside)
    }

    @Test("Proposed center out of bounds is clamped strictly inside container")
    func clampCenterBoundsProtection() {
        let half = standardInsetWidth / 2
        let padding = Theme.Spacing.xs

        let farTopLeft = CGPoint(x: -100, y: -200)
        let clampedTopLeft = InsetPlacement.clampCenter(
            farTopLeft,
            insetWidth: standardInsetWidth,
            in: standardContainer
        )
        #expect(clampedTopLeft.x == half + padding)
        #expect(clampedTopLeft.y == half + padding)

        let farBottomRight = CGPoint(x: 1000, y: 1000)
        let clampedBottomRight = InsetPlacement.clampCenter(
            farBottomRight,
            insetWidth: standardInsetWidth,
            in: standardContainer
        )
        #expect(clampedBottomRight.x == standardContainer.width - half - padding)
        #expect(clampedBottomRight.y == standardContainer.height - half - padding)
    }

    // MARK: - Graceful Fallback for Degenerate Sizes

    @Test("Degenerate container size falls back safely without division by zero or NaN")
    func degenerateContainerSizeSafety() {
        let tiny = CGSize(width: 40, height: 40)
        let pos = InsetPlacement.restingCenter(
            for: .topTrailing,
            in: tiny,
            insetWidth: standardInsetWidth,
            hasBottomChrome: true,
            isRTL: false
        )
        #expect(!pos.x.isNaN && !pos.y.isNaN)
        #expect(pos.x > 0 && pos.y > 0)
    }
}
