import Foundation
import IOKit
import IOUSBHost

// Xbox USB transport: wired GIP controllers — the original non-Bluetooth
// Xbox One pads (1537/1697) AND every Xbox-licensed third-party pad that
// speaks GIP over the same vendor interface (GameSir, PowerA, 8BitDo, Hori,
// PDP, …). Identification is by interface (class 0xFF, subclass 0x47,
// protocol 0xD0, interrupt IN 0x81 / OUT 0x01), not by VID/PID — the
// identify handshake confirms it's a gamepad.
//
// This transport owns: device discovery (IOKit hot-plug), the GIP handshake
// (announce → identify → power-on — the probe sequence the controller
// expects), chunk reassembly + per-chunk ACKs, and the conversion of the GIP
// input stream into TransportEvent.reportReceived payloads that
// XboxOneProfile.parseUSBReport understands.
//
// It adapts to WaveBird's `Transport` protocol with NO core changes: the
// coordinator's discover → connect → ready → reportReceived plumbing (and the
// rumble path session.parseRumble → profile.encodeRumble →
// transport.sendVibration) works as-is because it was already transport-typed.
//
// API NOTES (verified against the macOS SDK / Apple docs):
//   - IOUSBHost objects are created with
//     IOUSBHostDevice/Interface(__ioService:options:queue:interestHandler:)
//     — there is no init(service:) and no open()/close(). Dropping the last
//     reference releases the claim.
//   - Pipe I/O is enqueueIORequest(with:completionTimeout:completionHandler:)
//     with an NSMutableData buffer. For INTERRUPT pipes the completion
//     timeout MUST be 0 — "Must be 0 for interrupt pipes and streams";
//     Apple's IOUSBLib docs spell out the failure mode: "Returns
//     kIOReturnBadArgument if timeout values are specified for an interrupt
//     pipe." (That is the -536870206 / "Unable to enqueue IO." error the
//     original wired build hit on BOTH pipes.) There is no timeout-based
//     wind-down for interrupt reads: a cancelled session is released with
//     abortWithOption:error: (also ObjC-only, dispatched via the runtime).
//   - selectAlternateSetting(_:) must run BEFORE copyPipe — it aborts all
//     pending I/O and invalidates any pipe objects created before it.
//   - IORegistryEntryCreateCFProperty takes 4 arguments and RETURNS the value
//     as an Unmanaged reference (takeRetainedValue()).
//   - Discovery uses IOServiceAddMatchingNotification + the main run loop,
//     but with an "IOProviderClass"-ONLY match dictionary: property-level
//     matching (bInterfaceClass etc.) never matched the pad's interfaces
//     from user space on macOS 15, so the GIP class/subclass/protocol filter
//     runs in code on every delivered IOUSBHostInterface instead.

