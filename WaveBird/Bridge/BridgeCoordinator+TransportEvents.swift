import Foundation

extension BridgeCoordinator {
    // Solo (own-VHID) dispatch. Runs detached, off the main actor: the parse,
    // buildReport, and vhid.dispatch all happen on the cooperative pool so
    // input processing doesn't share a thread with the UI. We snapshot the
    // stable per-connection values (vhid/session/profile/calibration) into
    // locals here on the main actor — calibration is finalized by .ready (init
    // flash reads complete before .ready), so the snapshot is safe — and the
    // task captures only those Sendable locals, never self. republishVirtualHID
    // must re-call this after swapping the VHID, since the task holds the old
    // vhid/session by value rather than re-reading devices[id] each iteration.
    func startDispatch(for id: DeviceID) {
        dispatchTasks[id]?.cancel()
        stateContinuations[id]?.finish()
        guard let record = devices[id],
              let vhid = record.virtualHID,
              let session = record.session else { return }
        let profile = record.profile
        let calibration = record.calibration
        let axis = axisSettings(for: record)
        let mapBox = mappingSpecBoxes[id] ?? {
            let box = MappingSpecBox()
            mappingSpecBoxes[id] = box
            return box
        }()
        // Only the Xbox mode emits gated secondaries (the GIP 0x20 stream). Scope
        // the toggle to that mode by serial so it can't suppress another mode's
        // secondaries (e.g. passthrough's forwarded reports) for the same controller.
        let xboxGIP = (record.activeOutputModeID == "xboxSeries") ? xboxOutputSettings(for: record) : nil
        let kind = id.transport
        let tracker = activityTracker
        let (stream, continuation) = AsyncStream.makeStream(of: RawReport.self, bufferingPolicy: .bufferingNewest(1))
        stateContinuations[id] = continuation
        dispatchTasks[id] = Task.detached(priority: .userInitiated) {
            var lastSig: InputSignature?
            for await raw in stream {
                let parsed: ControllerState?
                switch kind {
                case .ble: parsed = profile.parseBLEReport(raw.data, calibration: calibration)
                case .usb: parsed = profile.parseUSBReport(raw.data, reportID: raw.reportID ?? 0, calibration: calibration)
                }
                guard let parsed else { continue }
                let inv = axis.snapshot()
                let state = parsed
                    .invertingY(left: inv.invertLeftY, right: inv.invertRightY)
                    .applyingMapping(mapBox.current)
                // Idle tracking: only a changed input fingerprint counts as activity.
                let sig = state.idleSignature
                if sig != lastSig { lastSig = sig; tracker.touch(id, at: .now) }
                let gipSnap = xboxGIP?.snapshot()
                // Mask the Guide bit from report 0x01 when "Send Guide to macOS"
                // is off. Only the primary report is masked; the GIP 0x07 path
                // uses the unmasked state and its own toggle.
                var primaryState = state
                if gipSnap?.sendGuideToSystem == false { primaryState.buttons.remove(.home) }
                let report = await session.buildReport(primaryState)
                try? await vhid.dispatch(report)
                // Skip secondaries entirely when the Xbox GIP stream is toggled
                // off; for every other mode xboxGIP is nil → secondaries always run.
                guard gipSnap?.sendGIPReports ?? true else { continue }
                let secondaries = await session.buildSecondaryReports(state)
                for secondary in secondaries {
                    // The Guide virtual-key (0x07) is gated independently of the
                    // 0x20 input stream.
                    if secondary.first == 0x07, gipSnap?.sendGuideToSDL == false { continue }
                    try? await vhid.dispatch(secondary)
                }
            }
        }
    }

