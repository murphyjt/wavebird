import CoreHID
import Foundation

extension BridgeCoordinator {
    // Called from .ready for Joy-Con devices. If a partner of the opposite
    // side is already .ready, form the pair (and either show a profile picker
    // or create the merged VHID using a remembered preference). Otherwise
    // surface a waiting-for-partner sheet via joyConWaitingForPartnerID.
    func handleJoyConReady(id: DeviceID) async {
        guard let record = devices[id] else { return }
        // Split-off Joy-Cons come back as solo controllers — own VHID, no
        // pair, no partner sheet. The Pair Joy-Cons button clears suppression
        // when the user wants to re-merge.
        if let serial = record.serial, splitJoyConSerialsThisSession.contains(serial) {
            await promoteSoloJoyCon(id: id)
            return
        }
        let pid = record.advertisement.productID
        let amLeft = JoyConPairProfile.isLeft(productID: pid)

        let partnerID = devices.first { otherID, other in
            guard otherID != id,
                  other.connectionState == .ready,
                  JoyConPairProfile.isJoyCon(productID: other.advertisement.productID)
            else { return false }
            // Skip partners the user already split off — they shouldn't get
            // pulled back into a new pair.
            if let s = other.serial, splitJoyConSerialsThisSession.contains(s) {
                return false
            }
            return JoyConPairProfile.isLeft(productID: other.advertisement.productID) != amLeft
        }?.key

        guard let partnerID else {
            joyConWaitingForPartnerID = id
            return
        }

        joyConWaitingForPartnerID = nil
        let leftID  = amLeft ? id : partnerID
        let rightID = amLeft ? partnerID : id
        await formJoyConPair(leftID: leftID, rightID: rightID)
    }

    // Drop the merged Joy-Con VHID, then bring each side back online as its
    // own solo controller. Suppression keeps a reconnecting partner from
    // pulling either side back into auto-pair this session; the Pair
    // Joy-Cons button clears it when the user wants to re-merge.
    func splitJoyConPair() async {
        guard let pair = joyConPair else { return }
        let leftID = pair.leftID
        let rightID = pair.rightID
        if let s = devices[leftID]?.serial  { splitJoyConSerialsThisSession.insert(s) }
        if let s = devices[rightID]?.serial { splitJoyConSerialsThisSession.insert(s) }
        tearDownJoyConPair()
        joyConWaitingForPartnerID = nil
        await promoteSoloJoyCon(id: leftID)
        await promoteSoloJoyCon(id: rightID)
    }

    // Build (or rebuild) the solo VHID for a single Joy-Con. Used when a
    // pair is split, when a sibling reconnects after a split, and when the
    // user dismisses the waiting-for-partner sheet. Stored preference goes
    // straight to a VHID; absence queues the profile picker.
    func promoteSoloJoyCon(id: DeviceID) async {
        guard let record = devices[id], record.connectionState == .ready else { return }
        guard JoyConPairProfile.isJoyCon(productID: record.advertisement.productID) else { return }

        if let serial = record.serial {
            splitJoyConSerialsThisSession.insert(serial)
        }
        if joyConWaitingForPartnerID == id {
            joyConWaitingForPartnerID = nil
        }
        // A prior solo run could leave a VHID behind (e.g. reconnect path).
        // Drop it before creating a new one so dispatch tasks don't double up.
        await tearDownSoloJoyCon(id: id)

        if let serial = record.serial,
           let preferred = knownControllers[serial]?.preferredOutputModeID {
            devices[id]?.outputModeID = preferred
            if let r = devices[id], let (vhid, session) = makeVirtualHID(for: r, modeID: preferred) {
                await vhid.activate()
                devices[id]?.virtualHID = vhid
                devices[id]?.session = session
                devices[id]?.activeOutputModeID = preferred
                startDispatch(for: id)
                // Profile-first: surface the LTK-pair prompt now that the
                // solo VHID is up. The picker-path covers itself via
                // activateWithProfile's existing maybePromptForPairing call.
                if let updated = devices[id] {
                    maybePromptForPairing(record: updated)
                }
            } else {
                await failVirtualHID(for: id)
            }
        } else {
            devices[id]?.awaitingProfileSelection = true
            advanceAwaitingProfileSelection()
        }
    }

