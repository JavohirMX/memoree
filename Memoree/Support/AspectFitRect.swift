import CoreGraphics
import Foundation

/// Centred aspect-fit layout for drawing a source size into a target canvas.
///
/// Used by the flipbook encoder so each frame keeps its own shape on a fixed
/// 1080×1440 black canvas instead of being stretched to 3:4.
enum AspectFitRect {
    /// The rect that fits `source` inside `target` without cropping, centred.
    ///
    /// Uses `min` of the two scale ratios (letterbox). Zero or negative source
    /// dimensions fall back to the full target so callers never draw NaNs.
    static func rect(for source: CGSize, in target: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0 else {
            return CGRect(origin: .zero, size: target)
        }
        let scale = min(target.width / source.width, target.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (target.width - size.width) / 2,
            y: (target.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