    // Joy-Con pair dispatch. Stays on the main actor: the two sides share one
    // VirtualHIDDevice, so main-actor serialization gives the per-side
    // leftState/rightState mutations and the concurrent dispatchInputReport
    // calls a single-writer guarantee for free. Parses on main (rare, low-rate
    // case — one pair). Per-side streams are independent so either side's
    // update wakes its own task; both merge the latest snapshot.
    func startPairDispatch(for id: DeviceID) {
        dispatchTasks[id]?.cancel()
        stateContinuations[id]?.finish()
        guard let record = devices[id] else { return }
        let profile = record.profile
        let calibration = record.calibration
        let axis = pairAxisSettings()
        let kind = id.transport
        let (stream, continuation) = AsyncStream.makeStream(of: RawReport.self, bufferingPolicy: .bufferingNewest(1))
        stateContinuations[id] = continuation
        dispatchTasks[id] = Task { @MainActor [weak self] in
            var lastSig: InputSignature?
            for await raw in stream {
                guard let self, let pair = self.joyConPair, pair.includes(id),
                      let vhid = pair.virtualHID, let session = pair.session else { continue }
                let parsed: ControllerState?
                switch kind {
                case .ble: parsed = profile.parseBLEReport(raw.data, calibration: calibration)
                case .usb: parsed = profile.parseUSBReport(raw.data, reportID: raw.reportID ?? 0, calibration: calibration)
                }
                guard let state = parsed else { continue }
                if pair.leftID == id { pair.leftState = state }
                else if pair.rightID == id { pair.rightState = state }
                let merged = JoyConPairProfile.merge(left: pair.leftState, right: pair.rightState)
                // Either side's input refreshes this side's timestamp (both sides
                // see the same merged state), so the pair idles as one.
                let sig = merged.idleSignature
                if sig != lastSig { lastSig = sig; self.activityTracker.touch(id, at: .now) }
                let inv = axis.snapshot()
                let report = await session.buildReport(merged.invertingY(left: inv.invertLeftY, right: inv.invertRightY))
                try? await vhid.dispatch(report)
            }
        }
    }