    // Symmetric to tearDownJoyConPair but for a single solo VHID. Emits an
    // explicit stop frame so the motor doesn't hang in the gap before
    // anything new comes up. No-op if there's no live VHID.
    func tearDownSoloJoyCon(id: DeviceID) async {
        guard devices[id]?.virtualHID != nil else { return }
        if let record = devices[id],
           let stopPayload = record.profile.encodeRumble(
               RumbleCommand(),
               sequence: rumbleRefreshBoxes[id]?.nextCounter() ?? 0,
               settings: rumbleSettings(for: record).snapshot()
           ) {
            try? await transport(for: id.transport)?.sendVibration(stopPayload, to: id)
        }
        dispatchTasks[id]?.cancel(); dispatchTasks[id] = nil
        stateContinuations[id]?.finish(); stateContinuations[id] = nil
        rumbleRefreshBoxes[id]?.cancel(); rumbleRefreshBoxes[id] = nil
        devices[id]?.virtualHID = nil
        devices[id]?.session = nil
    }

    // True when at least one .ready Joy-Con isn't currently in the active
    // pair. Drives the Pair Joy-Cons button in ContentView. Suppressed
    // serials still count — the manual trigger clears suppression for them.
    var hasUnpairedJoyCon: Bool {
        guard joyConPair == nil else { return false }
        return devices.values.contains { record in
            record.connectionState == .ready
            && JoyConPairProfile.isJoyCon(productID: record.advertisement.productID)
        }
    }

    // Manual entry point for the Pair Joy-Cons button. Clears any split
    // suppression accumulated this session, then either:
    //   * forms a pair immediately if at least one L and one R are .ready, or
    //   * arms the waiting-for-partner sheet on the lone .ready Joy-Con so the
    //     next opposite-side Joy-Con joins on contact.
    // Multi-Joy-Con setups (e.g. 2 Ls + 1 R) pick the first-encountered L+R
    // pair; leftover Joy-Cons stay solo. Skipped when a pair is already
    // active — JoyConPair only models a single pair at a time (see comment
    // in JoyConPair.swift).
    func pairJoyCons() async {
        guard joyConPair == nil else { return }
        splitJoyConSerialsThisSession.removeAll()

        let solos = devices.values.filter { record in
            record.connectionState == .ready
            && JoyConPairProfile.isJoyCon(productID: record.advertisement.productID)
        }
        let lefts  = solos.filter { JoyConPairProfile.isLeft(productID:  $0.advertisement.productID) }
        let rights = solos.filter { JoyConPairProfile.isRight(productID: $0.advertisement.productID) }

        if let l = lefts.first, let r = rights.first {
            // Solo VHIDs from a prior split linger until torn down — drop
            // them before bringing up the merged VHID so the controllers
            // don't briefly own two virtual devices each.
            await tearDownSoloJoyCon(id: l.id)
            await tearDownSoloJoyCon(id: r.id)
            joyConWaitingForPartnerID = nil
            await formJoyConPair(leftID: l.id, rightID: r.id)
        } else if let lone = lefts.first ?? rights.first {
            await tearDownSoloJoyCon(id: lone.id)
            joyConWaitingForPartnerID = lone.id
        }
    }

    // Both Joy-Cons are .ready — decide whether to ask the user for a profile
    // or jump straight to the merged VHID using a remembered preference.
    // Preference lookup checks BOTH serials so the user can answer the picker
    // once and have it stick regardless of which Joy-Con they reconnect first.
    func formJoyConPair(leftID: DeviceID, rightID: DeviceID) async {
        guard let left = devices[leftID], let right = devices[rightID] else { return }
        joyConPair = JoyConPair(leftID: leftID, rightID: rightID)

        let storedMode: String? = left.serial.flatMap { knownControllers[$0]?.preferredOutputModeID }
            ?? right.serial.flatMap { knownControllers[$0]?.preferredOutputModeID }

        if let storedMode {
            await activateJoyConPair(modeID: storedMode)
        } else {
            // Surface a single picker keyed to L's record. activateWithProfile
            // recognizes the JoyCon-pair case and routes through activateJoyConPair.
            devices[leftID]?.awaitingProfileSelection = true
            advanceAwaitingProfileSelection()
        }
    }

