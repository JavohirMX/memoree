#!/usr/bin/env swift

// The app icon, drawn from the design system rather than by hand.
//
// ## Why a generator
//
// An icon is the one piece of this app's visual identity that no design system
// governs, and a hand-drawn PNG is a file nobody can review: nobody can tell from
// the diff whether the inset moved or whether someone resized a layer in a tool
// that saves losslessly. So the icon is code, the code is here, and the PNG is
// build output.
//
// Every number below is either a real `Theme` value or derives from one, and the
// comments say which. If the composite geometry changes, this file is the place
// that follows it — which is the same reason `MomentComposite` exists rather than
// the geometry being written twice in a design tool.
//
// Run it:  swift Scripts/make-appicon.swift
//
// Output:  Memoree/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//
// ## The mark
//
// The composite, as geometry: the rear frame at 3:4 and the front inset into its
// top-left. That is the product's whole signature — two photographs, one moment —
// and it is drawn here as an outline rather than as a photograph, because an icon
// cannot be legible *because of* a scene. The outline is the frame; the inset is
// the other half.
//
// **Black field, white mark.** The canvas is `#000000` exactly (`AGENTS.md` §11)
// and white is the app's single emphasis. A white field with a black mark is
// equally on-brand and more conventional; it was not chosen because it would lose
// its edge against a dark home screen, and against a light one the black field is
// the stronger shape.

import AppKit
import CoreGraphics
import Foundation

// MARK: - The geometry

/// Canvas side. iOS requires a single 1024 for the modern icon format.
let canvas: CGFloat = 1024

/// The rear frame's height as a fraction of the canvas.
///
/// **0.74, and the number is the icon's real constraint.** A 3:4 frame sized off
/// its *width* — the obvious choice — comes out 930px tall on a 1024 canvas, which
/// collides with the system's squircle mask and leaves the mark touching the edge
/// it will be clipped by. Sizing off the height leaves 133px of margin top and
/// bottom, which survives the mask at every size iOS ships.
let frameHeightFraction: CGFloat = 0.74

/// The frame's aspect, from `CaptureFormatSelector.targetRatio`'s 3:4.
let frameAspect: CGFloat = 3.0 / 4.0

/// Frame corner radius as a fraction of the frame's short side.
///
/// `Theme.Radius.card` is 18 against a frame roughly 360pt wide in the app, which
/// is 5%. The icon uses **8%** rather than 5% — a corner that reads correctly at
/// 60pt is visibly rounder than the same corner at 3:4 in a 360pt frame, and the
/// alternative is an icon that looks sharper than the screen it launches.
let frameRadiusFraction: CGFloat = 0.08

/// Stroke width as a fraction of the frame's width.
///
/// **0.055, chosen from the smallest size rather than the largest.** At 1024 this
/// is 31px and looks heavy; at 60pt it is 1.9pt, and 1.9pt is the difference
/// between a frame and a hairline. Designing the icon at the size where it has to
/// work is the only way to find that number.
let strokeFraction: CGFloat = 0.050

/// The front inset's side, as a fraction of the frame's width.
///
/// **`Theme.Size.insetStandard` is 96 against a frame about 360pt wide — 27%.** The
/// icon uses 0.34, larger still, and for the same reason the corner radius is
/// rounder than the app's: at 60pt the whole icon is 60pt, the frame's width is
/// 33pt, and 27% of that is 9pt. Nine points is a speck. The *ratio* between the
/// two parts is what the eye reads first, and it survives being overweighted far
/// better than it survives being literal.
let insetFraction: CGFloat = 0.34

/// The inset's corner radius, from `Theme.Radius.inset` against `insetStandard`.
let insetRadiusFraction: CGFloat = 14.0 / 96.0

/// The inset's offset from the frame's top-left, as a fraction of its own side.
///
/// **`Theme.Spacing.m` is 12 against a 96pt inset — 12.5%.** Rounded to 14% here
/// for the same small-size reason as everything above it.
let insetInsetFraction: CGFloat = 0.14