actor XboxUSBTransport: Transport {
    nonisolated let kind: TransportKind = .usb
    nonisolated let events: AsyncStream<TransportEvent>

    // IPs for IOUSBHost completions (interest handling + enqueueIORequest).
    private let queue: DispatchQueue
    private let continuation: AsyncStream<TransportEvent>.Continuation
    // OpaquePointer is not Sendable, and deinit is nonisolated — the port is
    // created once in init and only touched by startDiscovery/deinit, so
    // nonisolated(unsafe) is the correct opt-out.
    nonisolated(unsafe) private let notifyPort = IONotificationPortCreate(kIOMainPortDefault)
    private var notification: io_iterator_t = 0           // interface match notification handle
    private var deviceNotification: io_iterator_t = 0     // device match notification handle
    private var grabInFlight = false                       // one bounded grab chain at a time
    private var pendingServices: [UUID: io_service_t] = [:]
    // Stable transport-level DeviceIDs (derived from the pad's USB locationID)
    // → the CURRENT registry entry ID. The entry ID changes on every
    // enumeration (blink loop + replug), so the inverse lookup can no longer
    // be decoded from the UUID — it is recorded each time a device is offered.
    private var deviceEntryCache: [UUID: UInt64] = [:]
    // Stable identity key (serial hash or locationID+productID) per stable
    // DeviceID — lets resolveLiveInterface re-find the pad even after a
    // re-enumeration changed its registry entry ID.
    private var stableKeyByID: [UUID: UInt64] = [:]

    /// The stable 64-bit identity key for a pad (see identifier(forDevice:info:)).
    /// Returns nil when only the unstable entry ID is available.
    private func stableKey(for info: DeviceInfo) -> UInt64? {
        if let serial = info.serialString, !serial.isEmpty {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in serial.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
            return hash
        }
        if let loc = info.locationID {
            return (UInt64(loc) << 16) | UInt64(info.productID & 0xFFFF)
        }
        return nil
    }
    private var claimedDevices: Set<UInt64> = []           // device entry IDs already published
    // Microsoft pads only stop their blinking re-enumeration loop once the
    // GIP data INTERFACE is claimed (observed: a device-only claim does NOT
    // stop it; a WebUSB site's interface claim does). We claim the interface
    // the instant it publishes and hold it here until connect().
    private var heldInterfaces: [UInt64: IOUSBHostInterface] = [:]
    // Secondary hold: the pad DEVICE, opened at publish time. Some stacks
    // only expose a device's interfaces once a user client holds the device
    // handle — Chrome's WebUSB open() does this before claimInterface. Kept
    // until connect() reuses it, so we never fight ourselves for access.
    private var heldDevices: [UInt64: IOUSBHostDevice] = [:]
    private var sessions: [UUID: Session] = [:]
    private var isDiscovering = false
    // Vendors known to expose the GIP vendor interface on their wired data
    // interface — the licensed "Designed for Xbox" controller makers. The
    // GIP class/subclass filter in process() stays the REAL gate (plus the
    // identify handshake); this set only decides whether we proactively
    // hold + configure the device while it blinks unclaimed.
    // Any other vendor's GIP interface is still caught by the interface
    // notification path. Wrong entries are harmless (no GIP children → no
    // claim).
    private nonisolated let xboxGIPVendors: Set<UInt16> = [
        0x045E, // Microsoft
        0x0738, // Mad Catz
        0x0E6F, // PDP
        0x0F0D, // Hori
        0x1532, // Razer
        0x24C6, // PowerA
        0x20D6, // BDA
        0x044F, // Thrustmaster
        0x10F5, // Turtle Beach
        0x2E24, // Hyperkin
        0x3285, // Nacon
        0x2DC8, // 8BitDo
        0x2E95, // SCUF
        0x3537, // GameSir
        0x11C1, // (vendor unknown — listed in the reference table, keep)
        0x294B, // Snakebyte
        0x2C16, // Priferential
        0x0B05, // ASUS
    ]

    // MARK: - session state

    final class Session: @unchecked Sendable {
        let id: DeviceID
        var device: IOUSBHostDevice?
        var interface: IOUSBHostInterface?
        var pipeIn: IOUSBHostPipe?
        var pipeOut: IOUSBHostPipe?
        var readTask: Task<Void, Never>?
        var parser = GIPStreamParser()
        var dataSequence: UInt8 = 0

        var address = Data()            // 6-byte BT address from ANNOUNCE
        var productID: UInt16 = 0
        var firmware: (major: UInt16, minor: UInt16)? = nil
        var lastInput: Data? = nil      // most recent full input payload
        var guideDown = false           // Guide (0x07 virtual key) state
        var supportsShare = false       // share GUID in identify info-block
        var supportsDLI = false         // DLI counter GUID in identify info-block
        var portToken: String? = nil    // stable per-port token (locationID)

        init(id: DeviceID) { self.id = id }

        var serial: String {
            // Stable identity from the announce address: the pad publishes
            // its wireless MAC here even when wired.
            guard address.count == 6 else {
                // Wired pads never announce (no wireless MAC), so the serial
                // falls back to a per-PORT identity: the USB locationID is
                // constant for the same physical port across replugs (unlike
                // the registry entry ID), so settings/known-controller prefs
                // follow the pad+port.
                if let port = portToken { return "xbox-usb-" + port }
                return "xbox-usb"
            }
            return "xbox-" + address.map { String(format: "%02x", $0) }.joined()
        }

        func nextSequence() -> UInt8 {
            // Sequence numbers increment per packet; zero is never used.
            var seq = dataSequence
            seq &+= 1
            if seq == 0 { seq = 1 }
            dataSequence = seq
            return seq
        }
    }

    init() {
        queue = DispatchQueue(label: "WaveBird.XboxUSB", qos: .userInteractive)
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    deinit {
        IONotificationPortDestroy(notifyPort)
    }

    // MARK: - Transport protocol

    func startDiscovery(matchers: [TransportMatcher]) async {
        guard !isDiscovering else { return }
        isDiscovering = true


        let selfRef = Unmanaged.passUnretained(self).toOpaque()

        // Notification 1 — DEVICES: the unclaimed pad power-cycles its USB
        // enumeration (the blinking-LED loop), so device publishes are the
        // clock of that loop. We log every one and, for Microsoft pads,
        // immediately race to grab the GIP interfaces of that cycle.
        var deviceIterator: io_iterator_t = 0
        var kr = IOServiceAddMatchingNotification(
            notifyPort, kIOPublishNotification,
            ["IOProviderClass": "IOUSBHostDevice"] as CFDictionary,
            { refcon, it in
                guard let refcon else { return }
                Unmanaged<XboxUSBTransport>.fromOpaque(refcon).takeUnretainedValue().devicesPublished(it)
            },
            selfRef, &deviceIterator
        )
        guard kr == KERN_SUCCESS else {
            isDiscovering = false

            yield(.availability(reason: "USB discovery unavailable (kern_return 0x\(String(kr, radix: 16)))"))
            return
        }
        deviceNotification = deviceIterator

        // Notification 2 — INTERFACES: the actual claim target. Match every
        // IOUSBHostInterface and filter the GIP signature in code
        // (property-level matching never worked from user space).
        var iterator: io_iterator_t = 0
        kr = IOServiceAddMatchingNotification(
            notifyPort, kIOPublishNotification,
            ["IOProviderClass": "IOUSBHostInterface"] as CFDictionary,
            { refcon, it in
                guard let refcon else { return }
                Unmanaged<XboxUSBTransport>.fromOpaque(refcon).takeUnretainedValue().interfacesPublished(it)
            },
            selfRef, &iterator
        )
        guard kr == KERN_SUCCESS else {
            isDiscovering = false

            yield(.availability(reason: "USB discovery unavailable (kern_return 0x\(String(kr, radix: 16)))"))
            return
        }
        notification = iterator


        // Deliver the notification through the main run loop — without this
        // the port's mach source is never serviced and no events arrive.
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
            .commonModes
        )

        devicesPublished(deviceIterator)     // already-present devices
        interfacesPublished(iterator)        // already-present interfaces
        _ = grabInterfaces()                 // initial pass, covers everything present now
    }

    func stopDiscovery() async {
        guard isDiscovering else { return }
        isDiscovering = false
        if notification != 0 {
            IOObjectRelease(notification)
            notification = 0
        }
        if deviceNotification != 0 {
            IOObjectRelease(deviceNotification)
            deviceNotification = 0
        }
    }

    func connect(_ id: DeviceID) async throws {
        guard pendingServices[id.raw] != nil else {
            throw NSError(domain: "XboxUSB", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No pending USB service for \(id.raw)"])
        }
        // A rival (WebUSB/browser tab, another app) may still hold the pad;
        // retry a couple of times before giving up — once the rival releases,
        // we win the exclusive open and the pad goes solid under OUR claim.
        var lastError: Error = NSError(domain: "XboxUSB", code: 0,
                                       userInfo: [NSLocalizedDescriptionKey: "unknown"])
        for attempt in 1...3 {
            // Re-resolve on EVERY attempt: the pad re-enumerates on its own
            // clock (blink loop) and configure(value: 1) re-publishes the
            // interface nubs, so the offered io_service_t can be a dead nub
            // ("Unable to enqueue IO."). Same nub = no-op.
            resolveLiveInterface(for: id)
            let session = Session(id: id)
            // Reuse the held interface claim (if any): opening the interface
            // twice fails with "exclusive access" — our own claim would
            // block us.
            if session.interface == nil {
                if let held = heldInterfaces.removeValue(forKey: deviceEntryID(from: id)) {
                    session.interface = held

                }
            }
            // Reuse the held device claim too (opening the same device twice
            // fails with "exclusive access" — our own hold would block us).
            if session.device == nil, let held = heldDevices.removeValue(forKey: deviceEntryID(from: id)) {
                session.device = held

            }
            do {
                try await open(session: session, interfaceService: pendingServices[id.raw]!)
                if let service = pendingServices.removeValue(forKey: id.raw) {
                    IOObjectRelease(service)
                }
                sessions[id.raw] = session
                yield(.connected(id))

                startReadLoop(session)
                // KICK the pad: the controller stays silent until the host
                // speaks (Windows sends power-on immediately; a pad that
                // never announces first needs the host to break the silence).
                // power-on wakes it, identify asks for its info block. Both
                // are idempotent; handlers re-send on real replies.
                do {
                    try await write(session, GIPOutbound.powerOn(clientID: clientID(session), sequence: session.nextSequence()))
                    try await write(session, GIPOutbound.identify(clientID: clientID(session), sequence: session.nextSequence()))
                } catch {

                }
                return
            } catch {
                lastError = error

                yield(.disconnected(id, .error(String(describing: error))))
                if attempt < 3 {
                    try? await Task.sleep(for: .milliseconds(800))
                }
            }
        }
        if let service = pendingServices.removeValue(forKey: id.raw) {
            IOObjectRelease(service)
        }
        claimedDevices.remove(deviceEntryID(from: id))   // allow re-discovery later
        throw lastError
    }

    func disconnect(_ id: DeviceID) async {
        guard let session = sessions.removeValue(forKey: id.raw) else { return }
        session.readTask?.cancel()
        session.readTask = nil
        close(session)
        claimedDevices.remove(deviceEntryID(from: id))   // replugs are re-offered
        yield(.disconnected(id, .userInitiated))
    }

    func send(_ payload: Data, reportID: UInt8?, to id: DeviceID) async throws {
        guard let session = sessions[id.raw] else { return }
        // Generic send is unused by the coordinator today; keep it thin.
        try await write(session, payload)
    }

    func sendVibration(_ payload: Data, to id: DeviceID) async throws {
        guard let session = sessions[id.raw] else { return }
        let frame = GIPOutbound.rumble(clientID: clientID(session),
                                       sequence: session.nextSequence(),
                                       payload: payload)
        try await write(session, frame)
    }
}

// MARK: - discovery plumbing

extension XboxUSBTransport {
    /// Run-loop callback entry: the pad enumerates and drops rapidly while
    /// unclaimed (the blinking LED loop). We log the VISIBLE CLOCK of that
    /// loop — every USB device publish — and when a Microsoft pad appears we
    /// immediately race to grab its GIP interfaces.
    nonisolated private func devicesPublished(_ iterator: io_iterator_t) {
        var batch: [io_service_t] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            batch.append(service)
            service = IOIteratorNext(iterator)
        }
        guard !batch.isEmpty else { return }
        Task { [weak self] in
            guard let self else {
                for svc in batch { IOObjectRelease(svc) }
                return
            }
            await self.handleDevices(batch)
        }
    }

    private func handleDevices(_ services: [io_service_t]) {
        var sawPad = false
        for service in services {
            let entry = registryEntryID(service)
            let vendor = registryUInt16(service, "idVendor") ?? 0
            let product = registryUInt16(service, "idProduct") ?? 0
            let name = registryString(service, "USB Product Name") ?? "?"
            let config = registryUInt8(service, "bConfigurationValue")

            // Wired GIP pads: Microsoft + every licensed manufacturer
            // (8BitDo, PDP, PowerA, GameSir, …). All speak GIP on the
            // class-0xFF/0x47 vendor-interface pair; the identify handshake
            // confirms gamepad-ness before the pad is offered.
            if xboxGIPVendors.contains(vendor) {
                sawPad = true
                // HOLD THE DEVICE OPEN first (the watchdog kills unclaimed
                // pads; some stacks only expose interfaces once a client
                // holds the device — Chrome's WebUSB open() does this before
                // claimInterface). Best effort: failure must not stop us.
                if heldDevices.count > 16 {
                    heldDevices.removeAll()
                }
                if heldDevices[entry] == nil {
                    do {
                        let dev = try IOUSBHostDevice(__ioService: service, options: [], queue: queue, interestHandler: nil)
                        heldDevices[entry] = dev

                        // THE WebUSB trick: select the device's configuration.
                        // IOUSBHost's own docs say interfaces are only created
                        // when the device is configured, and macOS leaves
                        // driverless vendor devices unconfigured — which is why
                        // the pad publishes no interfaces (nobody ever sent
                        // SET_CONFIGURATION) and why Chrome's
                        // selectConfiguration(1) makes it go solid.
                        configureDevice(dev)
                    } catch {

                    }
                }
                // THE critical move: claim within the SAME enumeration cycle.
                // Every millisecond counts against the watchdog — enumerate
                // the pad's child interfaces right now, instead of waiting
                // for the (never-reliable-while-blinking) IOUSBHostInterface
                // notification or a delayed sweep.
                let children = gipChildren(of: service)
                if children.isEmpty {

                } else {

                    process(children)
                }
            }
            IOObjectRelease(service)
        }
        if sawPad {
            Task { await self.grabWithRetries() }
        }
    }

    /// Sends SET_CONFIGURATION(1) to the pad — the WebUSB trick that makes
    /// the pad stop blinking and publish its interfaces.
    ///
    /// The Swift interface of IOUSBHostDevice does NOT expose
    /// configureWithValue:matchInterfaces:error: (Apple documents that
    /// method for Objective-C only; there is no Swift variant, which is why
    /// `dev.setConfiguration(...)` fails to compile). The method is real,
    /// public and present since macOS 10.15 (verified against the current
    /// SDK docs), so we invoke it via the Objective-C runtime: compile-safe,
    /// no type-system lookup, and both variants are tried.
    private func configureDevice(_ dev: IOUSBHostDevice) {
        // The real header (IOUSBHostDevice.h): the 3-arg variant is
        // NS_REFINED_FOR_SWIFT (imported as __configureWithValue(_:matchInterfaces:))
        // and the 2-arg variant is NS_SWIFT_UNAVAILABLE. Neither is reachable by
        // its ObjC name from Swift, but both remain public ObjC methods, so we
        // invoke them through the runtime. The error pointer is passed as NULL
        // (UnsafeMutableRawPointer? keeps the @convention(c) signature
        // C-compatible and compile-safe); success/failure is what we log.
        typealias ConfigureIMP = @convention(c) (AnyObject, Selector, UInt, Bool, UnsafeMutableRawPointer?) -> Bool
        let selector = NSSelectorFromString("configureWithValue:matchInterfaces:error:")
        if let imp = dev.method(for: selector) {
            let fn = unsafeBitCast(imp, to: ConfigureIMP.self)
            if fn(dev, selector, 1, true, nil) {

            } else {

            }
            return
        }
        // Fallback: the older two-argument variant (also public ObjC; Swift
        // marks it NS_SWIFT_UNAVAILABLE but the ObjC runtime still has it).
        // matchInterfaces defaults to YES for this variant.
        typealias ConfigureIMP2 = @convention(c) (AnyObject, Selector, UInt, UnsafeMutableRawPointer?) -> Bool
        let fallbackSelector = NSSelectorFromString("configureWithValue:error:")
        if let imp = dev.method(for: fallbackSelector) {
            let fn = unsafeBitCast(imp, to: ConfigureIMP2.self)
            if fn(dev, fallbackSelector, 1, nil) {

            } else {

            }
            return
        }

    }

    /// Child interfaces of a device, filtered to GIP (class 0xFF, subclass
    /// 0x47). Called synchronously at device-publish time.
    private func gipChildren(of deviceService: io_service_t) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var gip: [io_service_t] = []
        var child = IOIteratorNext(iterator)
        while child != 0 {
            let cls = registryUInt8(child, "bInterfaceClass")
            let sub = registryUInt8(child, "bInterfaceSubClass")
            if cls == 0xFF, sub == 0x47 {
                gip.append(child)
            } else {
                IOObjectRelease(child)
            }
            child = IOIteratorNext(iterator)
        }
        return gip
    }

    /// Run-loop callback entry for interface publishes.
    nonisolated private func interfacesPublished(_ iterator: io_iterator_t) {
        var batch: [io_service_t] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            batch.append(service)
            service = IOIteratorNext(iterator)
        }
        guard !batch.isEmpty else { return }
        Task { [weak self] in
            guard let self else {
                for svc in batch { IOObjectRelease(svc) }
                return
            }
            await self.handleInterfaces(batch)
        }
    }

    /// One-shot re-check for interfaces whose registry properties were not
    /// readable at publish time (can happen on the very first bump of a
    /// fresh enumeration). Never re-schedules itself.
    private func recheckInterface(_ service: io_service_t) {
        let cls = registryUInt8(service, "bInterfaceClass")
        let sub = registryUInt8(service, "bInterfaceSubClass")
        if cls == 0xFF, sub == 0x47 {
            process([service])
        } else {
            IOObjectRelease(service)
        }
    }

    private func handleInterfaces(_ services: [io_service_t]) {
        // Log EVERY interface publish — this is the diagnostic that tells us
        // whether the pad exposes its GIP interfaces at all while unclaimed,
        // and with which signature. GIP candidates (class 0xFF, subclass
        // 0x47) go to process(); unreadable ones are re-checked once (the
        // registry may not have the properties yet on the very first bump).
        var keep: [io_service_t] = []
        for service in services {
            let entry = registryEntryID(service)
            let vendor = registryUInt16(service, "idVendor")
                ?? registryUInt16(parentOf: service, "idVendor") ?? 0
            let product = registryUInt16(service, "idProduct")
                ?? registryUInt16(parentOf: service, "idProduct") ?? 0
            let cls = registryUInt8(service, "bInterfaceClass")
            let sub = registryUInt8(service, "bInterfaceSubClass")
            let proto = registryUInt8(service, "bInterfaceProtocol")
            if cls == 0xFF, sub == 0x47 {

                keep.append(service)
            } else if cls == nil, sub == nil, proto == nil {

                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard let self else {
                        IOObjectRelease(service)
                        return
                    }
                    await self.recheckInterface(service)
                }
            } else {

                IOObjectRelease(service)
            }
        }
        guard !keep.isEmpty else { return }
        process(keep)
    }

    /// One-shot enumeration of ALL present USB interfaces; filters GIP in
    /// code. Returns true when a new pad was claimed/offered.
    private func grabInterfaces() -> Bool {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            ["IOProviderClass": "IOUSBHostInterface"] as CFDictionary,
            &iterator
        )
        guard kr == KERN_SUCCESS else {

            return false
        }
        defer { IOObjectRelease(iterator) }
        var batch: [io_service_t] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            batch.append(service)
            service = IOIteratorNext(iterator)
        }
        guard !batch.isEmpty else {

            return false
        }
        let before = claimedDevices.count
        process(batch)

        return claimedDevices.count > before
    }

    /// Bounded, EVENT-DRIVEN retry chain (fires on pad device arrivals, not
    /// on a timer): the unclaimed pad exposes its interfaces only briefly
    /// per enumeration cycle, so we re-scan at 0 / 150 ms / 600 ms / 2 s
    /// after the device publish and stop as soon as an interface is held.
    private func grabWithRetries() async {
        guard !grabInFlight else { return }
        grabInFlight = true
        defer { grabInFlight = false }
        for attempt in 0...3 {
            if attempt > 0 {
                try? await Task.sleep(for: attempt == 1 ? .milliseconds(150)
                                                        : attempt == 2 ? .milliseconds(600)
                                                                       : .seconds(2))
            }
            // Success = a NEW pad was claimed/offered. Returning false here
            // does NOT mean unclaimed — the pad may already be ours from the
            // publish-time claim (the common case).
            if grabInterfaces() {

                return
            }

        }
    }

    /// Re-resolve the pad's CURRENT GIP interface at connect time.
    ///
    /// The unclaimed pad re-enumerates continuously (blink loop) and
    /// configure(value: 1) terminates + re-publishes the interface nubs, so
    /// the io_service_t offered during discovery can point at a nub that has
    /// since been destroyed. A pipe copied from a dead nub fails EVERY
    /// enqueue with kIOReturnBadArgument ("Unable to enqueue IO."). Scan the
    /// registry for the pad's live GIP interface (lowest bInterfaceNumber),
    /// replace the cached offer with it, and re-claim it if the held claim
    /// is on the old nub — so the pad goes solid under a REAL claim.
    private func resolveLiveInterface(for id: DeviceID) {
        let entry = deviceEntryID(from: id)
        let stable = stableKeyByID[id.raw]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            ["IOProviderClass": "IOUSBHostInterface"] as CFDictionary,
            &iterator
        ) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var best: (number: UInt8, service: io_service_t)?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let cls = registryUInt8(service, "bInterfaceClass")
            let sub = registryUInt8(service, "bInterfaceSubClass")
            if cls == UInt8(GIP.gipInterfaceClass),
               sub == UInt8(GIP.gipInterfaceSubclass) {
                // Match by stable identity first (survives re-enumeration —
                // the registry entry ID changes every cycle), entry ID as
                // fallback for pads with no stable identity.
                let matches: Bool
                if let stable {
                    matches = stableKey(for: readDeviceInfo(service) ?? DeviceInfo()) == stable
                } else {
                    matches = deviceEntryID(for: service) == entry
                }
                if matches {
                    let number = registryUInt8(service, "bInterfaceNumber") ?? 0
                    if best == nil || number < best!.number {
                        if let old = best { IOObjectRelease(old.service) }
                        best = (number, service)
                        continue
                    }
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        guard let found = best else {
            // No live GIP interface for this device right now (mid blink
            // cycle); keep the cached offer — open() fails cleanly and the
            // next attempt re-resolves.
            return
        }
        // The pad may have re-enumerated (blink loop): the live interface's
        // PARENT device entry ID can differ from the cached one. All
        // per-entry bookkeeping (claims, claimedDevices, cache) is keyed by
        // the PARENT's entry ID — never the nub's. Remap to the live parent;
        // a device claim kept from the dead parent is dropped (open()
        // re-creates one from the live parent).
        let foundParent = deviceEntryID(for: found.service)
        if foundParent != entry {

            if let held = heldInterfaces.removeValue(forKey: entry) {
                heldInterfaces[foundParent] = held
            }
            heldDevices.removeValue(forKey: entry)   // wraps the dead parent
            claimedDevices.remove(entry)
            claimedDevices.insert(foundParent)
            deviceEntryCache[id.raw] = foundParent
        }
        // Re-claim if the held claim is on a stale nub (entry ID changed).
        if let held = heldInterfaces[foundParent] {
            if registryEntryID(held.ioService) != registryEntryID(found.service) {

                heldInterfaces[foundParent] = nil
                if let iface = try? IOUSBHostInterface(__ioService: found.service, options: [], queue: queue, interestHandler: nil) {
                    heldInterfaces[foundParent] = iface

                }
            } else {

            }
        } else {
            // No claim held (invalidated or never claimed): claim the live
            // interface now so the pad can go solid before we even open.
            if let iface = try? IOUSBHostInterface(__ioService: found.service, options: [], queue: queue, interestHandler: nil) {
                heldInterfaces[foundParent] = iface

            }
        }
        // Point the cached offer at the live service (open() reads it).
        if let previous = pendingServices[id.raw] {
            IOObjectRelease(previous)
        }
        pendingServices[id.raw] = found.service
    }

    private struct InterfaceCandidate {
        let service: io_service_t
        let deviceEntry: UInt64
        let number: UInt8
        let info: DeviceInfo
    }

    private func process(_ services: [io_service_t]) {
        // 1) Keep only GIP vendor interfaces (class 0xFF, subclass 0x47 —
        //    any protocol byte; the data one is 0xD0). Both entry points
        //    (notification batches and startup sweeps) pass EVERY
        //    IOUSBHostInterface, so the filter stays here.
        // 2) Group by parent device: a pad exposes SEVERAL interfaces with
        //    the same signature (data + audio/aux), and opening more than
        //    one of them fails the others with "exclusive access" — so we
        //    claim exactly ONE interface per device, the lowest-numbered
        //    one (interface #0, the data pipe), and release the rest.
        var candidates: [InterfaceCandidate] = []
        for service in services {
            let cls = registryUInt8(service, "bInterfaceClass")
            let sub = registryUInt8(service, "bInterfaceSubClass")
            guard cls == UInt8(GIP.gipInterfaceClass),
                  sub == UInt8(GIP.gipInterfaceSubclass) else {
                IOObjectRelease(service)
                continue
            }
            let deviceEntry = deviceEntryID(for: service)
            let number = registryUInt8(service, "bInterfaceNumber") ?? 0
            let proto = registryUInt8(service, "bInterfaceProtocol") ?? 0
            let info = readDeviceInfo(service) ?? DeviceInfo()

            candidates.append(InterfaceCandidate(service: service, deviceEntry: deviceEntry, number: number, info: info))
        }

        // Claim the lowest-numbered interface per device; release the rest.
        var chosen: [UInt64: InterfaceCandidate] = [:]
        for candidate in candidates {
            if let existing = chosen[candidate.deviceEntry] {
                if candidate.number < existing.number {
                    chosen[candidate.deviceEntry] = candidate
                    IOObjectRelease(existing.service)
                } else {
                    IOObjectRelease(candidate.service)
                }
            } else {
                chosen[candidate.deviceEntry] = candidate
            }
        }

        for candidate in chosen.values {
            guard !claimedDevices.contains(candidate.deviceEntry) else {
                IOObjectRelease(candidate.service)
                continue
            }
            claimedDevices.insert(candidate.deviceEntry)
            // THE trick: claim the GIP data interface immediately. A pad
            // that's blinking re-enumerates forever unless an interface is
            // claimed — a device-only claim does NOT stop it (observed).
            claimInterface(candidate)
            offerInterface(candidate)
        }
    }

    private func claimInterface(_ candidate: InterfaceCandidate) {
        guard heldInterfaces[candidate.deviceEntry] == nil else { return }
        // The blinking pad burns a new registry entry ID per cycle; stale
        // claims on dead nubs would accumulate forever otherwise. (A dropped
        // live claim is re-taken by resolveLiveInterface at connect.)
        if heldInterfaces.count > 16 {
            heldInterfaces.removeAll()
        }
        do {
            let iface = try IOUSBHostInterface(__ioService: candidate.service, options: [], queue: queue, interestHandler: nil)
            heldInterfaces[candidate.deviceEntry] = iface

        } catch {

        }
    }

    /// Adapter dongles expose the same vendor signature but speak MT76
    /// 802.11 over it — refused by PID. Then the pad is offered to the
    /// coordinator at the transport level; the identify handshake confirms
    /// it's actually a gamepad.
    private func offerInterface(_ candidate: InterfaceCandidate) {
        guard !GIP.adapterProductIDs.contains(candidate.info.productID) else {

            IOObjectRelease(candidate.service)
            return
        }
        let id = DeviceID(transport: .usb, raw: identifier(forDevice: candidate.deviceEntry, info: candidate.info))
        if let previous = pendingServices[id.raw] {
            IOObjectRelease(previous)   // a later sweep re-offered the same pad
        }
        pendingServices[id.raw] = candidate.service   // ownership moves to connect()
        deviceEntryCache[id.raw] = candidate.deviceEntry   // current entry for this stable ID
        if let stable = stableKey(for: candidate.info) {
            stableKeyByID[id.raw] = stable
        }
        yield(.discovered(id, AdvertisementInfo(
            vendorID: candidate.info.vendorID,
            productID: candidate.info.productID,
            localName: "Xbox Controller (GIP)",
            rssi: nil
        )))
    }

    /// IORegistryEntryCreateCFProperty returns the value (4 arguments, no
    /// out-parameter); NSNumbers arrive as NSNumber after takeRetainedValue.
    private func registryUInt8(_ service: io_service_t, _ key: String) -> UInt8? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else { return nil }
        return value.uint8Value
    }

    private struct DeviceInfo {
        var vendorID: UInt16 = 0
        var productID: UInt16 = 0
        var locationID: UInt32? = nil        // kUSBDevicePropertyLocationID: stable per PORT
        var serialString: String? = nil      // "USB Serial Number" (absent on most pads)
    }

    // VIDs/PIDs are published on the interface AS WELL AS the parent device
    // ("idVendor"/"idProduct" — note the lowercase "id" prefix; "USB…ID"
    // keys do not exist). Read from the interface, fall back to the parent.
    private func readDeviceInfo(_ interfaceService: io_service_t) -> DeviceInfo? {
        var info = DeviceInfo()
        if let vendor = registryUInt16(interfaceService, "idVendor")
            ?? registryUInt16(parentOf: interfaceService, "idVendor") {
            info.vendorID = vendor
        }
        if let product = registryUInt16(interfaceService, "idProduct")
            ?? registryUInt16(parentOf: interfaceService, "idProduct") {
            info.productID = product
        }
        // Stable-per-port/stable-per-unit identity lives on the parent
        // IOUSBHostDevice (the interface nubs do not publish it).
        if let loc = registryUInt32(interfaceService, "locationID")
            ?? registryUInt32(parentOf: interfaceService, "locationID") {
            info.locationID = loc
        }
        if let serial = registryString(interfaceService, "USB Serial Number")
            ?? registryString(parentOf: interfaceService, "USB Serial Number") {
            info.serialString = serial
        }
        return info
    }

    private func registryUInt32(_ service: io_service_t, _ key: String) -> UInt32? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else { return nil }
        return value.uint32Value
    }

    private func registryEntryID(_ service: io_service_t) -> UInt64 {
        var entryID: UInt64 = 0
        _ = IORegistryEntryGetRegistryEntryID(service, &entryID)
        return entryID
    }

    private func registryString(_ service: io_service_t, _ key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else { return nil }
        return value
    }

    private func registryUInt16(_ service: io_service_t, _ key: String) -> UInt16? {
        guard let value = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else { return nil }
        return value.uint16Value
    }

    private func registryUInt16(parentOf service: io_service_t, _ key: String) -> UInt16? {
        var parent: io_service_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return registryUInt16(parent, key)
    }

    private func registryUInt32(parentOf service: io_service_t, _ key: String) -> UInt32? {
        var parent: io_service_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return registryUInt32(parent, key)
    }

    private func registryString(parentOf service: io_service_t, _ key: String) -> String? {
        var parent: io_service_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return registryString(parent, key)
    }

    /// Registry entry ID of the parent IOUSBHostDevice — the per-PAD key
    /// (all three interfaces of one pad share it).
    private func deviceEntryID(for service: io_service_t) -> UInt64 {
        var parent: io_service_t = 0
        if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(parent, &entryID) == KERN_SUCCESS {
                return entryID
            }
        }
        var entryID: UInt64 = 0
        _ = IORegistryEntryGetRegistryEntryID(service, &entryID)
        return entryID
    }

    /// STABLE per-unit/per-port identity for a wired pad.
    ///
    /// The registry ENTRY ID changes on every enumeration (and on every
    /// replug), so a DeviceID derived from it makes the coordinator treat
    /// each replug as a brand-new controller — the duplicate rows the user
    /// saw. Wired pads never ANNOUNCE, so there is no wireless MAC to key on
    /// either. Stable identities available from the device descriptor:
    ///   1. "USB Serial Number" string (best: unique per unit) — FNV-1a hash.
    ///   2. locationID (kUSBDevicePropertyLocationID: constant per PORT,
    ///      survives replug on that port) — keyed with productID.
    ///   3. Fallback: the registry entry ID (old behavior; unstable).
    private func identifier(forDevice entryID: UInt64, info: DeviceInfo) -> UUID {
        let key: UInt64
        if let serial = info.serialString, !serial.isEmpty {
            // FNV-1a 64-bit over the serial bytes.
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in serial.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
            key = hash
        } else if let loc = info.locationID {
            // Port identity + product: unique per port, stable across replugs.
            key = (UInt64(loc) << 16) | UInt64(info.productID & 0xFFFF)
        } else {
            key = entryID
        }
        var bytes = key.bigEndian
        return withUnsafeBytes(of: &bytes) { raw in
            let b = Array(raw)
            return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                               0x58, 0x42, 0x4F, 0x58, 0x00, 0x00, 0x00, 0x00))
        }
    }

    /// Inverse of identifier(forDevice:) — recover the CURRENT device entry
    /// ID for a DeviceID (used to release claims / find live interfaces).
    /// The UUID no longer encodes the entry ID (it's a stable key), so the
    /// lookup goes through deviceEntryCache, which offerInterface and
    /// resolveLiveInterface keep fresh. Legacy UUIDs (entry-ID payloads)
    /// still decode correctly as a fallback.
    private func deviceEntryID(from id: DeviceID) -> UInt64 {
        if let cached = deviceEntryCache[id.raw] { return cached }
        var value: UInt64 = 0
        withUnsafeBytes(of: id.raw) { raw in
            for byte in raw.prefix(8) {
                value = (value << 8) | UInt64(byte)
            }
        }
        return value
    }
}