    // Create the merged VHID for the active pair and start the merged dispatch
    // path. Per-side dispatch tasks update the pair's left/right snapshot and
    // emit a single merged report; rumble is split per-side and written to
    // each Joy-Con's vibration char.
    func activateJoyConPair(modeID: String) async {
        guard let pair = joyConPair,
              let left = devices[pair.leftID],
              let right = devices[pair.rightID] else { return }

        if let serial = left.serial { persistPairPreference(modeID, forSerial: serial, record: left) }
        if let serial = right.serial { persistPairPreference(modeID, forSerial: serial, record: right) }

        let outProfile = catalog.resolved(id: modeID).makeProfile(joyConPairProfile)
        let session = outProfile.makeSession()
        let serial = left.serial ?? right.serial

        // Both Joy-Con encoders read tuning from the same paired-profile
        // RumbleSettings — the merged detail-card binding writes once and
        // both motors feel the change.
        let sharedSettings = pairRumbleSettings()
        let onSetReport = makePairSetReportHandler(
            pair: pair,
            leftProfile: left.profile,
            rightProfile: right.profile,
            leftSettings: sharedSettings,
            rightSettings: sharedSettings,
            session: session
        )

        guard let vhid = VirtualHIDDevice(
            descriptor: outProfile.descriptor,
            vendorID: outProfile.vendorID,
            productID: outProfile.productID,
            productName: outProfile.productName,
            manufacturer: outProfile.manufacturer,
            versionNumber: outProfile.versionNumber,
            serialNumber: serial,
            transport: .usb,
            onSetReport: onSetReport
        ) else {
            // Drop the half-formed pair immediately — a non-nil joyConPair
            // slot implies a live VHID (see the property comment), and waiting
            // for the two .disconnected events to tear it down leaves that
            // invariant transiently false. Teardown first also keeps the
            // survivor-requeue logic in the .disconnected handler from seeing
            // the pair. Both sides are marked failed either way.
            tearDownJoyConPair()
            await failVirtualHID(for: pair.leftID)
            await failVirtualHID(for: pair.rightID)
            return
        }
        hidAccessIssue = nil
        vhidFailureCooldowns[pair.leftID] = nil
        vhidFailureCooldowns[pair.rightID] = nil
        await vhid.activate()
        pair.virtualHID = vhid
        pair.session = session
        pair.activeOutputModeID = modeID
        joyConPairVHIDActive = true
        startPairDispatch(for: pair.leftID)
        startPairDispatch(for: pair.rightID)

        // Profile-first ordering for Joy-Cons too: now that the merged VHID
        // is up, surface the LTK-pair prompt for each side. Only one slot at
        // a time; the second side picks up via reconsiderPairingPrompts
        // when the first resolves.
        if let left = devices[pair.leftID]   { maybePromptForPairing(record: left) }
        if let right = devices[pair.rightID] { maybePromptForPairing(record: right) }
    }

    // Persist the user's profile choice on each Joy-Con serial individually so
    // either side reconnecting alone restores the same mode once paired up.
    // Display name stays per-side ("Joy-Con 2 (L)"), not the pair name — the
    // entry represents a physical controller, not the merged identity.
    func persistPairPreference(_ modeID: String, forSerial serial: String, record: DeviceRecord) {
        let onDevicePaired = HostAdapter.address().flatMap { record.onDeviceHostAddresses?.contains($0) } ?? false
        var entry = knownControllers[serial] ?? KnownController(
            serial: serial,
            productID: record.advertisement.productID,
            displayName: record.profile.name,
            lastSeenAt: Date(),
            peripheralUUID: record.id.raw,
            preferredOutputModeID: nil,
            isPaired: onDevicePaired
        )
        entry.preferredOutputModeID = modeID
        entry.lastSeenAt = Date()
        entry.peripheralUUID = record.id.raw
        knownControllers[serial] = entry
        persistKnownControllers()
    }

    func tearDownJoyConPair() {
        guard let pair = joyConPair else { return }
        // Cancel both per-side dispatch tasks so they don't fire against a
        // disposed VHID. The per-side rumble refresh boxes are released too.
        dispatchTasks[pair.leftID]?.cancel(); dispatchTasks[pair.leftID] = nil
        dispatchTasks[pair.rightID]?.cancel(); dispatchTasks[pair.rightID] = nil
        stateContinuations[pair.leftID]?.finish(); stateContinuations[pair.leftID] = nil
        stateContinuations[pair.rightID]?.finish(); stateContinuations[pair.rightID] = nil
        rumbleRefreshBoxes[pair.leftID]?.cancel(); rumbleRefreshBoxes[pair.leftID] = nil
        rumbleRefreshBoxes[pair.rightID]?.cancel(); rumbleRefreshBoxes[pair.rightID] = nil
        pair.virtualHID = nil
        pair.session = nil
        joyConPair = nil
        joyConPairVHIDActive = false
    }

    // True if the device belongs to the currently-active Joy-Con pair.
    func isJoyConPaired(_ id: DeviceID) -> Bool {
        joyConPair?.includes(id) == true
    }

