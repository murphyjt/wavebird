import Foundation

extension BridgeCoordinator {
    static let idleDisconnectKey = "WaveBird.idleDisconnectMinutes"
    static let idleDisconnectDefaultMinutes = 10

    // System is going to sleep. Clean-disconnect every link and stop scanning so
    // we don't burn radio right up to the transition. This fires only on a real
    // sleep — closed-lid clamshell with an external display keeps the Mac awake,
    // so willSleep never posts and connected controllers stay put. Best-effort:
    // we don't block sleep; the OS tears BLE down regardless and we re-scan on wake.
    func prepareForSleep() async {
        await stopScanning()
        for id in Array(devices.keys) { await disconnectController(id) }
    }

    // Woke up. Resume scanning so paired controllers reconnect on the next
    // button press. (Scanning is always on while the app runs — there's no UI
    // to disable it — so this is unconditional.)
    func resumeAfterWake() async {
        await startScanning()
    }

    // Drops a controller after the configured minutes of no input change. Leaves
    // scanning untouched: the link goes away (the controller is free to sleep)
    // but the still-running scanner reconnects it on the next button press.
    func runIdleSweep() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            let minutes = (UserDefaults.standard.object(forKey: Self.idleDisconnectKey) as? Int)
                ?? Self.idleDisconnectDefaultMinutes
            guard minutes > 0 else { continue }            // 0 == Off
            let deadline = Duration.seconds(minutes * 60)
            let now = ContinuousClock.now
            for (id, rec) in devices where rec.connectionState == .ready {
                guard let last = activityTracker.lastActivity(for: id) else { continue }
                if now - last >= deadline { await disconnectController(id) }
            }
        }
    }
}