// MARK: - open / close

extension XboxUSBTransport {
    private func open(session: Session, interfaceService: io_service_t) async throws {
        // The interface is usually pre-claimed by process() and handed to
        // connect() — REUSE it (opening the same interface twice fails with
        // "exclusive access" against our own session). The device open is
        // optional: GIP rides the interface's interrupt pipes, so an
        // unavailable device claim must not fail the session.
        if session.interface == nil {
            session.interface = try IOUSBHostInterface(__ioService: interfaceService, options: [], queue: queue, interestHandler: nil)
        }
        if session.device == nil {
            var deviceService: io_service_t = 0
            if IORegistryEntryGetParentEntry(interfaceService, kIOServicePlane, &deviceService) == KERN_SUCCESS {
                defer { IOObjectRelease(deviceService) }
                session.device = try? IOUSBHostDevice(__ioService: deviceService, options: [], queue: queue, interestHandler: nil)
                if session.device == nil {

                }
            }
        }
        // Stable per-port/per-unit serial token (wired pads never ANNOUNCE,
        // so the serial falls back to the device identity). The USB Serial
        // Number — the same string that keys the stable DeviceID — is
        // preferred (unique per unit, survives port changes); locationID is
        // the per-port fallback. This is what lets the coordinator's
        // known-controller prefs (mapping, rumble) follow the pad instead of
        // colliding on "xbox-usb".
        if session.portToken == nil {
            if let serial = registryString(interfaceService, "USB Serial Number")
                ?? registryString(parentOf: interfaceService, "USB Serial Number"),
                !serial.isEmpty {
                session.portToken = serial
            } else if let loc = registryUInt32(interfaceService, "locationID")
                ?? registryUInt32(parentOf: interfaceService, "locationID") {
                session.portToken = String(format: "%08X", loc)
            }
        }

        guard let interface = session.interface else {
            throw NSError(domain: "XboxUSB", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Interface claim unavailable"])
        }

        // Activate the interface's default alternate setting BEFORE copying
        // pipes (IOUSBHostInterface.selectAlternateSetting): this sends
        // SET_INTERFACE and opens the interface's pipes. It MUST come first
        // — the docs note it aborts all pending I/O and invalidates any
        // pipe objects created before it. Best effort: an interface that is
        // already on alt 0 may reject the redundant SET_INTERFACE, and the
        // pad works without it either way.
        do {
            _ = try interface.selectAlternateSetting(0)

        } catch {

        }

        // Endpoint addresses: the data interface exposes interrupt IN 0x81
        // and interrupt OUT 0x01.
        guard let pipeIn = try? interface.copyPipe(withAddress: 0x81),
              let pipeOut = try? interface.copyPipe(withAddress: 0x01) else {
            throw NSError(domain: "XboxUSB", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Interrupt pipes 0x81/0x01 not found"])
        }
        session.pipeIn = pipeIn
        session.pipeOut = pipeOut

    }

    private func close(_ session: Session) {
        // There is no IOUSBHost close(): releasing the device/interface
        // objects drops the claim. With completionTimeout 0 the parked
        // interrupt read never completes on its own, so the pipes must be
        // ABORTED first — that releases the read loop's continuation with
        // kIOReturnAborted, and the loop exits via its session-alive check.
        // (abortWithOption:error: is ObjC-only in Swift — dispatched through
        // the runtime, same trick as configureDevice.)
        session.readTask?.cancel()
        session.readTask = nil
        abortPipe(session.pipeIn)
        abortPipe(session.pipeOut)
        session.pipeIn = nil
        session.pipeOut = nil
        session.interface = nil
        session.device = nil
    }

    /// ObjC-only IOUSBHostPipe abortWithOption:error: via the runtime.
    /// Synchronous (IOUSBHostAbortOptionSynchronous = 1): waits until the
    /// aborted I/O has completed so the read loop is released before the
    /// pipe objects go away.
    private func abortPipe(_ pipe: IOUSBHostPipe?) {
        guard let pipe else { return }
        typealias AbortIMP = @convention(c) (AnyObject, Selector, UInt, UnsafeMutableRawPointer?) -> Bool
        let selector = NSSelectorFromString("abortWithOption:error:")
        guard let imp = pipe.method(for: selector) else { return }
        let fn = unsafeBitCast(imp, to: AbortIMP.self)
        _ = fn(pipe, selector, 1, nil)
    }
}

// MARK: - read loop / GIP handshake

extension XboxUSBTransport {
    private func startReadLoop(_ session: Session) {
        session.readTask = Task { [weak self] in
            await self?.readLoop(session)
        }
    }

    // One outstanding 64-byte interrupt read at a time (the data packet
    // size; bInterval decides the cadence — the 1537 delivers ~250 Hz).
    // Interrupt reads cannot carry a completion timeout (and never time out
    // on their own), so a cancelled or unplugged session is released by
    // aborting the pipe in close().
    private func readLoop(_ session: Session) async {
        guard let pipe = session.pipeIn else { return }
        while !Task.isCancelled {
            do {
                let data = try await readPacket(pipe)
                guard !data.isEmpty else {
                    // Empty read = the pipe was ABORTED (session wind-down
                    // via disconnect/close — Task.isCancelled or the session
                    // leaving the dict below) or a rare zero-length packet.
                    // With completionTimeout 0 on interrupt pipes there is no
                    // idle-timeout path any more: pending IO simply waits.
                    if Task.isCancelled || sessions[session.id.raw] == nil { return }
                    continue
                }
                let shouldContinue = await handleBytes(session, data)
                if !shouldContinue { return }
            } catch {
                if Task.isCancelled || sessions[session.id.raw] == nil { return }
                await handleReadFault(session, error)
                return
            }
        }
    }

    private func readPacket(_ pipe: IOUSBHostPipe) async throws -> Data {
        let io = TransferIO(capacity: 64)
        let (result, count) = try await transfer(pipe, io)
        // kIOReturnAborted = session wind-down (close() aborts the pipe) or
        // the host stack aborting a stale poll. Return empty and let
        // readLoop's session-alive check decide: cancelled session returns,
        // live session keeps polling.
        if result == kIOReturnAborted { return Data() }
        guard result == kIOReturnSuccess else {
            throw NSError(domain: "XboxUSB", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "pipe read failed (kern_return 0x\(String(result, radix: 16)))"])
        }
        guard count > 0 else { return Data() }
        return io.data.subdata(with: NSRange(location: 0, length: min(count, 64)))
    }

    private func handleReadFault(_ session: Session, _ error: Error) async {
        // REAL fault only (unplug, bus reset, aborted transfer — not idle).
        guard sessions[session.id.raw] != nil else { return }

        sessions[session.id.raw] = nil
        close(session)
        claimedDevices.remove(deviceEntryID(from: session.id))   // allow re-discovery
        yield(.disconnected(session.id, .linkLoss))
    }

    /// Returns false when the transport must tear down the session.
    private func handleBytes(_ session: Session, _ data: Data) async -> Bool {
        let messages = session.parser.feed(data)
        // ACK EVERY acked packet immediately — the pad waits for the ACK
        // before sending the next chunk of a chunked transfer (identify),
        // and chunked packets surface no message until the transfer
        // completes, so their per-chunk ACKs can only come from
        // parser.drainAcks() — with-
        // out them the pad retransmits chunk 1 forever (fresh sequence each
        // time) and identify never completes.
        for ack in session.parser.drainAcks() {
            try? await write(session, GIPOutbound.acknowledge(
                clientID: clientID(session),
                sequence: session.nextSequence(),
                ackedCommand: ack.command,
                ackedOptions: ack.options,
                ackedLength: ack.ackedLength,
                transferTotal: ack.total))
        }
        for message in messages {
            let h = message.header
            // Dispatch on COMMAND, not on the INTERNAL option bit (command
            // is what decides how a message is handled; options do not).
            // The reassembled chunked identify arrives with the transfer's
            // options (INTERNAL set, ACK/CHUNK_START cleared) but command
            // dispatch is what matters — the old `if h.options.containsInternal`
            // gate silently dropped it whenever the completion chunk's header
            // was used.
            switch h.command {
            case .announce:
                handleAnnounce(session, message)
                try? await write(session, GIPOutbound.identify(
                    clientID: clientID(session), sequence: session.nextSequence()))
            case .identify:
                guard let info = GIPIdentifyInfo.parse(message.payload) else {

                    continue
                }

                if info.isGamepad {
                    session.supportsShare = info.supportsShare
                    session.supportsDLI = info.supportsDLI

                    if let fw = info.firmwareVersions.first {
                        session.firmware = (fw.major, fw.minor)
                    }
                    // Gamepad probe: power-on, then inputs flow.
                    try? await write(session, GIPOutbound.powerOn(
                        clientID: clientID(session), sequence: session.nextSequence()))
                    try? await write(session, GIPOutbound.led(
                        clientID: clientID(session), sequence: session.nextSequence()))
                    yieldMetadata(session)
                    yield(.ready(session.id))
                } else {

                    return false
                }
            case .status:
                if message.payload.count >= 1, message.payload[0] & GIP.statusConnected == 0 {

                }
            case .virtualKey:
                // Guide button (virtual key): payload [down, vk];
                // 0x5B = VK_LWIN.
                handleVirtualKey(session, message)
            case .input:
                handleInput(session, message)
            default:
                break
            }
        }
        return true
    }

    private func handleAnnounce(_ session: Session, _ message: GIPMessage) {
        // Announce layout: address[6], unknown[2], vid, pid, fw, hw
        let payload = message.payload
        guard payload.count >= 28 else { return }
        session.address = Data(payload.prefix(6))
        let pid = UInt16(payload[10]) | (UInt16(payload[11]) << 8)
        session.productID = pid

    }

    private func handleVirtualKey(_ session: Session, _ message: GIPMessage) {
        // [down, vk]; only Guide (VK_LWIN 0x5B) matters for a gamepad.
        let payload = message.payload
        guard payload.count >= 2, payload[1] == 0x5B else { return }
        let down = payload[0] & 0x01 != 0
        guard down != session.guideDown else { return }
        session.guideDown = down
        emitReplayInput(session)
    }

    private func handleInput(_ session: Session, _ message: GIPMessage) {
        // Input layout: the base 14 bytes are the gamepad state; pads that
        // advertise Share piggyback a byte near the END of the packet
        // (length − 18, or −26 with the DLI counter), and DLI pads append an
        // 8-byte latency counter. Keep the whole packet — the profile parses
        // the base 14, we synthesize two reserved bits.
        guard message.payload.count >= 14 else { return }
        var payload = Data(message.payload)
        // Guide latch: bit 0 of the buttons word is reserved in the input
        // layout (the button bits start at 1<<2), so it's a safe synthetic
        // channel.
        if session.guideDown { payload[0] |= 0x01 } else { payload[0] &= 0xFE }
        // Share latch: bit 1 is equally reserved. The physical Share byte is
        // at a fixed offset from the end of the packet.
        if session.supportsShare {
            if let share = GIPGamepadInput.shareByte(payload: payload, supportsDLI: session.supportsDLI) {
                if share & 0x01 != 0 { payload[0] |= 0x02 } else { payload[0] &= 0xFD }
            }
        }
        session.lastInput = payload
        yield(.reportReceived(session.id, reportID: nil, payload))
    }

    private func emitReplayInput(_ session: Session) {
        // Re-emit the last input with the Guide bit changed so the profile
        // turns it into .home while every other axis stays untouched.
        guard var payload = session.lastInput else { return }
        if session.guideDown { payload[0] |= 0x01 } else { payload[0] &= 0xFE }
        yield(.reportReceived(session.id, reportID: nil, payload))
    }

    private func clientID(_ session: Session) -> UInt8 {
        // Wired pads address the host as client 0 (the main gamepad).
        0
    }

    private func yieldMetadata(_ session: Session) {
        // Serial only in v1: FirmwareInfo is an NS2-shaped type; the GIP
        // firmware tuple stays in the session for future UI use.
        var meta = ControllerMetadata()
        meta.serial = session.serial
        yield(.deviceMetadata(session.id, meta))
    }
}

// MARK: - write / events

extension XboxUSBTransport {
    private func write(_ session: Session, _ frame: Data) async throws {
        guard let pipe = session.pipeOut else { return }
        let io = TransferIO(data: frame)
        // Writes are bounded by a watchdog: a pad that is asleep or mid
        // blink-cycle may not service its OUT endpoint, and a transfer that
        // never completes would block this actor for every session.
        let (result, _) = try await transfer(pipe, io, watchdog: 1.0)
        if result != kIOReturnSuccess {

        }
    }