// MARK: - Drawing

let frameHeight = canvas * frameHeightFraction
let frameWidth = frameHeight * frameAspect
let frameRect = CGRect(
    x: (canvas - frameWidth) / 2,
    y: (canvas - frameHeight) / 2,
    width: frameWidth,
    height: frameHeight
)

let stroke = frameWidth * strokeFraction
let insetSide = frameWidth * insetFraction

/// The inset's rectangle, positioned **from the top-left**.
///
/// ## CoreGraphics has its origin at the bottom-left and this does not
///
/// The first version placed the inset with the same `+` it used for the frame's
/// vertical margin, which put the mark in the **bottom-left** of the icon — the
/// wrong corner, and wrong in a way a glance should have caught.
///
/// So the position is computed top-down, where "top-left" means what it says, and
/// flipped exactly once here. Every other number in this file is unambiguous
/// because it is symmetric; this one is not, and that asymmetry is why it gets a
/// conversion of its own rather than an arithmetic sign.
let insetTopDown = CGRect(
    x: frameRect.minX + frameWidth * insetInsetFraction,
    y: frameRect.minY + frameHeight * insetInsetFraction,
    width: insetSide,
    height: insetSide
)
let insetRect = CGRect(
    x: insetTopDown.minX,
    // `canvas - maxY` converts a top-down y into CoreGraphics' bottom-left one.
    y: canvas - insetTopDown.maxY,
    width: insetTopDown.width,
    height: insetTopDown.height
)

guard let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    // **`noneSkipLast`, not `premultipliedLast`, and this is not cosmetic.**
    //
    // `premultipliedLast` allocates a fourth channel and *always* writes alpha —
    // 255 here, because the icon is fully opaque, and the channel is there anyway.
    // App Store Connect rejects an app icon that has an alpha channel at all, not
    // one whose alpha is 255 everywhere. `AppIconTests` caught this: the first
    // render decoded as `premultipliedLast` and would have been rejected.
    //
    // This is also the failure `sips` produces when an icon is resized, which is
    // how an icon that shipped fine in a build stops being shippable after
    // somebody tidied it.
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write(Data("could not create a bitmap context\n".utf8))
    exit(1)
}

// **Opaque, not transparent.** An app icon with an alpha channel is rejected by
// the App Store, and a semi-transparent one shows whatever is behind it on the
// home screen. Filling first also means the field is exactly `#000000` rather than
// `#00000000`, which is a distinction that only matters right up until it does.
context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

// The rear frame: a stroked outline, so it reads as a frame rather than a panel.
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.setLineWidth(stroke)
let framePath = CGPath(
    roundedRect: frameRect,
    cornerWidth: frameWidth * frameRadiusFraction,
    cornerHeight: frameWidth * frameRadiusFraction,
    transform: nil
)
context.addPath(framePath)
context.strokePath()

// The front inset: filled, because a second outline inside a frame at 60pt reads
// as one shape with a notch rather than as two photographs.
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.addPath(CGPath(
    roundedRect: insetRect,
    cornerWidth: insetSide * insetRadiusFraction,
    cornerHeight: insetSide * insetRadiusFraction,
    transform: nil
))
context.fillPath()

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("could not render the icon\n".utf8))
    exit(1)
}

// MARK: - Writing

let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Scripts
    .deletingLastPathComponent()   // repo root
let destination = repository
    .appendingPathComponent("Memoree/Resources/Assets.xcassets/AppIcon.appiconset")
    .appendingPathComponent("AppIcon-1024.png")

guard let png = NSBitmapImageRep(cgImage: image).representation(
    using: .png,
    properties: [:]
) else {
    FileHandle.standardError.write(Data("could not encode the icon as PNG\n".utf8))
    exit(1)
}

do {
    try png.write(to: destination)
} catch {
    FileHandle.standardError.write(Data("could not write \(destination.path): \(error)\n".utf8))
    exit(1)
}

print("wrote \(destination.path) — \(Int(canvas))×\(Int(canvas)), \(png.count) bytes")
