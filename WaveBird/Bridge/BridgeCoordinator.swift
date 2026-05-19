import CoreHID
import Foundation
import Observation

@Sendable func stderrLog(_ line: String) {
    FileHandle.standardError.write(Data("\(line)\n".utf8))
}

enum DeviceConnectionState: Sendable, Equatable {
    case discovered
    case connecting
    case connected
    case ready
    case disconnected
    case failed(String)
}

struct DeviceRecord: Identifiable {
    let id: DeviceID
    let profile: any ControllerProfile
    var advertisement: AdvertisementInfo
    var connectionState: DeviceConnectionState
    var virtualHID: VirtualHIDDevice?
    var reportRate: Double = 0       // reports received per second over BLE
    var serial: String? = nil
    var firmware: FirmwareInfo? = nil
    var calibration = ControllerCalibration()
    // Populated from the 0x1FA000 flash read during init. nil = not yet read.
    var onDeviceHostAddresses: [Data]? = nil
    var outputModeID: String
    // Mode captured at the moment the virtual HID device was created. We
    // intentionally keep using this instead of the record's live outputModeID
    // while republishing so reports keep matching the active descriptor.
    var activeOutputModeID: String = HIDOutputCatalog.nativeID
    // Per-virtual-device session created at .ready via the output profile's
    // makeSession(). Stateless outputs return self; stateful spoofs (Switch
    // Pro) return an actor that owns handshake/mode state for this connection.
    var session: (any HIDOutputSession)?
}

// One row in the controllers list. Either a currently-advertising/connected
// device (live), a previously-paired controller that isn't currently nearby
// (offline), or both at once (a live device whose serial we recognize from
// past pairings — still rendered as a live row, with a Paired badge).
struct ListEntry: Identifiable, Sendable {
    let id: String
    let live: DeviceRecord?
    let paired: PairedController?

    var displayName: String {
        paired?.displayName ?? live?.profile.name ?? "Unknown controller"
    }

    var serial: String? {
        live?.serial ?? paired?.serial
    }

    var isLive: Bool { live != nil }
    var isPaired: Bool { paired != nil }
}

@MainActor
@Observable
final class BridgeCoordinator {
    let profiles: [any ControllerProfile]
    let transports: [any Transport]
    let catalog: HIDOutputCatalog

    private(set) var devices: [DeviceID: DeviceRecord] = [:]
    private(set) var isScanning = false
    private(set) var lastReportSnapshot: ReportSnapshot?
    var pairingPrompt: PairingPrompt?
    // ListEntry.id of the controller shown in the controller-detail Window.
    // Written by every caller that opens the window (main-window rows, menu
    // bar item); ControllerDetailWindow reads it. Not cleared on close — the
    // next open always overwrites first, which avoids a race where SwiftUI
    // evaluates the window body against a stale nil.
    var pendingDetailEntryID: String?

    private static let outputModeDefaultsKey = "WaveBird.hidOutputMode"
    private static let pairedControllersKey = "WaveBird.pairedControllers"
    private static let legacyPairedSerialsKey = "WaveBird.pairedSerials"
    private static let scanAtLaunchKey = "WaveBird.scanAtLaunch"

    /// User preference: start scanning automatically when the app launches.
    /// Defaults to true for first launches.
    static var scanAtLaunch: Bool {
        UserDefaults.standard.object(forKey: scanAtLaunchKey) as? Bool ?? true
    }
    let defaultOutputModeID: String

    // Controllers we've previously paired with on this host. Persisted as
    // JSON in UserDefaults under pairedControllersKey. Mutating callers must
    // route through persistPairedControllers() so disk + memory stay in sync.
    private(set) var pairedControllers: [String: PairedController]

    // Per-session "user said not now" set, keyed by serial. Prevents re-prompting
    // on reconnect within the same launch. Cleared at process exit so the user
    // gets another chance next time they open WaveBird.
    @ObservationIgnored
    private var declinedPairingThisSession: Set<String> = []

    @ObservationIgnored
    private var consumerTask: Task<Void, Never>?

    @ObservationIgnored
    private var rateTask: Task<Void, Never>?

    @ObservationIgnored
    private var reportCounts: [DeviceID: Int] = [:]

    // Per-device latest-state channels. The consumer yields parsed states here
    // (non-blocking); a separate dispatch task picks up the newest and sends it
    // to the virtual HID device. bufferingNewest(1) discards stale states if the
    // dispatch task falls behind, so we always forward the most recent input.
    @ObservationIgnored
    private var stateContinuations: [DeviceID: AsyncStream<ControllerState>.Continuation] = [:]