    // One in-flight transfer at a time: enqueueIORequest takes an
    // NSMutableData and reports (IOReturn, transferredCount) through its
    // completion handler, which we bridge into a continuation. The buffer
    // wrapper is @unchecked Sendable so the @Sendable handler can capture it
    // under strict concurrency; the underlying NSMutableData stays alive on
    // the suspended actor frame for the duration of the transfer.
    //
    // THE COMPLETION TIMEOUT IS DELIBERATELY 0: both pipes are INTERRUPT
    // pipes and the API contract is "Must be 0 for interrupt pipes and
    // streams" (IOUSBHostPipe.h) — the old 1 s completion timeout was
    // rejected by the kernel with kIOReturnBadArgument ("Unable to enqueue
    // IO.", -536870206) on EVERY transfer. Interrupt transfers never time
    // out on their own; a transfer that cannot finish is instead released
    // with abortWithOption:error: — either immediately (close()), or, for
    // writes, after an optional watchdog wait.
    private func transfer(
        _ pipe: IOUSBHostPipe, _ io: TransferIO, watchdog: TimeInterval? = nil
    ) async throws -> (IOReturn, Int) {
        // IOUSBHostPipe is not Sendable; the box confines it to one
        // in-flight transfer at a time (this function is the only site that
        // touches it), so @unchecked Sendable is the correct opt-out.
        let context = TransferContext(pipe: pipe, io: io)
        // withThrowingTaskGroup (NOT withTaskGroup): the body throws when a
        // child fails or the group ends unexpectedly. The plain withTaskGroup
        // body is non-throwing, so the compiler rejects this body with
        // "invalid conversion from throwing function of type
        // '@concurrent (inout TaskGroup<TransferEvent>) async throws -> …'".
        // ThrowingTaskGroup.next() is throwing too.
        return try await withThrowingTaskGroup(of: TransferEvent.self) { group -> (IOReturn, Int) in
            group.addTask {
                do {
                    let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(IOReturn, Int), Error>) in
                        do {
                            try context.pipe.enqueueIORequest(with: context.io.data, completionTimeout: 0) { result, count in
                                cont.resume(returning: (result, count))
                            }
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                    // .completed takes TWO arguments (IOReturn, Int) — the
                    // continuation's result is a single tuple, so unpack it.
                    return .completed(result.0, result.1)
                } catch {
                    // Error is only stringified here so the task-group child
                    // result carries purely Sendable payloads.
                    return .failed("\(error)")
                }
            }
            if let watchdog {
                group.addTask {
                    try? await Task.sleep(for: .seconds(watchdog))
                    return .timeout
                }
            }
            guard let event = try await group.next() else {
                throw NSError(domain: "XboxUSB", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "transfer group ended unexpectedly"])
            }
            switch event {
            case .completed(let result, let count):
                group.cancelAll()   // stop the still-sleeping watchdog child
                return (result, count)
            case .failed(let message):
                throw NSError(domain: "XboxUSB", code: 6,
                              userInfo: [NSLocalizedDescriptionKey: message])
            case .timeout:
                // Watchdog fired before the transfer completed: release it
                // with a synchronous abort — the aborted completion
                // (kIOReturnAborted) then finishes the transfer child, so
                // the group cannot outlive the abort.

                abortPipe(pipe)
                guard let completed = try await group.next() else {
                    return (kIOReturnAborted, 0)
                }
                switch completed {
                case .completed(let result, let count):
                    return (result, count)
                case .failed(let message):
                    throw NSError(domain: "XboxUSB", code: 6,
                                  userInfo: [NSLocalizedDescriptionKey: message])
                case .timeout:
                    return (kIOReturnAborted, 0)
                }
            }
        }
    }