    func handle(_ event: TransportEvent, kind: TransportKind) async {
        switch event {
        case .discovered(let id, let info):
            // A device whose VHID just failed to create re-advertises the
            // instant failVirtualHID drops the link; auto-connecting again
            // would fail identically, in a tight loop (connect → init
            // handshake → fail → disconnect → re-advertise) that floods the
            // logs and starves the main actor. Skip it — cooldown expiry or
            // the app coming forward retries via rescanAfterVHIDFailureCooldown.
            if let until = vhidFailureCooldowns[id], ContinuousClock.now < until {
                return
            }
            if let existing = devices[id] {
                // Re-discovery: only re-attempt connect if not already in flight.
                switch existing.connectionState {
                case .connected, .connecting, .discovered, .ready: return
                case .disconnected, .failed: break
                }
                devices[id]?.connectionState = .discovered
                devices[id]?.advertisement = info
            } else {
                guard let profile = profile(forProductID: info.productID, kind: kind) else { return }
                devices[id] = DeviceRecord(
                    id: id,
                    profile: profile,
                    advertisement: info,
                    connectionState: .discovered,
                    virtualHID: nil,
                    outputModeID: defaultOutputModeID
                )
            }
            guard let t = transport(for: kind) else { return }
            do {
                try await t.connect(id)
            } catch {
                devices[id]?.connectionState = .failed(String(describing: error))
            }

        case .connecting(let id):
            devices[id]?.connectionState = .connecting
            armConnectingTimeout(id, kind: kind)

        case .connected(let id):
            devices[id]?.connectionState = .connected

        case .ready(let id):
            devices[id]?.connectionState = .ready
            cancelConnectingTimeout(id)
            // Seed activity so the idle sweep doesn't drop a freshly-connected
            // controller before it sends any input.
            activityTracker.seed(id)
            guard let record = devices[id] else { return }
            // Joy-Cons take a separate path: solo Joy-Con play promotes via
            // handleJoyConReady. LTK pairing for each Joy-Con is deferred
            // until after its VHID activates (inside activateJoyConPair or
            // promoteSoloJoyCon) — keeps the profile picker before the
            // pair prompt, consistent with non-Joy-Con ordering.
            if JoyConPairProfile.isJoyCon(productID: record.advertisement.productID) {
                refreshKnownController(for: record)
                await handleJoyConReady(id: id)
                return
            }
            // Profile-first: build VHID (or arm the picker) immediately, then
            // raise the LTK-pair prompt as a follow-up. .commandResponse
            // events have already populated serial / onDeviceHostAddresses
            // if the flash reads succeeded.
            if let serial = record.serial,
               let preferredID = knownControllers[serial]?.resolvedProfileID {
                // Known preference — resolve the profile, seed the mapping
                // spec, and create the VHID for its base mode immediately.
                let profile = resolveMappingProfile(id: preferredID)
                devices[id]?.outputModeID = profile.baseModeID
                devices[id]?.mappingProfileID = profile.id
                seedMappingSpec(for: id, profile: profile)
                if let r = devices[id], let (vhid, session) = makeVirtualHID(for: r, modeID: profile.baseModeID) {
                    await vhid.activate()
                    devices[id]?.virtualHID = vhid
                    devices[id]?.session = session
                    devices[id]?.activeOutputModeID = profile.baseModeID
                    startDispatch(for: id)
                    await applySecondaryInputs(for: id, modeID: profile.baseModeID)
                } else {
                    if let r = devices[id] { refreshKnownController(for: r) }
                    await failVirtualHID(for: id)
                    return
                }
                if let updated = devices[id] {
                    refreshKnownController(for: updated)
                    maybePromptForPairing(record: updated)
                }
            } else {
                // No stored preference — ask the user before creating the VHID.
                devices[id]?.awaitingProfileSelection = true
                if let updated = devices[id] {
                    refreshKnownController(for: updated)
                }
                // If another picker is already showing, this device just gets
                // queued — advance only picks it up once the current one resolves.
                advanceAwaitingProfileSelection()
                // maybePromptForPairing deferred to activateWithProfile.
            }
        case .commandResponse(let id, let request, let response):
            FileHandle.standardError.write(Data("[ble] cmd:           \(hex(request))\n".utf8))
            if let response {
                let label = response.sourceHandle.map { String(format: "resp 0x%04X", $0) } ?? "resp       "
                FileHandle.standardError.write(Data("[ble] \(label): \(hex(response.data))\n".utf8))
                // Flash-read responses (cmd 0x02) get a per-address hexdump so
                // unknown flash regions stay readable when adding Pro/JoyCon support.
                if request.first == 0x02, let address = NS2Responses.flashReadAddress(of: request) {
                    FileHandle.standardError.write(Data("[ble] flash data:\n".utf8))
                    for line in hexdumpLines(response.data.dropFirst(16), baseOffset: address) {
                        FileHandle.standardError.write(Data("[ble]   \(line)\n".utf8))
                    }
                }
                if let profile = devices[id]?.profile,
                   let meta = profile.handleCommandResponse(request: request, response: response.data) {
                    mergeMetadata(meta, into: id)
                }
            } else {
                FileHandle.standardError.write(Data("[ble] resp:          (none)\n".utf8))
            }

        case .unmatchedResponse(_, let data, let sourceHandle):
            let label = sourceHandle.map { String(format: "0x%04X", $0) } ?? "?"
            FileHandle.standardError.write(Data("[ble] orphan \(label): \(hex(data))\n".utf8))

        case .disconnected(let id, _):
            cancelConnectingTimeout(id)
            devices[id]?.awaitingProfileSelection = false
            advanceAwaitingProfileSelection()
            // Joy-Con pair lifecycle: if either side drops, tear down the
            // shared VHID and reset the surviving side to waiting-for-partner
            // (if it's still .ready). The .disconnected record stays in
            // devices so it can be re-discovered on press-to-reconnect.
            if let pair = joyConPair, pair.includes(id) {
                let survivor = pair.partner(of: id)
                tearDownJoyConPair()
                if let survivor, devices[survivor]?.connectionState == .ready {
                    joyConWaitingForPartnerID = survivor
                }
            }
            if joyConWaitingForPartnerID == id {
                joyConWaitingForPartnerID = nil
            }
            dispatchTasks[id]?.cancel()
            dispatchTasks[id] = nil
            stateContinuations[id]?.finish()
            stateContinuations[id] = nil
            activityTracker.remove(id)
            rumbleRefreshBoxes[id]?.cancel()
            rumbleRefreshBoxes[id] = nil
            mappingSpecBoxes[id] = nil
            testRumbleTasks[id]?.cancel()
            testRumbleTasks[id] = nil
            // Preserve a .failed marking (VHID failure, connect timeout) so
            // the row keeps showing why the controller dropped; reconnecting
            // overwrites it via .discovered → .connecting as usual.
            switch devices[id]?.connectionState {
            case .failed: break
            default: devices[id]?.connectionState = .disconnected
            }
            devices[id]?.virtualHID = nil
            devices[id]?.session = nil

        case .reportReceived(let id, let reportID, let data):
            guard let record = devices[id] else { return }
            // Raw-forwarding session path (ns2Passthrough): dispatch the transport
            // bytes verbatim under the right HID report ID, bypassing parsing.
            // Used so Pro can emit BLE Report 0x09 — which the state-translation
            // path can't decode — while still letting 0x05 ride through.
            if let session = record.session,
               let vhid = record.virtualHID,
               let raw = session.transformRawReport(reportID: reportID, data: data) {
                Task {
                    do {
                        try await vhid.dispatch(raw)
                    } catch {
                        stderrLog("[hid] dispatch failed len=\(raw.count) error=\(error)")
                    }
                }
                return
            }
            // Only the shared input (Report 0x05, unprefixed → reportID nil)
            // matches the layout NS2Report0x05.decode expects. The Pro's
            // secondary channel (Report 0x09) reaches here when the session
            // isn't raw-forwarding; its different layout would misdecode as
            // bogus buttons/sticks/IMU, so skip it. The parse itself happens in
            // the per-device dispatch task (off-main for solo devices).
            if kind == .ble, reportID != nil { return }
            stateContinuations[id]?.yield(RawReport(reportID: reportID, data: data))

        case .error(_, let msg):
            stderrLog(msg)

        case .availability(let reason):
            transportUnavailableReason = reason
        }
    }

