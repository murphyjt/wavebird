// Standalone CLI: trigger rumble via GameController.framework CoreHaptics API.
//
// Run (with WaveBird active so the virtual HID is registered):
//   swift Tools/RumbleTest.swift [locality]
//
// locality = default | all | handles | leftHandle | rightHandle | leftTrigger | rightTrigger
// Defaults to "handles" if omitted.
//
// Fires a 1-second continuous haptic, then stops. Watch WaveBird's Xcode console
// to see what output reports arrive — that shows you what format GCController
// sends for each presentation mode. Ctrl+C to exit.

import Foundation
import GameController
import CoreHaptics

@available(macOS 11, *)
func localityArg() -> GCHapticsLocality {
    let arg = CommandLine.arguments.dropFirst().first ?? "handles"
    switch arg {
    case "default":      return .default
    case "all":          return .all
    case "handles":      return .handles
    case "leftHandle":   return .leftHandle
    case "rightHandle":  return .rightHandle
    case "leftTrigger":  return .leftTrigger
    case "rightTrigger": return .rightTrigger
    default:
        print("Unknown locality '\(arg)'. Valid: default all handles leftHandle rightHandle leftTrigger rightTrigger")
        exit(1)
    }
}

@available(macOS 11, *)
func fireHaptic(on controller: GCController, locality: GCHapticsLocality) {
    print("Controller: \(controller.vendorName ?? "?") — \(controller.productCategory)")
    guard let haptics = controller.haptics else {
        print("No GCDeviceHaptics on this controller (unsupported presentation mode or not a haptics-capable device).")
        exit(1)
    }

    print("Supported localities: \(haptics.supportedLocalities)")

    guard let engine = haptics.createEngine(withLocality: locality) else {
        print("createEngine(locality: \(locality)) returned nil (locality not supported?).")
        exit(1)
    }

    do {
        try engine.start()

        let intensity  = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
        let sharpness  = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
        let event      = CHHapticEvent(eventType: .hapticContinuous,
                                       parameters: [intensity, sharpness],
                                       relativeTime: 0, duration: 1.0)
        let pattern    = try CHHapticPattern(events: [event], parameters: [])
        let player     = try engine.makePlayer(with: pattern)

        print("Firing haptic (locality: \(locality)) for 1 second — watch WaveBird logs…")
        try player.start(atTime: CHHapticTimeImmediate)
        Thread.sleep(forTimeInterval: 1.5)
        engine.stop()
        print("Done.")
        exit(0)
    } catch {
        print("Haptic playback error: \(error)")
        exit(1)
    }
}

guard #available(macOS 11, *) else {
    print("Requires macOS 11+")
    exit(1)
}

let locality = localityArg()

// Try already-connected controllers first, then wait briefly for a connect event.
func tryFire() {
    let controllers = GCController.controllers()
    if controllers.isEmpty {
        print("No controllers found yet, waiting…")
        return
    }
    // Prefer a non-Remote controller if multiple are connected.
    let c = controllers.first(where: { $0.extendedGamepad != nil }) ?? controllers[0]
    fireHaptic(on: c, locality: locality)
}

NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
    guard let c = note.object as? GCController else { return }
    print("Connected: \(c.vendorName ?? "?")")
    fireHaptic(on: c, locality: locality)
}

GCController.shouldMonitorBackgroundEvents = true
tryFire()

print("Waiting for a controller connection… (Ctrl+C to quit)")
RunLoop.main.run()