    private func yield(_ event: TransportEvent) { continuation.yield(event) }
}

/// Result of one transfer race (transfer completion vs watchdog timeout).
/// Payloads are Sendable-only: `any Error` is stringified as soon as it is
/// caught so nothing non-Sendable crosses the task-group boundary.
private enum TransferEvent {
    case completed(IOReturn, Int)
    case failed(String)
    case timeout
}

/// One in-flight transfer on one pipe: pipe + buffer, confined to a single
/// transfer at a time (the transport never enqueues twice on the same pipe).
/// @unchecked Sendable because IOUSBHostPipe is not Sendable — safe here for
/// the same reason as TransferIO.
private final class TransferContext: @unchecked Sendable {
    let pipe: IOUSBHostPipe
    let io: TransferIO

    init(pipe: IOUSBHostPipe, io: TransferIO) {
        self.pipe = pipe
        self.io = io
    }
}

/// NSMutableData box that is Sendable (the buffer itself is confined to one
/// transfer at a time, so shared-mutable access never happens in practice).
private final class TransferIO: @unchecked Sendable {
    let data: NSMutableData

    init(capacity: Int) {
        data = NSMutableData(length: capacity) ?? NSMutableData()
    }

    init(data source: Data) {
        data = NSMutableData(data: source)
    }
}
