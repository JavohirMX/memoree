import QuartzCore
import SwiftUI
import UIKit

/// Displays the capture service's preview surface.
///
/// Exists because of ADR-018. The service owns an
/// `AVCaptureVideoPreviewLayer` and hands it over as a bare `CALayer`; this
/// view installs it without importing AVFoundation, so AGENTS.md §3's rule
/// that `Features/` contains no AVFoundation survives intact.
///
/// The layer is installed, never copied. A `CALayer` has exactly one superlayer,
/// so the surface is added once, on construction, and never moved. It arrives
/// unattached from the service, which is what makes adding it correct rather
/// than a reparent that would silently blank the preview.
struct CameraPreview: UIViewRepresentable {

    /// The live surface, from `CapturePhotoService.previewLayer`.
    let layer: CALayer

    func makeUIView(context: Context) -> PreviewContainer {
        PreviewContainer(surface: layer)
    }

    /// Deliberately does nothing.
    ///
    /// The surface is a live capture session. Reassigning it would pull the
    /// layer out from under a running session, and comparing layers to decide
    /// whether to update would be a way of asking "is this the same session?"
    /// — which is not a question a view should be answering.
    func updateUIView(_ uiView: PreviewContainer, context: Context) {}
}

/// Hosts the capture surface.
///
/// Adds the surface as its own sublayer rather than trying to *become* it:
/// `UIView.layer` is get-only, so making the view adopt the surface outright is
/// not expressible. Adding is correct because the surface has no superlayer when
/// it arrives — it is created by the service and handed over unattached — and a
/// `CALayer` may have exactly one superlayer, which this becomes.
final class PreviewContainer: UIView {

    private let surface: CALayer

    init(surface: CALayer) {
        self.surface = surface
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layer.addSublayer(surface)
    }

    override func layoutSubviews() {
        // The surface must track the view's bounds, or it renders at its
        // original size in the corner. ` autoresizingMask` is not used because
        // a capture session's layer does not participate in autoresizing.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = bounds
        CATransaction.commit()
        super.layoutSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — the preview is constructed in code")
    }
}
