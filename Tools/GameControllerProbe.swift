// Standalone CLI: probe macOS GameController.framework recognition and inputs.
//
// Run (with WaveBird active so the virtual HID is registered):
//   swift Tools/GameControllerProbe.swift
//
// Lists every controller GameController.framework sees, then prints whenever
// any input changes — pressed buttons, stick deflections past a deadzone, and
// nonzero trigger values. Use this to verify the presentation mappings: if a
// face button labeled "A" in the probe doesn't match what you press, the
// presentation output has the wrong bits set.
//
// Quit with Ctrl+C.

import Foundation
import GameController

let stickDeadzone: Float = 0.08
let triggerDeadzone: Float = 0.04

func profileLabel(_ c: GCController) -> String {
    if c.extendedGamepad != nil { return "extendedGamepad" }
    if c.microGamepad != nil    { return "microGamepad" }
    return "(no recognized profile)"
}

// GCMotion has no documented HID-descriptor path, so for any presentation that
// isn't spoofing a controller Apple ships a motion driver for, this is the
// answer to "did the sensor block do anything".
func motionLabel(_ c: GCController) -> String {
    guard let m = c.motion else { return "motion=nil" }
    var caps: [String] = []
    if m.hasRotationRate { caps.append("rotationRate") }
    if m.hasGravityAndUserAcceleration { caps.append("gravity+userAccel") }
    if m.hasAttitude { caps.append("attitude") }
    if caps.isEmpty { caps.append("no capabilities") }
    return "motion=[\(caps.joined(separator: ", "))] sensorsActive=\(m.sensorsActive)"
}

func describe(_ c: GCController) -> String {
    let vendor = c.vendorName ?? "(no vendor)"
    return "\(vendor) — category=\"\(c.productCategory)\" — \(profileLabel(c)) — \(motionLabel(c))"
}

// GCExtendedGamepad is deliberately abstract: it exposes buttonA/B/X/Y and no
// Cross/Circle/Square/Triangle, even on GCDualSenseGamepad. The product-specific
// label is metadata on the element — `localizedName` ("Cross Button", "B
// Button") — so the same physical press reads differently per presentation.
//
// Printing both matters here because WaveBird's presentations remap the
// abstract inputs: in switchPro mode GameController's abstract A sits at the
// Nintendo A position, which is geometrically where Circle/B lives on a
// PlayStation pad. Abstract letters alone can't tell you whether a mapping is
// right; the pair can.
func label(_ b: GCControllerButtonInput?, _ abstract: String) -> String {
    guard let b else { return abstract }
    guard let name = b.localizedName, !name.isEmpty, name != abstract else { return abstract }
    return "\(abstract)(\(name))"
}

// Compact state line: only the parts that are nonzero / pressed.
func snapshot(_ gp: GCExtendedGamepad) -> String {
    var parts: [String] = []

    // Face / system buttons
    if gp.buttonA.isPressed                  { parts.append(label(gp.buttonA, "A")) }
    if gp.buttonB.isPressed                  { parts.append(label(gp.buttonB, "B")) }
    if gp.buttonX.isPressed                  { parts.append(label(gp.buttonX, "X")) }
    if gp.buttonY.isPressed                  { parts.append(label(gp.buttonY, "Y")) }
    if gp.leftShoulder.isPressed             { parts.append(label(gp.leftShoulder, "LB")) }
    if gp.rightShoulder.isPressed            { parts.append(label(gp.rightShoulder, "RB")) }
    if gp.leftThumbstickButton?.isPressed == true  { parts.append(label(gp.leftThumbstickButton, "LS·")) }
    if gp.rightThumbstickButton?.isPressed == true { parts.append(label(gp.rightThumbstickButton, "RS·")) }
    if gp.buttonOptions?.isPressed == true   { parts.append(label(gp.buttonOptions, "Options")) }
    if gp.buttonMenu.isPressed               { parts.append(label(gp.buttonMenu, "Menu")) }
    if gp.buttonHome?.isPressed == true      { parts.append(label(gp.buttonHome, "Home")) }
    // Share/Capture lives on the controller-specific subclasses, not the base
    // GCExtendedGamepad: Xbox exposes buttonShare, DualShock/DualSense buttonTouchpad.
    if let xbox = gp as? GCXboxGamepad, xbox.buttonShare?.isPressed == true {
        parts.append(label(xbox.buttonShare, "Share"))
    }

    // D-pad
    if gp.dpad.up.isPressed    { parts.append("↑") }
    if gp.dpad.down.isPressed  { parts.append("↓") }
    if gp.dpad.left.isPressed  { parts.append("←") }
    if gp.dpad.right.isPressed { parts.append("→") }

    // Triggers (analog)
    let lt = gp.leftTrigger.value
    let rt = gp.rightTrigger.value
    if lt > triggerDeadzone { parts.append(String(format: "LT=%.2f", lt)) }
    if rt > triggerDeadzone { parts.append(String(format: "RT=%.2f", rt)) }

    // Sticks (analog), only when deflected past deadzone
    let ls = gp.leftThumbstick
    let lx = ls.xAxis.value, ly = ls.yAxis.value
    if abs(lx) > stickDeadzone || abs(ly) > stickDeadzone {
        parts.append(String(format: "LS=(%+.2f,%+.2f)", lx, ly))
    }
    let rs = gp.rightThumbstick
    let rx = rs.xAxis.value, ry = rs.yAxis.value
    if abs(rx) > stickDeadzone || abs(ry) > stickDeadzone {
        parts.append(String(format: "RS=(%+.2f,%+.2f)", rx, ry))
    }

    return parts.isEmpty ? "(idle)" : parts.joined(separator: " ")
}