    // Sheet dismissed without action — treat the lone Joy-Con as its own
    // controller. Adds its serial to the split-suppression set so a partner
    // reconnecting won't yank it into auto-pair, then promotes it to a solo
    // VHID (or queues the profile picker if it has no stored preference).
    func acknowledgeJoyConWaitingForPartner() {
        guard let id = joyConWaitingForPartnerID else { return }
        joyConWaitingForPartnerID = nil
        if let serial = devices[id]?.serial {
            splitJoyConSerialsThisSession.insert(serial)
        }
        Task { [self] in await self.promoteSoloJoyCon(id: id) }
    }

    // Set-report handler for the merged Joy-Con pair VHID. Splits an incoming
    // RumbleCommand into per-side single-motor frames: leftAmp+left settings
    // → L's vibration char; rightAmp+right settings → R's vibration char.
    // Refresh loop ticks each side independently at the merged interval.
    func makePairSetReportHandler(
        pair: JoyConPair,
        leftProfile: any ControllerProfile,
        rightProfile: any ControllerProfile,
        leftSettings: RumbleSettings,
        rightSettings: RumbleSettings,
        session: any HIDOutputSession
    ) -> VirtualHIDDevice.SetReportHandler {
        let leftBox = RumbleRefreshBox()
        let rightBox = RumbleRefreshBox()
        rumbleRefreshBoxes[pair.leftID] = leftBox
        rumbleRefreshBoxes[pair.rightID] = rightBox
        let leftID = pair.leftID
        let rightID = pair.rightID

        return { [weak self] device, type, id, data in
            let idStr = id.map { String(format: "0x%02X", $0.rawValue) } ?? "-"
            let hex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            stderrLog("[hid] setReport type=\(type) id=\(idStr) len=\(data.count) [\(hex)] (joycon pair)")

            if let cmd = session.parseRumble(type: type, id: id, data: data) {
                leftBox.cancel()
                rightBox.cancel()

                let transportL = await self?.transport(for: leftID.transport)
                let transportR = await self?.transport(for: rightID.transport)

                // Single tick per side. Each side ignores the opposite amp by
                // virtue of its profile's encoder pulling only leftAmp or
                // rightAmp from the command.
                if let payload = leftProfile.encodeRumble(cmd, sequence: leftBox.nextCounter(), settings: leftSettings.snapshot()) {
                    try? await transportL?.sendVibration(payload, to: leftID)
                }
                if let payload = rightProfile.encodeRumble(cmd, sequence: rightBox.nextCounter(), settings: rightSettings.snapshot()) {
                    try? await transportR?.sendVibration(payload, to: rightID)
                }

                // Heartbeat. Each Joy-Con has its own refresh box so a stop on
                // one side doesn't yank the other side's loop. Watchdog still
                // 1 s — well above host cadences.
                let interval = BridgeCoordinator.mergeRefresh(leftProfile.rumbleRefreshInterval, session.refreshInterval)
                if let interval, !cmd.isStop {
                    leftBox.replace(with: Task {
                        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                        while !Task.isCancelled, ContinuousClock.now < deadline {
                            try? await Task.sleep(for: interval)
                            if let payload = leftProfile.encodeRumble(cmd, sequence: leftBox.nextCounter(), settings: leftSettings.snapshot()) {
                                try? await transportL?.sendVibration(payload, to: leftID)
                            }
                        }
                        if Task.isCancelled { return }
                        if let payload = leftProfile.encodeRumble(RumbleCommand(), sequence: leftBox.nextCounter(), settings: leftSettings.snapshot()) {
                            try? await transportL?.sendVibration(payload, to: leftID)
                        }
                    })
                    rightBox.replace(with: Task {
                        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                        while !Task.isCancelled, ContinuousClock.now < deadline {
                            try? await Task.sleep(for: interval)
                            if let payload = rightProfile.encodeRumble(cmd, sequence: rightBox.nextCounter(), settings: rightSettings.snapshot()) {
                                try? await transportR?.sendVibration(payload, to: rightID)
                            }
                        }
                        if Task.isCancelled { return }
                        if let payload = rightProfile.encodeRumble(RumbleCommand(), sequence: rightBox.nextCounter(), settings: rightSettings.snapshot()) {
                            try? await transportR?.sendVibration(payload, to: rightID)
                        }
                    })
                }
            }

            await session.handleSetReport(device: device, type: type, id: id, data: data)
        }
    }
}
