// Standalone CLI: dump the internal flash memory of a Switch 2 controller over BLE.
//
// Run:
//   swift Tools/Dump.swift [output.bin]
//
// Supported controllers (Nintendo VID 0x057E):
//   0x2066  Joy-Con 2 (R)
//   0x2067  Joy-Con 2 (L)
//   0x2069  Pro Controller 2
//   0x2073  NSO GameCube Controller
//
// Each chunk = 0x40 bytes (BLE max is 0x4F per Subcommand 0x04). Total = 0x200000 (2 MiB).
// Quit any running WaveBird (or other host) first so this process can claim the link.
//
// Protocol: see ndeadly/switch2_controller_research commands.md (Command 0x02 / Subcommand 0x04)
// and procon2tool/dumper.html (transport byte flipped 0x00→0x01 for BLE).

import Foundation
@preconcurrency import CoreBluetooth

private let kServiceUUID  = CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0")
private let kOutputUUID   = CBUUID(string: "649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005")
private let kResponseUUID = CBUUID(string: "C765A961-D9D8-4D36-A20A-5315B111836A")

private let kNintendoVID: UInt16 = 0x057E
private let kSupportedPIDs: [UInt16: String] = [
    0x2066: "Joy-Con 2 (R)",
    0x2067: "Joy-Con 2 (L)",
    0x2069: "Pro Controller 2",
    0x2073: "NSO GameCube Controller",
]

private let kTotalSize: Int = 0x200000   // 2 MiB
private let kChunkSize: Int = 0x40
private let kChunkTimeout: TimeInterval = 3

private func spiReadCommand(address: UInt32, length: UInt8) -> Data {
    Data([
        0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00,   // header: cmd 0x02 / transport 0x01 BLE / subcmd 0x04 / payloadLen 0x08
        length, 0x7E, 0x00, 0x00,
        UInt8(address & 0xFF),
        UInt8((address >> 8) & 0xFF),
        UInt8((address >> 16) & 0xFF),
        UInt8((address >> 24) & 0xFF),                    // address: little-endian
    ])
}

private func parseSPIResponse(_ data: Data, expectedAddress: UInt32) -> Data? {
    guard data.count >= 16, data[0] == 0x02, data[3] == 0x04 else { return nil }
    let addr = UInt32(data[12])
        | (UInt32(data[13]) << 8)
        | (UInt32(data[14]) << 16)
        | (UInt32(data[15]) << 24)
    guard addr == expectedAddress else { return nil }
    let len = Int(data[8])
    guard data.count >= 16 + len else { return nil }
    return data.subdata(in: 16..<(16 + len))
}

private func decodeNintendoMfg(_ mfg: Data) -> (vid: UInt16, pid: UInt16)? {
    guard mfg.count >= 9 else { return nil }
    let vid = UInt16(mfg[5]) | (UInt16(mfg[6]) << 8)
    let pid = UInt16(mfg[7]) | (UInt16(mfg[8]) << 8)
    return (vid, pid)
}

