import UIKit

/// Renders the two photographs of a moment into one image, on demand.
///
/// ## Why this exists and why it is careful about not existing
///
/// `MomentComposite` already draws the front-inside-back geometry — but as
/// *SwiftUI*, on screen. Sharing needs the same thing as pixels, because a
/// `ShareLink` hands a file to another app and a view hierarchy does not travel.
///
/// Three constraints, all of which are the reason this is a separate type rather
/// than a screenshot:
///
/// - **No watermark, ever** (AGENTS.md §2.7). Not a small one, not a
///   conditional one.
/// - **No filters, no crop beyond the composite's own geometry, no retouch**
///   (AGENTS.md §2.8). The output is the two photographs and the geometry, nothing
///   else.
/// - **Never written to Photos.** It is rendered into memory, handed to the share
///   sheet, and gone. A combined image that landed in the camera roll would be a
///   fourth asset nobody asked for, in a library Memoree's whole thesis is about
///   not cluttering (ADR-008).
///
/// ## The geometry is the app's, not a new design
///
/// 3:4, inset top-left, 14pt radius, 1pt white border — identical to
/// `MomentComposite`, and stated here rather than re-derived. Two copies of this
/// geometry is how the archive ends up with a 96pt inset and the camera review
/// screen with a 108pt one, which is what that type's own documentation says
/// happened.
enum MomentCompositeRenderer {

    /// The geometry, named so the view and this cannot drift apart silently.
    enum Geometry {
        static let aspectWidth: CGFloat = 3
        static let aspectHeight: CGFloat = 4
        /// Matches `Theme.Radius.inset`.
        static let insetRadius: CGFloat = 14
        static let borderWidth: CGFloat = 1
        /// Fraction of the composite's width, matching the view's 96pt on a
        /// ~393pt screen and its 108pt on the larger camera review surface.
        static let insetScale: CGFloat = 0.245
    }

    /// Renders `back` full-bleed with `front` inset into its top-left corner.
    ///
    /// Returns `nil` when there is nothing to render — no rear photograph, or no
    /// rear *bytes*. A missing half is not an error to paper over with a
    /// placeholder: a shared image that silently contains one photograph is
    /// worse than no share button, because the user cannot tell what they sent.
    static func render(back: Data, front: Data?) -> Data? {
        guard let backImage = UIImage(data: back) else { return nil }
        return render(back: backImage, front: front.flatMap(UIImage.init(data:)))
    }

    /// The image-level overload. Separate so a caller holding `UIImage`s — the
    /// detail screen does — does not have to round-trip through `Data`.
    static func render(back: UIImage, front: UIImage?) -> Data? {
        // **No `front` is a deliberate render, not a failure.** A moment captured
        // before the second shutter press genuinely has one photograph, and
        // sharing that one photograph is correct. What is refused is a *missing*
        // rear, because a composite without its background is not a moment.
        guard backImage(for: back) != nil else { return nil }

        let size = Self.canvasSize(for: back.size)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = back.scale
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let composited = renderer.image { context in
            // The rear photograph, drawn to fill. `draw(in:)` on the full rect is
            // what "full-bleed" means here — no aspect-preserving letterboxing,
            // because the source is already 3:4 (ADR-019).
            back.draw(in: CGRect(origin: .zero, size: size))

            guard let front else { return }
            let insetSide = size.width * Geometry.insetScale
            let insetRect = CGRect(
                x: insetSide * Self.marginScale,
                y: insetSide * Self.marginScale,
                width: insetSide,
                height: insetSide
            )

            // Clipped to a rounded rect, then a hairline border in white — the
            // same two operations `MomentComposite` does, in the same order.
            let path = UIBezierPath(
                roundedRect: insetRect,
                cornerRadius: Geometry.insetRadius * Self.scaleFor(insetSide)
            )
            context.cgContext.saveGState()
            path.addClip()
            // Aspect-fill the front into the square, cropping the overflow. This
            // is the composite's own geometry and not a filter: the pixels are
            // untouched, only the drawn rect is smaller than the source.
            front.draw(in: aspectFillRect(for: front.size, in: insetRect.size))
            context.cgContext.restoreGState()

            path.lineWidth = Geometry.borderWidth
            UIColor.white.setStroke()
            path.stroke()
        }

        return composited.jpegData(compressionQuality: Self.jpegQuality)
    }

    /// JPEG quality for the shared file.
    ///
    /// **0.95, not `nil`.** `jpegData(compressionQuality:)` at the top of the
    /// range is visually lossless to the eye and roughly a quarter of the PNG.
    /// A shared photograph that has been through a lossy-enough recompression
    /// looks like a rephotograph, and the user has no way to tell that is what
    /// happened.
    static let jpegQuality: CGFloat = 0.95

    /// The gap between the inset and the composite's corner, as a fraction of
    /// the inset's side. Matches the view's `Theme.Spacing.m` padding at the
    /// default inset size.
    private static let marginScale: CGFloat = 0.166

    private static func canvasSize(for source: CGSize) -> CGSize {
        CGSize(
            width: source.width,
            height: source.width * Geometry.aspectHeight / Geometry.aspectWidth
        )
    }

    /// Scales a design-time constant for the rendered resolution.
    ///
    /// The 14pt radius is a design-time value at ~393pt wide. Rendering at a
    /// 4032px-wide source means a 14 *literal* point radius would be a hairline,
    /// so it scales with the inset's side.
    private static func scaleFor(_ side: CGFloat) -> CGFloat {
        side / (393 * Geometry.insetScale)
    }

    /// The scale and offset that fills `target` with `source`, cropping the overflow.
    ///
    /// **`max` of the two ratios, not `min`.** Filling means neither axis may be
    /// short, and that is the larger of the two — `min` would letterbox and leave
    /// a visible gap, which is the one thing a front-inside-back composite must
    /// never have. The overflow is then cropped by the caller's clip, so the
    /// pixels are untouched and only the drawn rect is larger than the inset.
    private static func aspectFillRect(for source: CGSize, in target: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0 else {
            return CGRect(origin: .zero, size: target)
        }
        let scale = max(target.width / source.width, target.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (target.width - size.width) / 2,
            y: (target.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The renderer always has a drawable rear; this exists so the `guard` above
    /// is about a zero-sized image rather than a missing argument.
    private static func backImage(for image: UIImage) -> UIImage? {
        image.size.width > 0 && image.size.height > 0 ? image : nil
    }
}
