import Foundation

extension BridgeCoordinator {
    // Fire a canned rumble sequence on every ready, rumble-capable device. Each
    // device's prior test (if any) is cancelled; its rumble-refresh task is also
    // cancelled so a stale host-side resend can't interleave with the pattern.
    // Routes through the same encodeRumble + sendVibration path as host rumble,
    // so intensity/frequency/mapping all apply to the test as well.
    func playTestRumble(_ pattern: TestRumblePattern, on deviceID: DeviceID? = nil) {
        var targets: [(DeviceID, DeviceRecord, RumbleSettings)] = []
        if let deviceID {
            // Targeting one half of an active pair fires both motors against
            // the shared paired-profile settings so the test matches what the
            // host would feel during gameplay.
            if let pair = joyConPair, pair.includes(deviceID) {
                let shared = pairRumbleSettings()
                if let l = devices[pair.leftID]  { targets.append((pair.leftID,  l, shared)) }
                if let r = devices[pair.rightID] { targets.append((pair.rightID, r, shared)) }
            } else if let record = devices[deviceID] {
                targets.append((deviceID, record, rumbleSettings(for: record)))
            }
        } else {
            for (id, record) in devices where record.connectionState == .ready {
                targets.append((id, record, rumbleSettings(for: record)))
            }
        }
        for (id, record, settings) in targets where record.connectionState == .ready {
            let probeSettings = settings.snapshot()
            guard record.profile.encodeRumble(
                RumbleCommand(leftAmp: 1, rightAmp: 1), sequence: 0, settings: probeSettings
            ) != nil else { continue }
            startTestRumble(pattern, on: id, profile: record.profile, settings: settings)
        }
    }

    func startTestRumble(_ pattern: TestRumblePattern, on id: DeviceID, profile: any ControllerProfile, settings: RumbleSettings) {
        testRumbleTasks[id]?.cancel()
        rumbleRefreshBoxes[id]?.cancel()
        let transport = transport(for: id.transport)
        let refresh = rumbleRefreshBoxes[id]
        // Detached so the heartbeat loop runs on the global executor instead of
        // MainActor. Sharing the actor with the UI lets a heavy sheet re-render
        // delay the next sendVibration; the gameplay rumble path is already
        // off-main via the HID set-report handler.
        testRumbleTasks[id] = Task.detached { [weak self] in
            await self?.runTestRumble(pattern, on: id, profile: profile, transport: transport, refresh: refresh, settings: settings)
        }
    }

    nonisolated func runTestRumble(
        _ pattern: TestRumblePattern,
        on id: DeviceID,
        profile: any ControllerProfile,
        transport: (any Transport)?,
        refresh: RumbleRefreshBox?,
        settings: RumbleSettings
    ) async {
        @Sendable func send(_ cmd: RumbleCommand) async {
            if let payload = profile.encodeRumble(cmd, sequence: refresh?.nextCounter() ?? 0, settings: settings.snapshot()) {
                try? await transport?.sendVibration(payload, to: id)
            }
        }
        // Pump the command at the profile's refresh cadence for the requested duration.
        // A single send decays on the controller (it expects an output report after every
        // input report at ~67 Hz on BLE), so any "hold" needs to keep feeding the same
        // payload until the next value change.
        let heartbeat: Duration = profile.rumbleRefreshInterval ?? .milliseconds(15)
        @Sendable func hold(_ cmd: RumbleCommand, _ ms: Int) async {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(ms))
            while ContinuousClock.now < deadline {
                if Task.isCancelled { return }
                await send(cmd)
                try? await Task.sleep(for: heartbeat)
            }
        }
        let full: UInt16 = 0xFFFF
        let half: UInt16 = 0x8000

        switch pattern {
        case .both:
            await hold(RumbleCommand(leftAmp: full, rightAmp: full), 800)
        case .left:
            await hold(RumbleCommand(leftAmp: full, rightAmp: 0), 800)
        case .right:
            await hold(RumbleCommand(leftAmp: 0, rightAmp: full), 800)
        case .alternate:
            // Gait: brief L/R pulses with silence between, like footsteps.
            for _ in 0..<4 {
                if Task.isCancelled { break }
                await hold(RumbleCommand(leftAmp: half, rightAmp: 0), 120)
                await hold(RumbleCommand(), 120)
                if Task.isCancelled { break }
                await hold(RumbleCommand(leftAmp: 0, rightAmp: half), 120)
                await hold(RumbleCommand(), 120)
            }
        case .ramp:
            let steps = 12
            for i in 1...steps {
                if Task.isCancelled { break }
                let amp = UInt16(Double(full) * Double(i) / Double(steps))
                await hold(RumbleCommand(leftAmp: amp, rightAmp: amp), 90)
            }
            await hold(RumbleCommand(leftAmp: full, rightAmp: full), 250)
        }

        await send(RumbleCommand())
    }
}
