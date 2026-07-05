import CoreHID
import Foundation
import Observation

@MainActor
@Observable
final class BridgeCoordinator {
    let profiles: [any ControllerProfile]
    let transports: [any Transport]
    let catalog: HIDOutputCatalog

    var devices: [DeviceID: DeviceRecord] = [:]
    var isScanning = false
    /// Non-nil when a transport is unavailable (e.g. Bluetooth is off).
    /// Cleared when the transport becomes available again.
    var transportUnavailableReason: String?
    /// Non-nil when virtual-controller output is blocked. Drives the
    /// permission banner in the main window and menu bar. Set and cleared
    /// only by observed VHID creation outcomes in makeVirtualHID — the TCC
    /// post-event check is NOT trusted as a standalone signal (it reports
    /// not-granted on machines where the Accessibility box is ticked and
    /// the VHID works fine); it only refines the failure message.
    var hidAccessIssue: HIDAccessIssue?

    // Per-peripheral auto-connect suppression after a VHID creation failure,
    // set by failVirtualHID and checked in the .discovered handler. Without
    // it the forced disconnect + re-advertisement reconnects in a tight loop.
    // Cleared wholesale when the app comes forward (the user granting the
    // permission necessarily foregrounds System Settings and then us).
    @ObservationIgnored
    var vhidFailureCooldowns: [DeviceID: ContinuousClock.Instant] = [:]

    func clearVHIDFailureCooldowns() {
        vhidFailureCooldowns.removeAll()
    }
    var pairingPrompt: PairingPrompt?
    // The device whose ProfilePickerSheet is currently being shown. Updated via
    // advanceAwaitingProfileSelection() — multiple controllers reaching .ready at
    // once each get a sheet in turn (next one shows when the current is resolved).
    var awaitingProfileSelectionID: DeviceID?
    // A single Joy-Con 2 whose partner hasn't connected yet. Drives the
    // JoyConPartnerSheet so the user knows to attach the other side. Cleared
    // when the partner arrives (pair forms) or the lone Joy-Con disconnects.
    var joyConWaitingForPartnerID: DeviceID?
    // The currently-active L+R Joy-Con pair, if both sides are .ready. Owns
    // the merged VirtualHIDDevice + session + last-known per-side state. Not
    // @ObservationIgnored: listEntries and the row UI depend on the slot's
    // nil/non-nil transition. (Mutations of the pair instance itself — e.g.
    // assigning .virtualHID — aren't observed; the activation flow only
    // installs the pair after the VHID is built, so the slot's non-nil state
    // implies a live VHID.)
    var joyConPair: JoyConPair?
    // Mirrors joyConPair?.virtualHID != nil for the UI's activity indicator.
    // Class-instance reads aren't observed; we set this flag explicitly inside
    // activateJoyConPair / tearDownJoyConPair so the row redraws when the
    // merged VHID comes up or goes down.
    var joyConPairVHIDActive: Bool = false
    // Synthetic profile used for the merged Joy-Con pair's output identity.
    let joyConPairProfile = JoyConPairProfile()

    func advanceAwaitingProfileSelection() {
        awaitingProfileSelectionID = devices.first { $0.value.awaitingProfileSelection }?.key
    }

    static let outputModeDefaultsKey = "WaveBird.hidOutputMode"
    private static let knownControllersKey = "WaveBird.knownControllers"
    let defaultOutputModeID: String

    // Controllers we've previously paired with on this host. Persisted as
    // JSON in UserDefaults under knownControllersKey. Mutating callers must
    // route through persistKnownControllers() so disk + memory stay in sync.
    var knownControllers: [String: KnownController]

    // Per-session "user said not now" set, keyed by serial. Prevents re-prompting
    // on reconnect within the same launch. Cleared at process exit so the user
    // gets another chance next time they open WaveBird.
    @ObservationIgnored
    var declinedPairingThisSession: Set<String> = []

    // Joy-Cons whose serials the user split off the merged pair this session.
    // handleJoyConReady refuses to auto-form a pair or raise the
    // waiting-for-partner sheet for any side present in this set. Cleared at
    // process exit; the user can re-pair by restarting the app.
    @ObservationIgnored
    var splitJoyConSerialsThisSession: Set<String> = []