    @ObservationIgnored
    private var dispatchTasks: [DeviceID: Task<Void, Never>] = [:]

    @ObservationIgnored
    private var rumbleRefreshBoxes: [DeviceID: RumbleRefreshBox] = [:]

    @ObservationIgnored
    private var testRumbleTasks: [DeviceID: Task<Void, Never>] = [:]

    // Per-device tunable rumble settings. The settings instance for a given product ID
    // is created the first time a device of that type connects, then reused — UserDefaults
    // persistence is keyed by PID so the same physical controller carries its tuning
    // across re-pairings. The encoder reads via passed-in snapshots, so the BLE write
    // queue never touches @MainActor state.
    private var rumbleSettingsByPID: [UInt16: RumbleSettings] = [:]

    func rumbleSettings(for record: DeviceRecord) -> RumbleSettings {
        rumbleSettings(forProductID: record.advertisement.productID)
    }

    func rumbleSettings(forProductID pid: UInt16) -> RumbleSettings {
        if let existing = rumbleSettingsByPID[pid] { return existing }
        let made = RumbleSettings(productID: pid)
        rumbleSettingsByPID[pid] = made
        return made
    }

    // Prevents App Nap / background throttling while a controller is active.
    // Wrapped so that deinit ends the activity regardless of isolation.
    @ObservationIgnored
    private var activity: ActivityToken?

    private final class ActivityToken: @unchecked Sendable {
        private let token: NSObjectProtocol
        init(_ token: NSObjectProtocol) { self.token = token }
        deinit { ProcessInfo.processInfo.endActivity(token) }
    }

    init(
        profiles: [any ControllerProfile],
        transports: [any Transport],
        catalog: HIDOutputCatalog = .default
    ) {
        self.profiles = profiles
        self.transports = transports
        self.catalog = catalog
        let stored = UserDefaults.standard.string(forKey: Self.outputModeDefaultsKey)
        self.defaultOutputModeID = stored.flatMap { catalog.entry(id: $0)?.id } ?? HIDOutputCatalog.nativeID
        self.pairedControllers = Self.loadPairedControllers()
    }

