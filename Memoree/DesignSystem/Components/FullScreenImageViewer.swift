import SwiftUI
import UIKit

/// A full-screen, interactive zoomable image viewer for single images or moment pairs.
///
/// Features:
/// - Supports single image or a pair of images (front and back)
/// - Tap to flip or horizontal swipe to switch between the pair when at 1x scale
/// - Pinch-to-zoom up to 5x with smooth spring physics
/// - Pan gesture while zoomed in to inspect details
/// - Double-tap gesture to toggle between 1x and 2.5x zoom
/// - Swipe-down to dismiss when at 1x scale
/// - Subtle page indicator dots (1/2) when a pair is present
/// - Pure black canvas background (#000000)
public struct FullScreenImageViewer: View {

    let primary: UIImage
    let secondary: UIImage?
    let onDismiss: () -> Void

    @State private var selectedIndex: Int = 0
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragDismissOffset: CGFloat = 0

    public init(
        image: UIImage,
        secondary: UIImage? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.primary = image
        self.secondary = secondary
        self.onDismiss = onDismiss
    }

    public init(
        pair: (primary: UIImage, secondary: UIImage),
        onDismiss: @escaping () -> Void
    ) {
        self.primary = pair.primary
        self.secondary = pair.secondary
        self.onDismiss = onDismiss
    }

    private var activeImage: UIImage {
        if selectedIndex == 1, let secondary {
            return secondary
        }
        return primary
    }

    private var hasPair: Bool {
        secondary != nil
    }

    public var body: some View {
        ZStack {
            Theme.Color.canvas
                .ignoresSafeArea()
                .opacity(backgroundOpacity)

            GeometryReader { proxy in
                let size = proxy.size
                Image(uiImage: activeImage)
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
                    .onTapGesture(count: 1) {
                        if scale <= 1.0 && hasPair {
                            togglePair()
                        }
                    }
            }

            // Top close button
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

            // Bottom page indicator dots if viewing a pair
            if hasPair {
                VStack {
                    Spacer()
                    pageIndicator
                        .opacity(scale > 1.0 || dragDismissOffset > 0 ? 0.0 : 1.0)
                        .padding(.bottom, Theme.Spacing.xl)
                }
            }
        }
    }

    @ViewBuilder
    private var pageIndicator: some View {
        HStack(spacing: Theme.Spacing.s) {
            Circle()
                .fill(selectedIndex == 0 ? Theme.Color.textPrimary : Theme.Color.textTertiary)
                .frame(width: Theme.Size.pageIndicatorDot, height: Theme.Size.pageIndicatorDot)

            Circle()
                .fill(selectedIndex == 1 ? Theme.Color.textPrimary : Theme.Color.textTertiary)
                .frame(width: Theme.Size.pageIndicatorDot, height: Theme.Size.pageIndicatorDot)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(Capsule().fill(Theme.Color.surface.opacity(0.75)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(selectedIndex == 0 ? "Photo 1 of 2" : "Photo 2 of 2")
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
                    withAppAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        scale = 1.0
                        offset = .zero
                    }
                } else if scale > 5.0 {
                    withAppAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
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
                    // Drag down to dismiss when primarily vertical
                    if value.translation.height > 0 && abs(value.translation.height) > abs(value.translation.width) {
                        dragDismissOffset = value.translation.height
                    }
                }
            }
            .onEnded { value in
                if scale > 1.0 {
                    lastOffset = offset
                } else {
                    // Check if drag was a dismiss gesture
                    if value.translation.height > 100 || value.velocity.height > 600 {
                        onDismiss()
                    } else if hasPair && abs(value.translation.width) > 50 && abs(value.translation.width) > abs(value.translation.height) {
                        // Horizontal swipe between pairs
                        togglePair()
                        withAppAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragDismissOffset = 0
                        }
                    } else {
                        withAppAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragDismissOffset = 0
                        }
                    }
                }
            }
    }

    private func togglePair() {
        withAppAnimation(.easeInOut(duration: 0.2)) {
            selectedIndex = (selectedIndex == 0) ? 1 : 0
        }
    }

    private func toggleZoom() {
        withAppAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
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
