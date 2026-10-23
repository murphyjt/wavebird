#if NYXI_DIAGNOSTICS
import SwiftUI

// Separate, opt-in diagnostic app: uses the production BLE transport, decoder
// and pair merge without creating a HID device or requiring its managed
// entitlement. The regular WaveBird build never includes this entry point.
@main
struct NYXIDiagnosticsApp: App {
    @State private var monitor = NYXIMonitor()

    var body: some Scene {
        Window("WaveBird — NYXI BLE Diagnostics", id: "diagnostics") {
            VStack(alignment: .leading, spacing: 14) {
                Text("NYXI Hyperion 3 — experimental").font(.title2)
                Text("BLE input monitor. Hold SYNC on each half. This build does not create a system gamepad.")
                Text(monitor.status)
                Divider()
                Text("L: \(monitor.leftStatus)")
                Text("R: \(monitor.rightStatus)")
                Text("Buttons: \(monitor.buttons)")
                Text("Left stick: \(monitor.leftStick)")
                Text("Right stick: \(monitor.rightStick)")
                Text("Reports: \(monitor.reports)").monospacedDigit()
                Text("Keep both halves connected for at least 60 seconds, then press buttons and move both sticks.")
                    .foregroundStyle(.secondary)
            }
            .fontDesign(.monospaced)
            .padding(24)
            .frame(width: 700)
            .task { await monitor.start() }
        }
        .windowResizability(.contentSize)
    }
}

@MainActor @Observable
final class NYXIMonitor {
    var status = "Starting Bluetooth…"
    var leftStatus = "waiting"
    var rightStatus = "waiting"
    var buttons = "none"
    var leftStick = "0, 0"
    var rightStick = "0, 0"
    var reports = 0
    private let transport = BLETransport()
    private var sides: [DeviceID: Bool] = [:]
    private var states: [DeviceID: ControllerState] = [:]
    private var lastSignature: InputSignature?
    private var lastLog = ContinuousClock.now
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        stderrLog("[nyxi] diagnostic monitor started; no virtual HID; hold SYNC on L and R")
        let profiles = [JoyConProfile(side: .left), JoyConProfile(side: .right)]
        await transport.startDiscovery(matchers: profiles.compactMap { $0.bleMatcher.map(TransportMatcher.ble) })
        for await event in transport.events {
            switch event {
            case .availability(let reason): status = reason ?? "Scanning — hold SYNC on L and R"
            case .discovered(let id, let info):
                guard sides[id] == nil else { continue }
                sides[id] = info.productID == 0x2067
                setStatus(id, "connecting")
                try? await transport.connect(id)
            case .connected(let id): setStatus(id, "initializing")
            case .consoleMode(let id, let enabled): setStatus(id, enabled ? "console initialization" : "Nintendo common channel")
            case .ready(let id): setStatus(id, "ready")
            case .disconnected(let id, let reason):
                setStatus(id, "disconnected: \(reason); hold SYNC again")
                states[id] = nil
                sides[id] = nil
                updateMerged()
            case .reportReceived(let id, let reportID, let data):
                guard reportID == nil, let left = sides[id],
                      let state = JoyConProfile(side: left ? .left : .right)
                    .parseBLEReport(data, calibration: ControllerCalibration()) else { continue }
                states[id] = state
                reports += 1
                updateMerged()
            case .error(_, let message): status = message
            default: break
            }
        }
    }

    private func setStatus(_ id: DeviceID, _ text: String) {
        if sides[id] == true { leftStatus = text } else { rightStatus = text }
    }

    private func updateMerged() {
        let left = states.first { sides[$0.key] == true }?.value
        let right = states.first { sides[$0.key] == false }?.value
        let merged = JoyConPairProfile.merge(left: left, right: right)
        let table: [(ButtonSet, String)] = [
            (.a,"A"), (.b,"B"), (.x,"X"), (.y,"Y"), (.l,"L"), (.r,"R"), (.zl,"ZL"), (.zr,"ZR"),
            (.minus,"−"), (.plus,"+"), (.stickL,"LS"), (.stickR,"RS"), (.dpadUp,"Up"),
            (.dpadDown,"Down"), (.dpadLeft,"Left"), (.dpadRight,"Right"), (.home,"Home"),
            (.capture,"Capture"), (.c,"C"), (.sl,"SL"), (.sr,"SR"),
        ]
        let names = table.filter { merged.buttons.contains($0.0) }.map(\.1)
        buttons = names.isEmpty ? "none" : names.joined(separator: " ")
        leftStick = "\(merged.leftStick.x), \(merged.leftStick.y)"
        rightStick = "\(merged.rightStick.x), \(merged.rightStick.y)"
        let signature = merged.idleSignature
        if lastSignature?.buttons != signature.buttons ||
            (lastSignature != signature && lastLog.duration(to: .now) > .milliseconds(100)) {
            stderrLog("[nyxi] merged buttons=\(buttons) L=(\(leftStick)) R=(\(rightStick)) reports=\(reports)")
            lastLog = .now
        }
        lastSignature = signature
    }
}
#endif
