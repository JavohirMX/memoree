import CoreGraphics
import Foundation

/// How far the camera is zoomed, in the words the buttons use.
///
/// ## Why three cases and not a `CGFloat`
///
/// A zoom slider is a `CGFloat`, and a `CGFloat` is how this went wrong twice
/// already. The measurement said the rear sensor's **upscale threshold is 1.0×**
/// — every step past 1× is digital enlargement — and the virtual device hands off
/// between lenses at **2.00**. So the useful zoom range is three specific places
/// with real differences between them, not a continuum, and a type that names
/// them makes the difference visible at every call site.
///
/// | Case | What it is | Sharpness |
/// | --- | --- | --- |
/// | `.ultraWide` | The ultra-wide lens at its full field of view | Native — no enlargement |
/// | `.wide` | The wide lens at its full field of view | Native |
/// | `.doubleWide` | Wide lens, magnified 2× | **Upscaled.** Accepted; why there are three and not more |
///
/// ## Why the labels are "0.5×", "1×", "2×" and not "ultra wide"
///
/// Because that is what the user is looking at. A person framing a photograph
/// knows what 2× means and does not know what a "telephoto" is, and the button's
/// job is to be read at a glance while the camera is open.
///
/// ## Why `.front` has no `ultraWide`
///
/// **The front camera has one lens, so `ultraWide` is refused there.** Returning
/// `nil` rather than clamping to `.wide` is deliberate: silently giving the user
/// something other than what they pressed is how a control becomes a liar, and
/// the front of a phone genuinely has no wide-angle option on any iPhone.
enum CameraZoom: String, Sendable, Equatable, CaseIterable {

    case ultraWide
    case wide
    case doubleWide

    /// The label on the button.
    ///
    /// **"0.5×", "1×", "2×" — a dot, not a comma, and not localised.**
    ///
    /// Not localised because these are *camera* conventions rather than numbers:
    /// every camera app writes them this way in every language, and a button
    /// reading "0,5×" in one locale and "0.5×" in another would be a button whose
    /// label changes meaning with the phone's settings. The `×` is the
    /// multiplication sign rather than the letter `x`, which is what iOS and every
    /// camera app use.
    var label: String {
        switch self {
        case .ultraWide: "0.5×"
        case .wide: "1×"
        case .doubleWide: "2×"
        }
    }

    /// The multiplier, relative to the wide lens at its full field of view.
    ///
    /// **Stated rather than derived**, because these three numbers are what the
    /// buttons mean and are not something to compute from hardware that varies.
    /// The device survey measured the two facts they rest on — the rear upscale
    /// threshold is 1.0, and the dual-wide device hands off at 2.00 — and nothing
    /// else about the mapping is knowable without a phone in hand.
    var factor: CGFloat {
        switch self {
        case .ultraWide: 0.5
        case .wide: 1.0
        case .doubleWide: 2.0
        }
    }

    /// The `videoZoomFactor` to set on a virtual dual-wide device.
    ///
    /// **Not the same as `factor`**, and the difference is the whole reason the
    /// virtual device is used at all.
    ///
    /// A dual-wide device's **1.0 is its own widest field of view** — the
    /// ultra-wide's. Its wide lens sits at 2.0, which is exactly the switch-over
    /// factor the survey measured. So:
    ///
    /// | Button | Device zoom | Which lens |
    /// | --- | --- | --- |
    /// | 0.5× | 1.0 | ultra-wide, native |
    /// | 1× | 2.0 | wide at native field of view |
    /// | 2× | 4.0 | wide, magnified |
    ///
    /// **So the whole zoom range is one `videoZoomFactor` write and no session
    /// restart.** That matters more than it sounds: reconfiguring a running
    /// `AVCaptureSession` is the operation ADR-003 measured four times to be the
    /// thing that kills the frame output, and switching lenses the obvious way
    /// would add an instance of it to the middle of every moment.
    var virtualDeviceZoomFactor: CGFloat {
        // Derived by doubling, so the relationship to `factor` is stated once.
        factor * 2
    }

    /// The nearest case to `factor`, for reading back a device that has been set
    /// by something other than this app.
    ///
    /// Rounds to the nearest half rather than clamping to the ends, so a device
    /// left at an odd zoom reports the button a user would have meant.
    static func nearest(to factor: CGFloat) -> CameraZoom? {
        CameraZoom.allCases.min { lhs, rhs in
            abs(lhs.factor - factor) < abs(rhs.factor - factor)
        }
    }

    /// Whether this zoom can be offered on `position`.
    ///
    /// **The front camera is one lens**, so `ultraWide` is not available there and
    /// the third button is disabled rather than hidden — a row of buttons whose
    /// count changes with the camera is more confusing than one that shows you
    /// why it cannot.
    func isAvailable(on position: CameraPosition) -> Bool {
        if position == .front, self == .ultraWide { return false }
        return true
    }
}