    // Holds the profile mode chosen in ProfilePickerSheet for controllers whose
    // KnownController entry doesn't exist yet at selection time. Consumed by
    // recordController so the preference survives the pairing exchange.
    @ObservationIgnored
    var pendingProfileModeIDs: [String: String] = [:]

    @ObservationIgnored
    private var consumerTask: Task<Void, Never>?


    // Per-device latest-state channels. The consumer yields parsed states here
    // (non-blocking); a separate dispatch task picks up the newest and sends it
    // to the virtual HID device. bufferingNewest(1) discards stale states if the
    // dispatch task falls behind, so we always forward the most recent input.
    @ObservationIgnored
    var stateContinuations: [DeviceID: AsyncStream<RawReport>.Continuation] = [:]

    @ObservationIgnored
    var dispatchTasks: [DeviceID: Task<Void, Never>] = [:]

    @ObservationIgnored
    var rumbleRefreshBoxes: [DeviceID: RumbleRefreshBox] = [:]

    @ObservationIgnored
    var testRumbleTasks: [DeviceID: Task<Void, Never>] = [:]

    // Per-device timer armed on .connecting; fires if .ready isn't reached in
    // time, then force-disconnects via the transport. Cancelled on .ready and
    // on .disconnected. Covers both the BLE link-up phase and the init/pair
    // handshake window — anything stuck pre-.ready gets dropped.
    @ObservationIgnored
    var connectingTimeoutTasks: [DeviceID: Task<Void, Never>] = [:]
    static let connectingTimeout: Duration = .seconds(10)

    // Tracks per-device last meaningful input for the idle-disconnect sweep.
    // Fed from the dispatch tasks; read by runIdleSweep. See +Power.swift.
    let activityTracker = ActivityTracker()

    @ObservationIgnored
    var idleSweepTask: Task<Void, Never>?

    // Per-controller tunable rumble settings, keyed by NS2 serial. Created on
    // first access, reused, persisted to UserDefaults by serial so each physical
    // controller carries its own tuning across re-pairings. The encoder reads via
    // passed-in snapshots, so the BLE write queue never touches @MainActor state.
    var rumbleSettingsBySerial: [String: RumbleSettings] = [:]

    func rumbleSettings(for record: DeviceRecord) -> RumbleSettings {
        rumbleSettings(forSerial: settingsKey(for: record), productID: record.advertisement.productID)
    }

    func rumbleSettings(forSerial serial: String, productID: UInt16) -> RumbleSettings {
        if let existing = rumbleSettingsBySerial[serial] { return existing }
        let made = RumbleSettings(serial: serial, productID: productID)
        rumbleSettingsBySerial[serial] = made
        return made
    }

    // RumbleSettings instance the merged Joy-Con VHID and its detail card both
    // write through. Encoders for L and R read tuning from this single
    // instance while the pair is active; per-side rumble instances stay
    // untouched so solo use after a split keeps each Joy-Con's own profile.
    func pairRumbleSettings() -> RumbleSettings {
        rumbleSettings(forSerial: joyConPairSerial() ?? "joycon-pair",
                       productID: joyConPairProfile.hidProductID)
    }

    // Per-controller axis configuration (Y-axis inversion). Same per-serial
    // model as rumble. The dispatch task reads a snapshot off-main, so it never
    // touches @MainActor state.
    var axisSettingsBySerial: [String: AxisSettings] = [:]

    func axisSettings(for record: DeviceRecord) -> AxisSettings {
        axisSettings(forSerial: settingsKey(for: record))
    }

    func axisSettings(forSerial serial: String) -> AxisSettings {
        if let existing = axisSettingsBySerial[serial] { return existing }
        let made = AxisSettings(serial: serial)
        axisSettingsBySerial[serial] = made
        return made
    }

    func pairAxisSettings() -> AxisSettings {
        axisSettings(forSerial: joyConPairSerial() ?? "joycon-pair")
    }

