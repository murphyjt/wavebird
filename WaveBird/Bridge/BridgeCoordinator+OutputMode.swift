import CoreHID
import Foundation

extension BridgeCoordinator {
    // Called by ProfilePickerSheet when the user confirms their choice.
    // `profileID` may be a well-known default ID, a custom profile ID, or (for
    // legacy callers) a bare output-mode ID — resolveMappingProfile handles all.
    func activateWithProfile(_ profileID: String, for id: DeviceID) async {
        guard let record = devices[id], record.awaitingProfileSelection else { return }
        let profile = resolveMappingProfile(id: profileID)
        devices[id]?.awaitingProfileSelection = false
        devices[id]?.outputModeID = profile.baseModeID
        devices[id]?.mappingProfileID = profile.id

        if let pair = joyConPair, pair.includes(id) {
            await activateJoyConPair(profileID: profile.id)
            advanceAwaitingProfileSelection()
            return
        }

        if let serial = record.serial {
            if knownControllers[serial] != nil {
                await setPreferredProfile(profile.id, forSerial: serial)
            } else {
                pendingProfileIDs[serial] = profile.id
                let onDevicePaired = HostAdapter.address().flatMap { record.onDeviceHostAddresses?.contains($0) } ?? false
                recordController(for: record, isPaired: onDevicePaired)
            }
        }
        seedMappingSpec(for: id, profile: profile)
        guard let r = devices[id] else { return }
        if let (vhid, session) = makeVirtualHID(for: r, modeID: profile.baseModeID) {
            await vhid.activate()
            devices[id]?.virtualHID = vhid
            devices[id]?.session = session
            devices[id]?.activeOutputModeID = profile.baseModeID
            startDispatch(for: id)
            await applySecondaryInputs(for: id, modeID: profile.baseModeID)
        } else {
            await failVirtualHID(for: id)
            advanceAwaitingProfileSelection()
            return
        }
        if let updated = devices[id] {
            maybePromptForPairing(record: updated)
        }
        advanceAwaitingProfileSelection()
    }

    func dismissProfilePicker() async {
        guard let id = awaitingProfileSelectionID else { return }
        await activateWithProfile(MappingProfile.defaultProfileID(forModeID: defaultOutputModeID), for: id)
    }

    // Persist the per-serial profile selection (normalized to a real profile
    // ID) and apply it live if the controller is connected. The legacy
    // preferredOutputModeID is left untouched for downgrade safety.
    func setPreferredProfile(_ profileID: String, forSerial serial: String) async {
        let profile = resolveMappingProfile(id: profileID)
        guard var paired = knownControllers[serial] else { return }
        if paired.preferredProfileID != profile.id {
            paired.preferredProfileID = profile.id
            knownControllers[serial] = paired
            persistKnownControllers()
        }
        if let liveID = devices.first(where: { $0.value.serial == serial })?.key {
            await applyProfile(profile.id, for: liveID)
        }
    }

    // Apply a profile to a live connection. Same base = spec-box swap only
    // (no republish, applies mid-session); different base = the existing
    // republish path with the new VHID identity.
    func applyProfile(_ profileID: String, for id: DeviceID) async {
        let profile = resolveMappingProfile(id: profileID)
        if let pair = joyConPair, pair.includes(id) {
            await activateJoyConPair(profileID: profile.id)
            return
        }
        devices[id]?.mappingProfileID = profile.id
        seedMappingSpec(for: id, profile: profile)
        guard devices[id]?.outputModeID != profile.baseModeID else { return }
        devices[id]?.outputModeID = profile.baseModeID
        UserDefaults.standard.set(profile.baseModeID, forKey: BridgeCoordinator.outputModeDefaultsKey)
        guard devices[id]?.virtualHID != nil else { return }
        await republishVirtualHID(for: id, modeID: profile.baseModeID)
    }

    // Transitional shims so ControllerDetailSheet still compiles until Task 8
    // rewires it. Bare mode IDs resolve to that mode's default profile.
    func setPreferredOutputMode(_ modeID: String, forSerial serial: String) async {
        await setPreferredProfile(modeID, forSerial: serial)
    }

    func setOutputMode(_ modeID: String, for id: DeviceID) async {
        await applyProfile(modeID, for: id)
    }

    // Insert or replace a KnownController entry. isPaired: true after a
    // successful LTK exchange or when the controller's flash already had this
    // host's entry; false for profile-only records.
    func recordController(for record: DeviceRecord, isPaired: Bool) {
        guard let serial = record.serial else { return }
        knownControllers[serial] = KnownController(
            serial: serial,
            productID: record.advertisement.productID,
            displayName: record.profile.name,
            lastSeenAt: Date(),
            peripheralUUID: record.id.raw,
            preferredOutputModeID: knownControllers[serial]?.preferredOutputModeID,
            preferredProfileID: knownControllers[serial]?.preferredProfileID ?? pendingProfileIDs[serial],
            isPaired: isPaired
        )
        persistKnownControllers()
    }