    func mergeMetadata(_ meta: ControllerMetadata, into id: DeviceID) {
        if let serial = meta.serial {
            devices[id]?.serial = serial
            FileHandle.standardError.write(Data("[ble] serial:        \(serial)\n".utf8))
        }
        if let firmware = meta.firmware {
            devices[id]?.firmware = firmware
            FileHandle.standardError.write(Data("[ble] firmware:      \(firmware)\n".utf8))
        }
        if let zeros = meta.triggerZeros {
            devices[id]?.calibration.triggerZeros = zeros
            FileHandle.standardError.write(Data("[ble] trigger zeros: L=\(zeros.left) R=\(zeros.right)\n".utf8))
        }
        if let cal = meta.leftCalibration {
            devices[id]?.calibration.left = cal
            FileHandle.standardError.write(Data("[ble] L stick cal: n=(\(cal.neutralX),\(cal.neutralY)) max=(\(cal.maxX),\(cal.maxY)) min=(\(cal.minX),\(cal.minY))\n".utf8))
        }
        if let cal = meta.rightCalibration {
            devices[id]?.calibration.right = cal
            FileHandle.standardError.write(Data("[ble] R stick cal: n=(\(cal.neutralX),\(cal.neutralY)) max=(\(cal.maxX),\(cal.maxY)) min=(\(cal.minX),\(cal.minY))\n".utf8))
        }
        if let addrs = meta.onDeviceHostAddresses {
            devices[id]?.onDeviceHostAddresses = addrs
            let formatted = addrs.map { $0.map { String(format: "%02X", $0) }.joined(separator: ":") }.joined(separator: ", ")
            FileHandle.standardError.write(Data("[ble] paired hosts: [\(formatted)]\n".utf8))
        }
    }

    func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // Classic hexdump-style: `<OFFSET>: AA BB CC ... |ascii|`, 16 bytes per row.
    // baseOffset shifts the displayed offset so the column reflects an absolute address.
    func hexdumpLines(_ data: Data, baseOffset: Int = 0) -> [String] {
        var lines: [String] = []
        let bytes = Array(data)
        var offset = 0
        while offset < bytes.count {
            let chunk = Array(bytes[offset..<min(offset + 16, bytes.count)])
            let first = chunk.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            let second = chunk.dropFirst(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            let hex = first + (second.isEmpty ? "" : "  " + second)
            let ascii = String(chunk.map {
                (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "."
            })
            let padded = hex.padding(toLength: 48, withPad: " ", startingAt: 0)
            lines.append("\(String(format: "0x%06X", baseOffset + offset)): \(padded) |\(ascii)|")
            offset += 16
        }
        return lines
    }

    func armConnectingTimeout(_ id: DeviceID, kind: TransportKind) {
        connectingTimeoutTasks[id]?.cancel()
        let timeout = Self.connectingTimeout
        connectingTimeoutTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            guard let state = self.devices[id]?.connectionState,
                  state == .connecting || state == .connected else { return }
            stderrLog("[ble] connect timeout after \(timeout) — forcing disconnect for \(id.raw)")
            self.devices[id]?.connectionState = .failed("Timed out waiting for controller to become ready")
            if let t = self.transport(for: kind) {
                await t.disconnect(id)
            }
            self.connectingTimeoutTasks[id] = nil
        }
    }

    func cancelConnectingTimeout(_ id: DeviceID) {
        connectingTimeoutTasks[id]?.cancel()
        connectingTimeoutTasks[id] = nil
    }

    func profile(forProductID pid: UInt16, kind: TransportKind) -> (any ControllerProfile)? {
        switch kind {
        case .ble: return profiles.first { $0.bleMatcher?.productID == pid }
        case .usb: return profiles.first { $0.usbMatcher?.productID == pid }
        }
    }
}