    // Per-controller Xbox advanced options (GIP 0x20 stream on/off). Same
    // per-serial model; only the Xbox output mode reads it, sampled off-main by
    // the dispatch task so a live toggle applies without a republish.
    var xboxOutputSettingsBySerial: [String: XboxOutputSettings] = [:]

    func xboxOutputSettings(for record: DeviceRecord) -> XboxOutputSettings {
        xboxOutputSettings(forSerial: settingsKey(for: record))
    }

    func xboxOutputSettings(forSerial serial: String) -> XboxOutputSettings {
        if let existing = xboxOutputSettingsBySerial[serial] { return existing }
        let made = XboxOutputSettings(serial: serial)
        xboxOutputSettingsBySerial[serial] = made
        return made
    }

    // Settings key for a live record: its serial, or a PID-derived placeholder
    // when the serial flash read hasn't landed (degenerate — settings for an
    // un-serialized controller don't meaningfully persist, but the accessor
    // still needs a stable key).
    private func settingsKey(for record: DeviceRecord) -> String {
        record.serial ?? String(format: "pid-0x%04X", record.advertisement.productID)
    }

    // Combined key for the active Joy-Con pair: "Lserial+Rserial" (L first).
    // nil if either side's serial isn't known yet.
    func joyConPairSerial() -> String? {
        guard let pair = joyConPair,
              let left = devices[pair.leftID]?.serial,
              let right = devices[pair.rightID]?.serial else { return nil }
        return "\(left)+\(right)"
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
        self.defaultOutputModeID = stored.flatMap { catalog.entry(id: $0)?.id } ?? catalog.firstAllowListedID
        self.knownControllers = Self.loadKnownControllers()
    }

    private static func loadKnownControllers() -> [String: KnownController] {
        guard let data = UserDefaults.standard.data(forKey: knownControllersKey),
              let decoded = try? JSONDecoder().decode([String: KnownController].self, from: data)
        else { return [:] }
        return decoded
    }

    func persistKnownControllers() {
        guard let encoded = try? JSONEncoder().encode(knownControllers) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.knownControllersKey)
    }