    // Refresh lastSeenAt + peripheralUUID for an existing known controller,
    // preserving its isPaired flag. Called on every .ready of a recognized serial.
    func refreshKnownController(for record: DeviceRecord) {
        guard let serial = record.serial, var entry = knownControllers[serial] else { return }
        entry.lastSeenAt = Date()
        entry.peripheralUUID = record.id.raw
        knownControllers[serial] = entry
        persistKnownControllers()
    }

    func disconnectController(_ id: DeviceID) async {
        // Pair rows act as one device — disconnecting from L's row drops both
        // sides so the merged VHID goes away cleanly.
        if let pair = joyConPair, pair.includes(id) {
            if let t = transport(for: pair.leftID.transport) { await t.disconnect(pair.leftID) }
            if let t = transport(for: pair.rightID.transport) { await t.disconnect(pair.rightID) }
            return
        }
        guard let transport = transport(for: id.transport) else { return }
        await transport.disconnect(id)
    }

    func output(for record: DeviceRecord, modeID: String) -> any HIDOutputProfile {
        catalog.resolved(id: modeID).makeProfile(record.profile)
    }

    // Tell the transport which optional secondary input channels the resolved
    // output mode needs (e.g. ns2Passthrough wants Pro's Report 0x09). Called
    // whenever a mode activates or changes; for modes that need none (every
    // shipping presentation), this unsubscribes any previously-enabled channel.
    func applySecondaryInputs(for id: DeviceID, modeID: String) async {
        guard let record = devices[id] else { return }
        let out = output(for: record, modeID: modeID)
        await transport(for: id.transport)?.setSecondaryInputs(out.requiredSecondaryReportIDs, for: id)
    }

    func makeVirtualHID(for record: DeviceRecord, modeID: String) -> (VirtualHIDDevice, any HIDOutputSession)? {
        let out = output(for: record, modeID: modeID)
        let session = out.makeSession()
        let rumbleBox = RumbleRefreshBox()
        rumbleRefreshBoxes[record.id] = rumbleBox
        let settings = rumbleSettings(for: record)
        let onSetReport = makeSetReportHandler(id: record.id, transport: transport(for: record.id.transport), profile: record.profile, rumbleRefresh: rumbleBox, session: session, settings: settings)
        guard let vhid = VirtualHIDDevice(
            descriptor: out.descriptor,
            vendorID: out.vendorID,
            productID: out.productID,
            productName: out.productName,
            manufacturer: out.manufacturer,
            versionNumber: out.versionNumber,
            serialNumber: record.serial,
            transport: hidTransport(for: record),
            onSetReport: onSetReport
        ) else { return nil }
        hidAccessIssue = nil
        vhidFailureCooldowns[record.id] = nil
        return (vhid, session)
    }

    // Shared failure path for every VHID creation site. A failed VHID leaves
    // the BLE link up but useless, and creation is only retried on the next
    // .ready — so drop the link: after fixing the permission, a button press
    // reconnects and retries. Also records the issue for the banner (set
    // here, not in makeVirtualHID, so the pair path is covered too).
    func failVirtualHID(for id: DeviceID) async {
        hidAccessIssue = HIDAccessIssue.current()
        devices[id]?.connectionState = .failed("Failed to create virtual HID device")
        let until = ContinuousClock.now.advanced(by: .seconds(60))
        vhidFailureCooldowns[id] = until
        // Self-expire: accessory mode never posts didBecomeActive, so the
        // activation-driven clear can't be the only retry trigger. Skipped
        // if a wholesale clear or a newer failure superseded this deadline.
        Task { @MainActor [weak self] in
            try? await Task.sleep(until: until, clock: .continuous)
            guard let self, self.vhidFailureCooldowns[id] == until else { return }
            self.vhidFailureCooldowns[id] = nil
            await self.rescanAfterVHIDFailureCooldown()
        }
        await transport(for: id.transport)?.disconnect(id)
    }

    // Lifting a cooldown must not wait for a fresh advertisement: with
    // duplicate filtering on, CoreBluetooth coalesces discoveries per scan
    // session, so the .discovered swallowed during the cooldown may have been
    // the only one this session. Restarting discovery opens a new session — a
    // still-advertising controller re-fires .discovered immediately, a
    // sleeping one on its next button press — and the normal
    // discovered → connect path (with its calibrated timeout) does the rest.
    func rescanAfterVHIDFailureCooldown() async {
        guard isScanning else { return }
        let matchers = allScanMatchers()
        for t in transports {
            await t.stopDiscovery()
            await t.startDiscovery(matchers: matchers)
        }
    }