    // First read pairedControllersKey (the new JSON shape). If that's absent,
    // migrate from the prior pairedSerialsKey ([String]) by synthesizing minimal
    // entries and persisting the new shape. The legacy key is removed once
    // migration completes so we don't re-do it on every launch.
    private static func loadPairedControllers() -> [String: PairedController] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: pairedControllersKey),
           let decoded = try? JSONDecoder().decode([String: PairedController].self, from: data) {
            return decoded
        }
        let legacy = defaults.stringArray(forKey: legacyPairedSerialsKey) ?? []
        guard !legacy.isEmpty else { return [:] }
        var migrated: [String: PairedController] = [:]
        for serial in legacy {
            migrated[serial] = PairedController(
                serial: serial,
                productID: 0,
                displayName: "Paired controller",
                lastSeenAt: .distantPast
            )
        }
        if let encoded = try? JSONEncoder().encode(migrated) {
            defaults.set(encoded, forKey: pairedControllersKey)
        }
        defaults.removeObject(forKey: legacyPairedSerialsKey)
        return migrated
    }

    private func persistPairedControllers() {
        guard let encoded = try? JSONEncoder().encode(pairedControllers) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.pairedControllersKey)
    }

    // LTK pairing entrypoints. We always need the host BT address (the value
    // the controller compares to its flash entries when deciding whether to
    // auto-reconnect), so if IOBluetooth can't give it to us we silently skip.
    //
    // Four (local × on-device) states determine the prompt:
    //   yes/yes → already paired, no prompt
    //   yes/no  → intent .repair (something else overwrote our slot)
    //   no/yes  → intent .remember (we forgot but the controller didn't)
    //   no/no   → intent .pair (fresh exchange)
    // When the flash read failed (onDeviceHostAddresses still nil at .ready),
    // we fall back to local-only logic — same behavior as before this branch.
    private func maybePromptForPairing(record: DeviceRecord) {
        guard pairingPrompt == nil,
              record.id.transport == .ble,
              let serial = record.serial,
              !declinedPairingThisSession.contains(serial),
              let host = HostAdapter.address()
        else { return }

        let localPaired = pairedControllers[serial] != nil
        let onDevicePaired: Bool? = record.onDeviceHostAddresses.map { $0.contains(host) }

        let intent: PairingPrompt.Intent?
        switch (localPaired, onDevicePaired) {
        case (true,  true?):  intent = nil           // YES/YES — already paired
        case (true,  false?): intent = .repair       // YES/NO  — controller forgot us
        case (false, true?):  intent = .remember     // NO/YES  — we forgot the controller
        case (false, false?): intent = .pair         // NO/NO   — fresh
        case (true,  nil):    intent = nil           // flash unknown, local known — trust local
        case (false, nil):    intent = .pair         // flash unknown, local unpaired — fresh
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
        // .remember adopts the existing on-device pairing locally without any
        // wire exchange — the controller already has our host address stored.
        if prompt.intent == .remember {
            if let record = devices[prompt.deviceID] { recordPairing(for: record) }
            pairingPrompt = nil
            return
        }
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
            if let record = devices[prompt.deviceID] { recordPairing(for: record) }
            pairingPrompt = nil
        } catch {
            pairingPrompt?.status = .failed(String(describing: error))
        }
    }

    func declinePairing() {
        if let serial = pairingPrompt?.serial {
            declinedPairingThisSession.insert(serial)
        }
        pairingPrompt = nil
    }

    // User-initiated pairing from the controller detail sheet. Reuses the same
    // PairingPrompt + PairingSheet path as the auto-prompt, but bypasses the
    // session-decline gate since the click is an explicit opt-in.
    func requestPairing(for record: DeviceRecord) {
        guard record.id.transport == .ble,
              let serial = record.serial,
              let host = HostAdapter.address()
        else { return }
        let onDevicePaired: Bool? = record.onDeviceHostAddresses.map { $0.contains(host) }
        let intent: PairingPrompt.Intent = onDevicePaired == true ? .remember : .pair
        declinedPairingThisSession.remove(serial)
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

    // Whether requestPairing(for:) would currently succeed for the given record.
    // Used to enable/disable the "Pair This Device…" button.
    func canRequestPairing(for record: DeviceRecord) -> Bool {
        record.id.transport == .ble
            && record.connectionState == .ready
            && record.serial != nil
            && HostAdapter.address() != nil
    }

    // Live entries first (sorted by serial for stability), then paired-offline
    // entries (sorted by lastSeenAt desc). A live entry whose serial matches a
    // paired record is decorated with that record; offline-only entries appear
    // when a paired controller isn't currently advertising.
    var listEntries: [ListEntry] {
        // Track which paired records have been "claimed" by a live row, by
        // serial OR by peripheralUUID. Peripheral matching lets the live and
        // offline rows share an identity from the moment the peripheral is
        // discovered, instead of waiting for the serial flash read.
        var claimedSerials: Set<String> = []
        let liveSorted = devices.values.sorted { lhs, rhs in
            (lhs.serial ?? "") < (rhs.serial ?? "")
        }
        var entries: [ListEntry] = liveSorted.map { record in
            let paired: PairedController? = record.serial.flatMap { pairedControllers[$0] }
                ?? pairedControllers.values.first { $0.peripheralUUID == record.id.raw }
            if let p = paired { claimedSerials.insert(p.serial) }
            // When a paired record matches, use its serial as the row's id
            // (even before the live record's own serial arrives). This keeps
            // the row identity stable from offline → live across discovery.
            let id = paired?.serial ?? record.serial ?? record.id.raw.uuidString
            return ListEntry(id: id, live: record, paired: paired)
        }
        let offline = pairedControllers.values
            .filter { !claimedSerials.contains($0.serial) }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
        for paired in offline {
            entries.append(ListEntry(id: paired.serial, live: nil, paired: paired))
        }
        return entries
    }

    // Look up the profile that owns a given product ID across known transports.
    // Used to render the right icon tint for offline rows (we don't have a
    // live DeviceRecord for those).
    func profile(forProductID pid: UInt16) -> (any ControllerProfile)? {
        profiles.first { $0.bleMatcher?.productID == pid || $0.usbMatcher?.productID == pid }
    }

    // Returns whether this controller's serial is in our local paired dict.
    // Note this only reflects what WaveBird has recorded — the controller may
    // still hold an LTK for this Mac on its side even after a local forget;
    // that on-device entry only gets cleared when the controller next pairs
    // with something else (or the user re-pairs with WaveBird).
    func isPaired(serial: String) -> Bool {
        pairedControllers[serial] != nil
    }

    // Forget a serial locally. Re-shows the pairing prompt on the controller's
    // next .ready. Does not currently send 0x03/0x08 ("Clear pairing info") to
    // the controller — that would wipe the on-device LTK entirely. Add the
    // device-side clear later if the local-only forget proves confusing.
    func forgetPairing(serial: String) {
        guard pairedControllers.removeValue(forKey: serial) != nil else { return }
        persistPairedControllers()
        declinedPairingThisSession.remove(serial)
    }

    // Persist the user's preferred output mode for a specific paired serial,
    // and if that controller is currently live, republish its virtual HID in
    // the new mode immediately. The per-serial preference is applied again on
    // future .ready transitions for this serial.
    func setPreferredOutputMode(_ modeID: String, forSerial serial: String) async {
        guard var paired = pairedControllers[serial] else { return }
        if paired.preferredOutputModeID != modeID {
            paired.preferredOutputModeID = modeID
            pairedControllers[serial] = paired
            persistPairedControllers()
        }
        if let liveID = devices.first(where: { $0.value.serial == serial })?.key {
            await setOutputMode(modeID, for: liveID)
        }
    }

    // Insert/refresh a PairedController entry. Called after a successful
    // pairing exchange, after a "remember" adoption, and on every .ready of
    // an already-paired controller (to bump lastSeenAt for list sorting).
    private func recordPairing(for record: DeviceRecord) {
        guard let serial = record.serial else { return }
        pairedControllers[serial] = PairedController(
            serial: serial,
            productID: record.advertisement.productID,
            displayName: record.profile.name,
            lastSeenAt: Date(),
            peripheralUUID: record.id.raw,
            preferredOutputModeID: pairedControllers[serial]?.preferredOutputModeID
        )
        persistPairedControllers()
    }

    // Persist the new default for future devices, update this device's desired
    // mode, and republish its virtual HID if it is currently active.
    func setOutputMode(_ modeID: String, for id: DeviceID) async {
        guard devices[id]?.outputModeID != modeID else { return }
        devices[id]?.outputModeID = modeID
        UserDefaults.standard.set(modeID, forKey: Self.outputModeDefaultsKey)
        guard devices[id]?.virtualHID != nil else { return }
        await republishVirtualHID(for: id, modeID: modeID)
    }

    private func output(for record: DeviceRecord, modeID: String) -> any HIDOutputProfile {
        catalog.resolved(id: modeID).makeProfile(record.profile)
    }

    private func makeVirtualHID(for record: DeviceRecord, modeID: String) -> (VirtualHIDDevice, any HIDOutputSession)? {
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
        return (vhid, session)
    }

    // Always-on diagnostic log for output reports the host sends us.
    // Routes rumble through session.parseRumble → profile.encodeRumble →
    // transport.sendVibration, and forwards everything to session.handleSetReport
    // for handshake/subcommand replies.
    private func makeSetReportHandler(
        id deviceID: DeviceID,
        transport: (any Transport)?,
        profile: any ControllerProfile,
        rumbleRefresh: RumbleRefreshBox,
        session: any HIDOutputSession,
        settings: RumbleSettings
    ) -> VirtualHIDDevice.SetReportHandler {
        return { [weak self] device, type, id, data in
            let idStr = id.map { String(format: "0x%02X", $0.rawValue) } ?? "-"
            let hex = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            stderrLog("[hid] setReport type=\(type) id=\(idStr) len=\(data.count) [\(hex)]")

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
                // Xbox spoof sets 80 ms session-side; nil on either means defer.
                let interval = Self.mergeRefresh(profile.rumbleRefreshInterval, session.refreshInterval)
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

    private func hidTransport(for record: DeviceRecord) -> HIDDeviceTransport {
        // Always use .usb — BLE-transport virtual devices with output reports trigger
        // kIOReturnNoPower (IOServiceOpen:0xe00002e2). The transport hint is independent
        // of the real controller's connection and has no effect on input delivery.
        return .usb
    }

    private func republishVirtualHID(for id: DeviceID, modeID: String) async {
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
            devices[id]?.connectionState = .failed("Failed to create virtual HID device")
            return
        }
        await vhid.activate()
        devices[id]?.virtualHID = vhid
        devices[id]?.session = session
        devices[id]?.activeOutputModeID = modeID
    }

    deinit {
        consumerTask?.cancel()
        rateTask?.cancel()
        for task in dispatchTasks.values { task.cancel() }
        for cont in stateContinuations.values { cont.finish() }
        for box in rumbleRefreshBoxes.values { box.cancel() }
        for task in testRumbleTasks.values { task.cancel() }
    }

    func start() async {
        guard consumerTask == nil else { return }
        activity = ActivityToken(ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Controller input bridging"
        ))
        let transports = self.transports
        consumerTask = Task { [weak self] in
            await withDiscardingTaskGroup { group in
                for transport in transports {
                    group.addTask { [weak self] in
                        for await event in transport.events {
                            await self?.handle(event, kind: transport.kind)
                        }
                    }
                }
            }
        }
        rateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.snapshotRates()
            }
        }
    }

    private func snapshotRates() {
        for (id, count) in reportCounts {
            devices[id]?.reportRate = Double(count)
        }
        for id in devices.keys where reportCounts[id] == nil {
            devices[id]?.reportRate = 0
        }
        reportCounts.removeAll(keepingCapacity: true)
    }

    func toggleScan() async {
        let allMatchers: [TransportMatcher] = profiles.flatMap { p -> [TransportMatcher] in
            var ms: [TransportMatcher] = []
            if let bm = p.bleMatcher { ms.append(.ble(bm)) }
            if let um = p.usbMatcher { ms.append(.usb(um)) }
            return ms
        }
        if isScanning {
            for t in transports { await t.stopDiscovery() }
            isScanning = false
        } else {
            for t in transports { await t.startDiscovery(matchers: allMatchers) }
            isScanning = true
        }
    }

    private func startDispatch(for id: DeviceID) {
        dispatchTasks[id]?.cancel()
        stateContinuations[id]?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: ControllerState.self, bufferingPolicy: .bufferingNewest(1))
        stateContinuations[id] = continuation
        dispatchTasks[id] = Task { @MainActor [weak self] in
            for await state in stream {
                guard let self,
                      let record = self.devices[id],
                      let vhid = record.virtualHID,
                      let session = record.session else { continue }
                let report = await session.buildReport(state)
                try? await vhid.dispatch(report)
                let secondaries = await session.buildSecondaryReports(state)
                for secondary in secondaries {
                    try? await vhid.dispatch(secondary)
                }
            }
        }
    }

    private func handle(_ event: TransportEvent, kind: TransportKind) async {
        switch event {
        case .discovered(let id, let info):
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

        case .connected(let id):
            devices[id]?.connectionState = .connected

        case .ready(let id):
            devices[id]?.connectionState = .ready
            guard let record = devices[id] else { return }
            // Apply any per-serial preferred output mode before publishing the
            // virtual HID, so the user's choice (set while offline) is honored
            // without a tear-down/republish cycle.
            let startupModeID: String = {
                if let serial = record.serial,
                   let preferred = pairedControllers[serial]?.preferredOutputModeID {
                    return preferred
                }
                return record.outputModeID
            }()
            devices[id]?.outputModeID = startupModeID
            if let (vhid, session) = makeVirtualHID(for: record, modeID: startupModeID) {
                await vhid.activate()
                devices[id]?.virtualHID = vhid
                devices[id]?.session = session
                devices[id]?.activeOutputModeID = startupModeID
                startDispatch(for: id)
            } else {
                devices[id]?.connectionState = .failed("Failed to create virtual HID device")
            }
            // All .commandResponse events for this device's init have been
            // processed by now (they're yielded before .ready on the same
            // stream), so record.serial / onDeviceHostAddresses are populated
            // if the flash reads succeeded.
            if let updated = devices[id] {
                if let serial = updated.serial, pairedControllers[serial] != nil {
                    recordPairing(for: updated)  // refresh lastSeenAt
                }
                maybePromptForPairing(record: updated)
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
            dispatchTasks[id]?.cancel()
            dispatchTasks[id] = nil
            stateContinuations[id]?.finish()
            stateContinuations[id] = nil
            rumbleRefreshBoxes[id]?.cancel()
            rumbleRefreshBoxes[id] = nil
            testRumbleTasks[id]?.cancel()
            testRumbleTasks[id] = nil
            devices[id]?.connectionState = .disconnected
            devices[id]?.virtualHID = nil
            devices[id]?.session = nil
            devices[id]?.reportRate = 0
            reportCounts[id] = nil

        case .reportReceived(let id, let reportID, let data):
            guard let record = devices[id] else { return }
            lastReportSnapshot = ReportSnapshot(deviceID: id, data: data)
            reportCounts[id, default: 0] += 1
            let parsed: ControllerState?
            switch kind {
            case .ble: parsed = record.profile.parseBLEReport(data, calibration: record.calibration)
            case .usb: parsed = record.profile.parseUSBReport(data, reportID: reportID ?? 0, calibration: record.calibration)
            }
            if var state = parsed {
                if kind == .ble { state.rawBLEData = data }
                stateContinuations[id]?.yield(state)
            }

        case .error(_, let msg):
            stderrLog(msg)
        }
    }

    private func mergeMetadata(_ meta: ControllerMetadata, into id: DeviceID) {
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

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // Classic hexdump-style: `<OFFSET>: AA BB CC ... |ascii|`, 16 bytes per row.
    // baseOffset shifts the displayed offset so the column reflects an absolute address.
    private func hexdumpLines(_ data: Data, baseOffset: Int = 0) -> [String] {
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

    private func profile(forProductID pid: UInt16, kind: TransportKind) -> (any ControllerProfile)? {
        switch kind {
        case .ble: return profiles.first { $0.bleMatcher?.productID == pid }
        case .usb: return profiles.first { $0.usbMatcher?.productID == pid }
        }
    }

    private func transport(for kind: TransportKind) -> (any Transport)? {
        transports.first { $0.kind == kind }
    }

    nonisolated private static func mergeRefresh(_ a: Duration?, _ b: Duration?) -> Duration? {
        switch (a, b) {
        case (nil, nil): nil
        case (let x?, nil): x
        case (nil, let y?): y
        case (let x?, let y?): min(x, y)
        }
    }

    // Fire a canned rumble sequence on every ready, rumble-capable device. Each
    // device's prior test (if any) is cancelled; its rumble-refresh task is also
    // cancelled so a stale host-side resend can't interleave with the pattern.
    // Routes through the same encodeRumble + sendVibration path as host rumble,
    // so intensity/frequency/mapping all apply to the test as well.
    func playTestRumble(_ pattern: TestRumblePattern, on deviceID: DeviceID? = nil) {
        let targets: [(DeviceID, DeviceRecord)]
        if let deviceID, let record = devices[deviceID] {
            targets = [(deviceID, record)]
        } else {
            targets = devices.filter { $0.value.connectionState == .ready }.map { ($0.key, $0.value) }
        }
        for (id, record) in targets where record.connectionState == .ready {
            let probeSettings = rumbleSettings(for: record).snapshot()
            guard record.profile.encodeRumble(
                RumbleCommand(leftAmp: 1, rightAmp: 1), sequence: 0, settings: probeSettings
            ) != nil else { continue }
            startTestRumble(pattern, on: id, profile: record.profile, settings: rumbleSettings(for: record))
        }
    }

    private func startTestRumble(_ pattern: TestRumblePattern, on id: DeviceID, profile: any ControllerProfile, settings: RumbleSettings) {
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

    nonisolated private func runTestRumble(
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

enum TestRumblePattern: String, CaseIterable, Identifiable, Sendable {
    case both
    case left
    case right
    case alternate
    case ramp

    var id: String { rawValue }
    var label: String {
        switch self {
        case .both:      return "Both"
        case .left:      return "Left"
        case .right:     return "Right"
        case .alternate: return "Alternate"
        case .ramp:      return "Ramp"
        }
    }
}

// Holds the active Xbox rumble refresh task for one device. Lock-protected so the
// handler closure (any executor) and the main-actor coordinator can both cancel safely.
private final class RumbleRefreshBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var counter: UInt8 = 0

    func replace(with newTask: Task<Void, Never>) {
        lock.withLock {
            task?.cancel()
            task = newTask
        }
    }

    func cancel() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }

    // Monotonically increment the per-device transmit counter so successive
    // GC/Pro vibration payloads differ in their tid nibble and the controller
    // doesn't dedupe them. UInt8 wraparound is fine — only the low 4 bits matter.
    func nextCounter() -> UInt8 {
        lock.withLock {
            counter = counter &+ 1
            return counter
        }
    }
}

struct ReportSnapshot: Sendable {
    let deviceID: DeviceID
    let data: Data

    var hex: String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // Same hex, broken into 8-byte lines.
    var hexLines: String {
        let b = data.startIndex
        return stride(from: 0, to: data.count, by: 8).map { start in
            let end = min(start + 8, data.count)
            return data[(b + start)..<(b + end)]
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
        }.joined(separator: "\n")
    }
}
