import SwiftUI
import UIKit

/// A full-screen, interactive zoomable image viewer.
///
/// Features:
/// - Pinch-to-zoom up to 5x with smooth spring physics
/// - Pan gesture while zoomed in to inspect details
/// - Double-tap gesture to toggle between 1x and 2.5x zoom
/// - Swipe-down to dismiss when at 1x scale
/// - Pure black canvas background (#000000)
public struct FullScreenImageViewer: View {

    let image: UIImage
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragDismissOffset: CGFloat = 0

    public init(image: UIImage, onDismiss: @escaping () -> Void) {
        self.image = image
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack {
            Theme.Color.canvas
                .ignoresSafeArea()
                .opacity(backgroundOpacity)

            GeometryReader { proxy in
                let size = proxy.size
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(scale)
                    .offset(x: offset.width, y: offset.height + dragDismissOffset)
                    .gesture(magnificationGesture)
                    .simultaneousGesture(panOrDismissGesture(containerSize: size))
                    .onTapGesture(count: 2) {
                        toggleZoom()
                    }
            }

            // Close button in top-trailing corner
            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .scaledDisplayFont(Theme.Size.headerIcon, weight: .bold)
                            .foregroundStyle(Theme.Color.textPrimary)
                            .frame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
                            .background(Circle().fill(Theme.Color.surface.opacity(0.8)))
                    }
                    .buttonStyle(.plain)
                    .padding(Theme.Spacing.m)
                    .accessibilityLabel("Close full screen view")
                }
                Spacer()
            }
        }
    }

    private var backgroundOpacity: Double {
        if scale > 1.0 { return 1.0 }
        let progress = min(max(abs(dragDismissOffset) / 200.0, 0), 1.0)
        return 1.0 - (progress * 0.5)
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = lastScale * value.magnification
                scale = min(max(newScale, 1.0), 5.0)
            }
            .onEnded { _ in
                if scale < 1.0 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        scale = 1.0
                        offset = .zero
                    }
                } else if scale > 5.0 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        scale = 5.0
                    }
                }
                lastScale = scale
            }
    }

    private func panOrDismissGesture(containerSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1.0 {
                    // Pan around zoomed image
                    let maxOffsetX = max(0, (containerSize.width * (scale - 1)) / 2)
                    let maxOffsetY = max(0, (containerSize.height * (scale - 1)) / 2)

                    let proposedX = lastOffset.width + value.translation.width
                    let proposedY = lastOffset.height + value.translation.height

                    offset = CGSize(
                        width: min(max(proposedX, -maxOffsetX), maxOffsetX),
                        height: min(max(proposedY, -maxOffsetY), maxOffsetY)
                    )
                } else {
                    // Drag down to dismiss when at 1x
                    if value.translation.height > 0 {
                        dragDismissOffset = value.translation.height
                    }
                }
            }
            .onEnded { value in
                if scale > 1.0 {
                    lastOffset = offset
                } else {
                    if value.translation.height > 100 || value.velocity.height > 600 {
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragDismissOffset = 0
                        }
                    }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            if scale > 1.0 {
                scale = 1.0
                lastScale = 1.0
                offset = .zero
                lastOffset = .zero
            } else {
                scale = 2.5
                lastScale = 2.5
            }
        }
    }
}
