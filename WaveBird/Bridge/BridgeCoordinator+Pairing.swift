import Foundation

extension BridgeCoordinator {
    // LTK pairing entrypoints. We always need the host BT address (the value
    // the controller compares to its flash entries when deciding whether to
    // auto-reconnect), so if IOBluetooth can't give it to us we silently skip.
    //
    // The (local × on-device) matrix:
    //   yes/yes → already paired, no prompt
    //   yes/no  → .repair (something else overwrote our slot)
    //   no/yes  → silently upgrade the local record to isPaired=true, no prompt
    //   no/no   → .pair (fresh exchange)
    // When the flash read failed (onDeviceHostAddresses still nil at .ready),
    // we fall back to local-only logic.
    func maybePromptForPairing(record: DeviceRecord) {
        guard pairingPrompt == nil,
              record.id.transport == .ble,
              let serial = record.serial,
              !declinedPairingThisSession.contains(serial),
              knownControllers[serial]?.suppressPairingPrompt != true,
              let host = HostAdapter.address()
        else { return }

        let localPaired = knownControllers[serial]?.isPaired == true
        let onDevicePaired: Bool? = record.onDeviceHostAddresses.map { $0.contains(host) }

        // Silently adopt: controller already has this host stored, but our
        // local record says otherwise. No LTK exchange needed.
        if !localPaired, onDevicePaired == true {
            if var entry = knownControllers[serial] {
                entry.isPaired = true
                knownControllers[serial] = entry
                persistKnownControllers()
            }
            return
        }

        let intent: PairingPrompt.Intent?
        switch (localPaired, onDevicePaired) {
        case (true,  true?):  intent = nil      // already paired
        case (true,  false?): intent = .repair  // controller forgot us
        case (false, false?): intent = .pair    // fresh
        case (true,  nil):    intent = nil      // flash unknown, trust local
        case (false, nil):    intent = .pair    // flash unknown, assume fresh
        case (false, true?):  intent = nil      // handled above
        }

        guard let intent else { return }
        pairingPrompt = PairingPrompt(
            deviceID: record.id,
            controllerName: record.profile.name,
            serial: serial,
            productID: record.advertisement.productID,
            hostAddress: host,
            intent: intent,
            status: .idle
        )
    }

    func acceptPairing() async {
        guard let prompt = pairingPrompt else { return }
        guard let transport = transport(for: prompt.deviceID.transport) else {
            pairingPrompt?.status = .failed("transport unavailable")
            return
        }
        pairingPrompt?.status = .inProgress
        do {
            _ = try await NS2Pairing.run(
                deviceID: prompt.deviceID,
                transport: transport,
                hostAddress: prompt.hostAddress
            )
            if let record = devices[prompt.deviceID] { recordController(for: record, isPaired: true) }
            pairingPrompt = nil
            reconsiderPairingPrompts()
        } catch {
            pairingPrompt?.status = .failed(String(describing: error))
        }
    }

    func declinePairing() {
        if let serial = pairingPrompt?.serial {
            declinedPairingThisSession.insert(serial)
        }
        pairingPrompt = nil
        reconsiderPairingPrompts()
    }

    // "Don't Ask Again": persist a per-serial suppression so the prompt never
    // reappears for this controller on any future launch. Records a profile-only
    // KnownController first if one doesn't exist yet, so the flag has somewhere
    // to live. Reversed by forgetting the controller (which drops the record).
    func declinePairingPermanently() {
        guard let prompt = pairingPrompt else { return }
        let serial = prompt.serial
        if knownControllers[serial] == nil, let record = devices[prompt.deviceID] {
            recordController(for: record, isPaired: false)
        }
        knownControllers[serial]?.suppressPairingPrompt = true
        persistKnownControllers()
        declinedPairingThisSession.insert(serial)
        pairingPrompt = nil
        reconsiderPairingPrompts()
    }

    // Called when the 30 s sheet timer fires without an answer. Dismisses
    // without recording a decline so the controller's next .ready can
    // re-prompt. The VHID was already built at .ready time (profile-first
    // ordering), so nothing else needs to happen here.
    func timeoutPairingPrompt() {
        pairingPrompt = nil
        reconsiderPairingPrompts()
    }

    // After a prompt resolves, scan .ready devices and re-attempt the pairing
    // prompt for any that haven't been prompted yet. Without this, two
    // Joy-Cons reaching .ready close together drop the second one's LTK
    // prompt because maybePromptForPairing guards on pairingPrompt == nil.
    // Idempotent: a controller already paired or in declinedPairingThisSession
    // simply returns from maybePromptForPairing without raising a prompt.
    func reconsiderPairingPrompts() {
        for record in devices.values where record.connectionState == .ready {
            maybePromptForPairing(record: record)
            if pairingPrompt != nil { return }
        }
    }
}