// Track the last printed snapshot per controller so we only emit on change.
final class StateTracker: @unchecked Sendable {
    private var last: [ObjectIdentifier: String] = [:]
    private let q = DispatchQueue(label: "probe.state")

    func emit(_ c: GCController, line: String) {
        q.sync {
            let key = ObjectIdentifier(c)
            if last[key] == line { return }
            last[key] = line
            let label = (c.vendorName ?? "?").padding(toLength: 28, withPad: " ", startingAt: 0)
            FileHandle.standardError.write(Data("[\(label)] \(line)\n".utf8))
        }
    }

    func clear(_ c: GCController) {
        q.sync { _ = last.removeValue(forKey: ObjectIdentifier(c)) }
    }
}

let tracker = StateTracker()

// GCMotion advertising a capability is not the same as motion data flowing.
// Sensors on the PlayStation/Switch profiles need explicit activation, so turn
// them on and sample — a live rotationRate is the only proof motion works.
func installMotion(on c: GCController) {
    guard let m = c.motion else { return }
    let label = (c.vendorName ?? "?").padding(toLength: 28, withPad: " ", startingAt: 0)
    if m.sensorsRequireManualActivation {
        m.sensorsActive = true
        FileHandle.standardError.write(Data("[\(label)] motion: sensors activated (active=\(m.sensorsActive))\n".utf8))
    }
    // Poll rather than rely on valueChangedHandler: if the handler never fires
    // we still learn whether the underlying values are moving, which separates
    // "GameController isn't delivering motion callbacks" from "the driver isn't
    // parsing our IMU bytes at all" (values pinned at zero).
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        let r = m.rotationRate
        let a = m.acceleration
        let g = m.gravity
        FileHandle.standardError.write(Data(String(
            format: "[\(label)] poll rot(%+.3f %+.3f %+.3f) accel(%+.3f %+.3f %+.3f) grav(%+.3f %+.3f %+.3f) active=%@\n",
            r.x, r.y, r.z, a.x, a.y, a.z, g.x, g.y, g.z,
            m.sensorsActive ? "Y" : "N").utf8))
    }
}

func install(on c: GCController) {
    installMotion(on: c)
    guard let gp = c.extendedGamepad else {
        FileHandle.standardError.write(Data("[?] \(c.vendorName ?? "?") has no extendedGamepad profile — skipping input handler\n".utf8))
        return
    }
    gp.valueChangedHandler = { gp, _ in
        tracker.emit(c, line: snapshot(gp))
    }

    // Home/Share don't fire the gamepad valueChangedHandler (Home is a system
    // button routed separately; Share isn't in the GCExtendedGamepad profile at
    // all). Attach dedicated element handlers so a lone press still registers.
    let label = (c.vendorName ?? "?").padding(toLength: 28, withPad: " ", startingAt: 0)
    func logButton(_ name: String, _ pressed: Bool) {
        FileHandle.standardError.write(Data("[\(label)] \(name) \(pressed ? "DOWN" : "up")\n".utf8))
    }
    gp.buttonHome?.pressedChangedHandler = { _, _, pressed in logButton("Home", pressed) }
    if let xbox = gp as? GCXboxGamepad {
        xbox.buttonShare?.pressedChangedHandler = { _, _, pressed in logButton("Share", pressed) }
    }
    // Catch-all: the physical input profile carries every element, including
    // system buttons the extendedGamepad profile omits. If even this stays
    // silent on Home/Share, macOS isn't delivering them to the app at all.
    //
    // Filtered to elements extendedGamepad does NOT cover — snapshot() already
    // prints those with their localizedName, so an unfiltered catch-all doubles
    // every press. What survives is the interesting part: system buttons, and
    // inputs the two layers model differently (ZL/ZR are analog triggers to
    // extendedGamepad but named buttons here). Matched by identity and by name,
    // since the two profiles need not vend the same element instances.
    let coveredIDs = Set(gp.allButtons.map(ObjectIdentifier.init))
    let coveredNames = Set(gp.allButtons.compactMap(\.localizedName))
    c.physicalInputProfile.valueDidChangeHandler = { _, element in
        guard let button = element as? GCControllerButtonInput, button.isPressed,
              !coveredIDs.contains(ObjectIdentifier(button)),
              let name = element.localizedName ?? element.sfSymbolsName,
              !coveredNames.contains(name) else { return }
        FileHandle.standardError.write(Data("[\(label)] profile-only: \(name)\n".utf8))
    }

    // Print an idle baseline so the user knows the handler is wired.
    tracker.emit(c, line: snapshot(gp))
}

// Unbuffered: this tool is usually run with stdout redirected to a file, and
// Swift block-buffers to a pipe — which reads as "the probe printed nothing".
setvbuf(stdout, nil, _IONBF, 0)

print("== GameController.framework probe ==")
let initial = GCController.controllers()
print("Initial controllers: \(initial.count)")
for c in initial {
    print("  - \(describe(c))")
    install(on: c)
}

NotificationCenter.default.addObserver(
    forName: .GCControllerDidConnect, object: nil, queue: .main
) { note in
    guard let c = note.object as? GCController else { return }
    FileHandle.standardError.write(Data("[connect]    \(describe(c))\n".utf8))
    install(on: c)
}

NotificationCenter.default.addObserver(
    forName: .GCControllerDidDisconnect, object: nil, queue: .main
) { note in
    guard let c = note.object as? GCController else { return }
    FileHandle.standardError.write(Data("[disconnect] \(describe(c))\n".utf8))
    tracker.clear(c)
}

if #available(macOS 11, *) {
    GCController.shouldMonitorBackgroundEvents = true
}

print("Listening for input. Press buttons / move sticks. Ctrl+C to exit.")
RunLoop.main.run()