final class Dumper: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var outputCh: CBCharacteristic?
    private var responseCh: CBCharacteristic?

    private var address: UInt32 = 0
    private var buffer = Data(count: kTotalSize)
    private let outputURL: URL
    private var startTime: Date?
    private var lastLog: Date = .distantPast
    private var timeoutItem: DispatchWorkItem?
    private var deviceLabel: String = "?"

    init(outputURL: URL) { self.outputURL = outputURL }

    func start() {
        log("output: \(outputURL.path)")
        log("waiting for Bluetooth power-on…")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            let already = central.retrieveConnectedPeripherals(withServices: [kServiceUUID])
            if let p = already.first {
                log("attaching to already-connected peripheral \(p.identifier)")
                attach(p)
            } else {
                let pids = kSupportedPIDs.keys.sorted().map { String(format: "0x%04X", $0) }.joined(separator: ", ")
                log("scanning for Nintendo VID 0x057E PID in {\(pids)}")
                central.scanForPeripherals(withServices: nil,
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        case .unauthorized:
            fail("Bluetooth unauthorized — grant Bluetooth permission to the terminal launching this script in System Settings → Privacy & Security → Bluetooth.")
        case .poweredOff:  fail("Bluetooth is powered off.")
        case .unsupported: fail("Bluetooth not supported on this host.")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let parsed = decodeNintendoMfg(mfg),
              parsed.vid == kNintendoVID else { return }
        guard let name = kSupportedPIDs[parsed.pid] else {
            log(String(format: "ignoring Nintendo PID 0x%04X (not supported)", parsed.pid))
            return
        }
        deviceLabel = "\(name) [PID 0x" + String(format: "%04X", parsed.pid) + "]"
        log("found \(deviceLabel) at \(peripheral.identifier) — connecting")
        central.stopScan()
        attach(peripheral)
    }

    private func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.connect(p, options: ["kCBConnectOptionRequiresLowLatency": true])
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("connected; discovering service")
        peripheral.discoverServices([kServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let reason = error.map(\.localizedDescription) ?? "no error"
        fail(String(format: "disconnected (%@) at 0x%06X / 0x%06X", reason, address, UInt32(kTotalSize)))
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == kServiceUUID }) else {
            fail("primary service \(kServiceUUID) not exposed by peripheral")
        }
        peripheral.discoverCharacteristics([kOutputUUID, kResponseUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let chars = service.characteristics ?? []
        outputCh   = chars.first(where: { $0.uuid == kOutputUUID })
        responseCh = chars.first(where: { $0.uuid == kResponseUUID })
        guard outputCh != nil, let responseCh else {
            fail("required characteristics not found")
        }
        log("subscribing to command-response notifications")
        peripheral.setNotifyValue(true, for: responseCh)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == kResponseUUID, characteristic.isNotifying else { return }
        log(String(format: "starting dump of %d bytes (0x%X chunks of 0x%X)",
                   kTotalSize, kTotalSize / kChunkSize, kChunkSize))
        startTime = Date()
        sendNextRead()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == kResponseUUID, let value = characteristic.value else { return }
        guard let chunk = parseSPIResponse(value, expectedAddress: address) else { return }
        timeoutItem?.cancel()

        let dst = Int(address)
        let end = dst + chunk.count
        guard end <= buffer.count else {
            fail(String(format: "response overruns buffer at 0x%06X (+%d)", address, chunk.count))
        }
        buffer.replaceSubrange(dst..<end, with: chunk)
        address &+= UInt32(chunk.count)

        if address >= kTotalSize {
            finish()
        } else {
            progressLog()
            sendNextRead()
        }
    }

    // MARK: Sequencer

    private func sendNextRead() {
        guard let peripheral, let outputCh else { return }
        let remaining = UInt32(kTotalSize) - address
        let len = UInt8(min(UInt32(kChunkSize), remaining))
        let cmd = spiReadCommand(address: address, length: len)
        peripheral.writeValue(cmd, for: outputCh, type: .withoutResponse)
        scheduleTimeout()
    }

    private func scheduleTimeout() {
        timeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fail(String(format: "timeout waiting for response at 0x%06X — controller may need an init handshake first", self.address))
        }
        timeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + kChunkTimeout, execute: item)
    }

    private func progressLog() {
        let now = Date()
        guard now.timeIntervalSince(lastLog) > 1 else { return }
        lastLog = now
        let pct = Double(address) / Double(kTotalSize) * 100
        let elapsed = now.timeIntervalSince(startTime ?? now)
        let kbps = elapsed > 0 ? Double(address) / 1024 / elapsed : 0
        log(String(format: "  0x%06X / 0x%06X  (%.1f%%, %.1f KiB/s)", address, UInt32(kTotalSize), pct, kbps))
    }

    private func finish() {
        timeoutItem?.cancel()
        let elapsed = Date().timeIntervalSince(startTime ?? Date())
        do {
            try buffer.write(to: outputURL)
        } catch {
            fail("write failed: \(error.localizedDescription)")
        }
        log(String(format: "done — %d bytes in %.1fs from %@", buffer.count, elapsed, deviceLabel))
        exit(0)
    }

    private func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
        exit(1)
    }

    private func log(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }
}

let outputPath = CommandLine.arguments.dropFirst().first ?? "controller-dump.bin"
let outputURL = URL(fileURLWithPath: outputPath,
                   relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
let dumper = Dumper(outputURL: outputURL)
dumper.start()
dispatchMain()
