import Foundation
import IOKit.hid

// Why virtual-controller output is blocked. Only ever produced from an
// observed HIDVirtualDevice init failure — the TCC post-event check alone is
// not predictive (verified on hardware 2026-07-05: it reports not-granted on
// a machine where the Accessibility box is ticked and the VHID works), so it
// is consulted only to pick the more specific message after a failure.
enum HIDAccessIssue: Equatable {
    case permissionDenied
    case vhidCreationFailed

    // Called at the moment a VHID creation fails.
    static func current() -> HIDAccessIssue {
        IOHIDCheckAccess(kIOHIDRequestTypePostEvent) == kIOHIDAccessTypeGranted
            ? .vhidCreationFailed
            : .permissionDenied
    }

    var message: String {
        switch self {
        // "Reconnect" not "press a button": only LTK-paired controllers wake
        // on a button press; a first-time controller needs SYNC again, and
        // the empty-state copy already teaches that.
        case .permissionDenied:
            "WaveBird needs the Accessibility permission to create virtual game controllers. Enable WaveBird in System Settings, then reconnect the controller."
        case .vhidCreationFailed:
            "Couldn't create the virtual game controller. Check that WaveBird is enabled under Privacy & Security → Accessibility, then reconnect the controller."
        }
    }
}