// Live entries first (connected before not-connected, then by serial for
    // stability), then paired-offline entries (sorted by lastSeenAt desc). A
    // live entry whose serial matches a paired record is decorated with that
    // record; offline-only entries appear when a paired controller isn't
    // currently advertising.
    //
    // Joy-Con pair: when joyConPair is active, R's row is suppressed and L's
    // row stands in for the pair. The UI reads activeJoyConPair to render the
    // combined name + draw the VHID-active accent off the pair's virtualHID.
    var listEntries: [ListEntry] {
        var claimedSerials: Set<String> = []
        let liveSorted = devices.values.sorted { lhs, rhs in
            let lr = Self.connectionRank(lhs.connectionState)
            let rr = Self.connectionRank(rhs.connectionState)
            if lr != rr { return lr < rr }
            return (lhs.serial ?? "") < (rhs.serial ?? "")
        }
        var entries: [ListEntry] = []
        for record in liveSorted {
            if let pair = joyConPair, pair.rightID == record.id {
                // R is folded into the L-keyed pair row; claim its serial
                // so the offline sweep doesn't surface it as Not Connected.
                if let s = record.serial { claimedSerials.insert(s) }
                continue
            }
            let paired: KnownController? = record.serial.flatMap { knownControllers[$0] }
                ?? knownControllers.values.first { $0.peripheralUUID == record.id.raw }
            if let p = paired { claimedSerials.insert(p.serial) }
            let id = paired?.serial ?? record.serial ?? record.id.raw.uuidString
            // Strip the live per-connection objects so the view layer can't pin
            // the VirtualHIDDevice (and thus the CoreHID system device) alive.
            var viewRecord = record
            viewRecord.virtualHID = nil
            viewRecord.session = nil
            entries.append(ListEntry(id: id, live: viewRecord, vhidActive: record.virtualHID != nil, paired: paired))
        }
        let offline = knownControllers.values
            .filter { !claimedSerials.contains($0.serial) }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
        for paired in offline {
            entries.append(ListEntry(id: paired.serial, live: nil, vhidActive: false, paired: paired))
        }
        return entries
    }

    // List sort priority: actively connected first, then in-progress, then
    // not-connected — so a disconnected live record never sits above a
    // connected one.
    private static func connectionRank(_ state: DeviceConnectionState) -> Int {
        switch state {
        case .ready, .connected:       0
        case .connecting, .discovered: 1
        case .disconnected, .failed:   2
        }
    }

    // Exposed for the UI: when non-nil and the row's record is the pair's L,
    // render "Joy-Con 2 (L + R)" and draw the active VHID indicator off this
    // pair's virtualHID instead of the per-record one.
    var activeJoyConPair: JoyConPair? { joyConPair }

    // Name to show for a list/menu entry. The L side standing in for an active
    // Joy-Con pair shows the merged pair name; everything else uses the entry's
    // own name. Single source of truth so ContentView and the menu bar agree.
    func listDisplayName(for entry: ListEntry) -> String {
        if let pair = joyConPair, pair.leftID == entry.live?.id {
            return "Joy-Con 2 Pair"
        }
        return entry.displayName
    }

    // True while any user-facing prompt is on screen. ContentView watches
    // this to flip the activation policy to .regular in accessory mode so
    // the Window scene can host the prompt sheet, and restore the user's
    // hide-dock-icon preference once everything is closed.
    var hasActivePrompt: Bool {
        pairingPrompt != nil
            || awaitingProfileSelectionID != nil
            || joyConWaitingForPartnerID != nil
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
        knownControllers[serial]?.isPaired == true
    }

    // Forget a serial locally. Disconnects the device first if it's currently
    // live so the forget visibly takes effect (no lingering Ready row). Re-shows
    // the pairing prompt on the controller's next .ready. Does not currently
    // send 0x03/0x08 ("Clear pairing info") to the controller — that would wipe
    // the on-device LTK entirely. Add the device-side clear later if the
    // local-only forget proves confusing.
    func forgetController(serial: String) async {
        if let liveID = devices.first(where: { $0.value.serial == serial })?.key {
            await disconnectController(liveID)
            devices.removeValue(forKey: liveID)
        }
        guard knownControllers.removeValue(forKey: serial) != nil else { return }
        persistKnownControllers()
        declinedPairingThisSession.remove(serial)
    }

    deinit {
        consumerTask?.cancel()
        idleSweepTask?.cancel()
        for task in dispatchTasks.values { task.cancel() }
        for cont in stateContinuations.values { cont.finish() }
        for box in rumbleRefreshBoxes.values { box.cancel() }
        for task in testRumbleTasks.values { task.cancel() }
        for task in connectingTimeoutTasks.values { task.cancel() }
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
        idleSweepTask = Task { [weak self] in await self?.runIdleSweep() }
    }

    func toggleScan() async {
        if isScanning { await stopScanning() } else { await startScanning() }
    }

    // Every profile's matchers, flattened across transports. Used by every path
    // that (re)starts discovery — toggleScan, resumeAfterWake.
    func allScanMatchers() -> [TransportMatcher] {
        profiles.flatMap { p -> [TransportMatcher] in
            var ms: [TransportMatcher] = []
            if let bm = p.bleMatcher { ms.append(.ble(bm)) }
            if let um = p.usbMatcher { ms.append(.usb(um)) }
            return ms
        }
    }

    func startScanning() async {
        guard !isScanning else { return }
        let allMatchers = allScanMatchers()
        for t in transports { await t.startDiscovery(matchers: allMatchers) }
        isScanning = true
    }

    func stopScanning() async {
        guard isScanning else { return }
        for t in transports { await t.stopDiscovery() }
        isScanning = false
    }

    func transport(for kind: TransportKind) -> (any Transport)? {
        transports.first { $0.kind == kind }
    }

    nonisolated static func mergeRefresh(_ a: Duration?, _ b: Duration?) -> Duration? {
        switch (a, b) {
        case (nil, nil): nil
        case (let x?, nil): x
        case (nil, let y?): y
        case (let x?, let y?): min(x, y)
        }
    }

}

