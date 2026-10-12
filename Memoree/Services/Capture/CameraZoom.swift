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
/// ## Front: 0.5× and 1×, never 2×
///
/// Front 0.5× is a **different physical camera** (`.builtInUltraWideCamera`), not
/// a zoom factor — see `requiresItsOwnDevice`. Front 2× is refused: it would be a
/// digital crop of a selfie. The rear offers all three on one virtual dual-wide.
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
    /// ultra-wide's. Its wide lens sits at the switch-over factor (survey: 2.00).
    /// So button FOV × switch-over is the device factor:
    ///
    /// | Button | Device zoom (switch-over 2) | Which lens |
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
    ///
    /// - Parameter switchOver: First entry of
    ///   `virtualDeviceSwitchOverVideoZoomFactors` when known; defaults to the
    ///   surveyed 2.0 so tests and cold paths stay deterministic.
    func virtualDeviceZoomFactor(switchOver: CGFloat = 2.0) -> CGFloat {
        factor * switchOver
    }

    /// Convenience for the surveyed default switch-over (2.0).
    var virtualDeviceZoomFactor: CGFloat {
        virtualDeviceZoomFactor(switchOver: 2.0)
    }

    /// Zoom to apply on `position` without becoming a liar.
    ///
    /// Front 2× is not offered; a preference remembered from the rear must not
    /// digitally crop the selfie when the input is rebuilt. Preference stays
    /// `.doubleWide` in storage so returning to the rear restores 2×.
    func effective(for position: CameraPosition) -> CameraZoom {
        if position == .front, self == .doubleWide { return .wide }
        return self
    }

    /// Whether moving from `from` to `to` on `position` must stop and re-attach
    /// a different physical lens (front UW ↔ wide only).
    static func requiresSessionReconfigure(
        from: CameraZoom,
        to: CameraZoom,
        on position: CameraPosition
    ) -> Bool {
        guard position == .front else { return false }
        return from.requiresItsOwnDevice(on: position) != to.requiresItsOwnDevice(on: position)
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
    /// ## The front has no telephoto, so 2× is not there
    ///
    /// **The front camera has one lens**, so 2× on it is a digital crop of your
    /// face — the magnification that makes a selfie a close-up of one cheek. iOS
    /// Camera omits it for the same reason. The rear's 2× is real: the virtual
    /// dual-wide device hands off to a genuinely longer lens at that point.
    ///
    /// So the front row is 0.5× and 1×, and the rear row is all three.
    ///
    /// ## And 0.5× *is* available on the front
    ///
    /// **This needs a different physical camera**, not a zoom factor. A device
    /// survey on this hardware found `.builtInUltraWideCamera` at the **front**
    /// position with 56 three-by-four formats, so the reach exists — which the
    /// first version of this assumed it did not, and greyed the button out.
    /// `requiresItsOwnDevice(on:)` is what makes that difference explicit, because
    /// it changes what applying the zoom costs.
    func isAvailable(on position: CameraPosition) -> Bool {
        if position == .front, self == .doubleWide { return false }
        return true
    }

    /// The zooms offered on `position`, in order.
    ///
    /// **The row changes length when the camera changes**, which is a decision
    /// rather than an oversight: the alternative is showing a permanently disabled
    /// 2× on the front, and a control that is never pressable on one camera is
    /// clutter that changes nothing.
    static func offered(on position: CameraPosition) -> [CameraZoom] {
        allCases.filter { $0.isAvailable(on: position) }
    }

    /// Whether this zoom needs a **different physical camera** rather than a
    /// different zoom factor.
    ///
    /// ## Only the front's 0.5× does
    ///
    /// The rear's whole range is one virtual dual-wide device, so every rear zoom
    /// is a `videoZoomFactor` write. **The front has no virtual device** — the
    /// survey found `.builtInDualWideCamera` only at the back — so front 0.5× has
    /// to attach the front's ultra-wide lens, which is `removeInput`/`addInput` on
    /// the session: the stop-reconfigure-start cycle ADR-003 measured.
    ///
    /// ## Why this is worth stating rather than hiding in the controller
    ///
    /// Because the cost differs by a factor of two. A caller that assumes every
    /// zoom is a property write will build the rear's cheap path for the front's
    /// expensive one, and the symptom — a frame output that dies mid-moment — is
    /// the single hardest failure in this app to diagnose.
    func requiresItsOwnDevice(on position: CameraPosition) -> Bool {
        position == .front && self == .ultraWide
    }
}
