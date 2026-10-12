import CoreGraphics
import Testing
@testable import Memoree

@Suite("Aspect-fit letterbox layout")
struct AspectFitRectTests {

    private let canvas = CGSize(width: 1080, height: 1440)

    @Test("Exact 3:4 fills the canvas")
    func exactThreeByFourFills() {
        let source = CGSize(width: 1080, height: 1440)
        let rect = AspectFitRect.rect(for: source, in: canvas)
        #expect(rect == CGRect(origin: .zero, size: canvas))
    }

    @Test("Wider than 3:4 letterboxes top and bottom")
    func widerLetterboxesVertically() {
        let source = CGSize(width: 1600, height: 900)
        let rect = AspectFitRect.rect(for: source, in: canvas)
        #expect(rect.origin.x == 0)
        #expect(rect.size.width == canvas.width)
        #expect(rect.size.height < canvas.height)
        #expect(rect.origin.y > 0)
        #expect(abs(rect.maxY - (canvas.height - rect.origin.y)) < 0.001)
    }

    @Test("Taller than 3:4 letterboxes left and right")
    func tallerLetterboxesHorizontally() {
        let source = CGSize(width: 900, height: 1600)
        let rect = AspectFitRect.rect(for: source, in: canvas)
        #expect(rect.origin.y == 0)
        #expect(rect.size.height == canvas.height)
        #expect(rect.size.width < canvas.width)
        #expect(rect.origin.x > 0)
        #expect(abs(rect.maxX - (canvas.width - rect.origin.x)) < 0.001)
    }

    @Test("Zero source size falls back to full target")
    func zeroSourceFallsBack() {
        let rect = AspectFitRect.rect(for: .zero, in: canvas)
        #expect(rect == CGRect(origin: .zero, size: canvas))
    }

    @Test("Preserves source aspect ratio")
    func preservesAspect() {
        let source = CGSize(width: 2000, height: 1000)
        let rect = AspectFitRect.rect(for: source, in: canvas)
        let sourceAspect = source.width / source.height
        let fittedAspect = rect.size.width / rect.size.height
        #expect(abs(sourceAspect - fittedAspect) < 0.001)
    }
}