    // Always-on diagnostic log for output reports the host sends us.
    // Routes rumble through session.parseRumble → profile.encodeRumble →
    // transport.sendVibration, and forwards everything to session.handleSetReport
    // for handshake/subcommand replies.
    func makeSetReportHandler(
        id deviceID: DeviceID,
        transport: (any Transport)?,
        profile: any ControllerProfile,
        rumbleRefresh: RumbleRefreshBox,
        session: any HIDOutputSession,
        settings: RumbleSettings
    ) -> VirtualHIDDevice.SetReportHandler {
        return { device, type, id, data in
            let idStr = id.map { String(format: "0x%02X", $0.rawValue) } ?? "-"
            let hex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            stderrLog("[hid] setReport type=\(type) id=\(idStr) len=\(data.count) [\(hex)]")

            // Passthrough modes can hand us a pre-formed BLE vibration payload.
            // When non-nil, send it verbatim and skip parseRumble → encodeRumble:
            // the host is already speaking the controller's native rumble format,
            // and we'd lose per-band freq/amp fidelity if we normalized through
            // RumbleCommand. We also cancel any in-flight refresh task — the host
            // drives cadence itself in passthrough.
            if let payload = session.rawVibrationPayload(type: type, id: id, data: data) {
                rumbleRefresh.cancel()
                try? await transport?.sendVibration(payload, to: deviceID)
                await session.handleSetReport(device: device, type: type, id: id, data: data)
                return
            }

            if let cmd = session.parseRumble(type: type, id: id, data: data) {
                rumbleRefresh.cancel()
                // Pump a fresh counter on every outgoing command. GC/Pro dedupe
                // byte-identical successive payloads, so the tid nibble must vary
                // even when amplitude doesn't — including when the host drives the
                // cadence itself (DS4/DualSense send ~30 Hz at constant amplitude).
                if let payload = profile.encodeRumble(cmd, sequence: rumbleRefresh.nextCounter(), settings: settings.snapshot()) {
                    try? await transport?.sendVibration(payload, to: deviceID)
                }
                // Whichever side wants more frequent updates wins. Pro 2 sets
                // a 15 ms controller-side requirement to match the Switch console;
                // Xbox presentation sets 80 ms session-side; nil on either means defer.
                let interval = BridgeCoordinator.mergeRefresh(profile.rumbleRefreshInterval, session.refreshInterval)
                if let interval, !cmd.isStop {
                    rumbleRefresh.replace(with: Task {
                        // Watchdog: a refresh task that outlives this window
                        // means the host hasn't re-sent a rumble cmd in a long
                        // time — game crash, focus loss, or driver hang. Any of
                        // those should leave the motor silent, not pumping
                        // forever. 1 s is well above every supported host's
                        // refresh cadence (DS4 ~33 ms, Xbox 80 ms, Pro 15 ms),
                        // so a healthy active rumble always cancels & replaces
                        // this task long before the deadline.
                        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                        while !Task.isCancelled, ContinuousClock.now < deadline {
                            try? await Task.sleep(for: interval)
                            // Re-snapshot per refresh so mid-stream slider tweaks apply.
                            if let payload = profile.encodeRumble(cmd, sequence: rumbleRefresh.nextCounter(), settings: settings.snapshot()) {
                                try? await transport?.sendVibration(payload, to: deviceID)
                            }
                        }
                        // Cancellation = a fresh host cmd took over; that path
                        // sends its own payload. Only when we hit the deadline
                        // without being replaced do we force a stop.
                        if Task.isCancelled { return }
                        if let payload = profile.encodeRumble(RumbleCommand(), sequence: rumbleRefresh.nextCounter(), settings: settings.snapshot()) {
                            try? await transport?.sendVibration(payload, to: deviceID)
                        }
                    })
                }
            }

            await session.handleSetReport(device: device, type: type, id: id, data: data)
        }
    }

    func hidTransport(for record: DeviceRecord) -> HIDDeviceTransport {
        // Always use .usb — BLE-transport virtual devices with output reports trigger
        // kIOReturnNoPower (IOServiceOpen:0xe00002e2). The transport hint is independent
        // of the real controller's connection and has no effect on input delivery.
        return .virtual
    }

    func republishVirtualHID(for id: DeviceID, modeID: String) async {
        guard var record = devices[id] else { return }
        // Broadcast an explicit stop before tearing down the VHID. Without it
        // the controller relies on natural heartbeat-decay (~300 ms) to silence
        // itself during the gap before the new VHID comes up — fine in
        // isolation, but repeated mode toggles or a stop swallowed by BLE could
        // leave a paired controller buzzing.
        if let stopPayload = record.profile.encodeRumble(
            RumbleCommand(),
            sequence: rumbleRefreshBoxes[id]?.nextCounter() ?? 0,
            settings: rumbleSettings(for: record).snapshot()
        ) {
            try? await transport(for: id.transport)?.sendVibration(stopPayload, to: id)
        }
        record.virtualHID = nil
        devices[id]?.virtualHID = nil
        devices[id]?.session = nil
        rumbleRefreshBoxes[id]?.cancel()
        rumbleRefreshBoxes[id] = nil
        try? await Task.sleep(for: .milliseconds(150))
        guard let (vhid, session) = makeVirtualHID(for: record, modeID: modeID) else {
            await failVirtualHID(for: id)
            return
        }
        await vhid.activate()
        devices[id]?.virtualHID = vhid
        devices[id]?.session = session
        devices[id]?.activeOutputModeID = modeID
        // The dispatch task captures vhid/session by value, so it must be
        // restarted against the freshly-built VHID — otherwise it keeps
        // dispatching to the torn-down device.
        startDispatch(for: id)
        await applySecondaryInputs(for: id, modeID: modeID)
    }
}
