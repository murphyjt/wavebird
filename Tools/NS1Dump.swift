// Standalone CLI: read SPI flash from a REAL Switch 1 Pro Controller over Bluetooth HID.
//
// Run:
//   swiftc -O -o /tmp/ns1dump Tools/NS1Dump.swift && /tmp/ns1dump [start] [end] [out.bin]
//   e.g. /tmp/ns1dump 0x6000 0x60AA          # factory sensor + stick parameters
//        /tmp/ns1dump 0x8010 0x8040          # user calibration
//   defaults to 0x6000..0x60AA when no range is given.
//
// Why: WaveBird SYNTHESIZES this flash for its Switch Pro presentation
// (WaveBird/HID/SwitchProSession.swift::spiFlash). Several of those blocks were
// written without a cited source. This reads the same addresses off genuine
// hardware so the emulated values can be checked against ground truth.
//
// Protocol (dekuNukem/Nintendo_Switch_Reverse_Engineering; mirrored by
// SDL_hidapi_switch.c and by our own emulation of the controller side):
//   Host -> Output Report 0x01: [0x01, counter, rumble×8, 0x10, addr LE×4, len]
//   Ctrl -> Input Report 0x21:  [0x21, timer, ..., 13:ack(0x90), 14:0x10,
//                                15..18:addr echo, 19:len, 20...:data]
// Max 0x1D bytes per read.
//
// READ-ONLY. Subcommand 0x10 only; this never issues a flash write (0x11).
//
// Note: macOS binds the Pro Controller with its own driver, which runs its own
// subcommand traffic concurrently. Replies are matched on the echoed address so
// the driver's interleaved 0x21 frames don't satisfy our requests.

import Foundation
import IOKit.hid

let kVID = 0x057E
let kPID = 0x2009      // Switch 1 Pro Controller
let kMaxRead = 0x1D    // per-subcommand cap

// MARK: - CLI

var args = CommandLine.arguments.dropFirst()
// Flags may appear in any order before the address arguments.
var flags: Set<String> = []
while let f = args.first, ["info", "imu", "virtual", "raw"].contains(f) {
    flags.insert(f)
    args = args.dropFirst()
}
let infoMode = flags.contains("info")
let imuMode = flags.contains("imu")
// Normally the virtual device is rejected (see below). `virtual` deliberately
// targets it instead — the only way to compare what WaveBird emits against real
// hardware in the same sensor frame.
let wantVirtual = flags.contains("virtual")
// `raw` mode: hexdump input reports as they arrive, whatever their ID. Answers
// "are we even putting these bytes on the wire" independently of what any
// driver does with them.
let rawMode = flags.contains("raw")

func parseAddr(_ s: String) -> UInt32? {
    s.hasPrefix("0x") || s.hasPrefix("0X")
        ? UInt32(s.dropFirst(2), radix: 16)
        : UInt32(s)
}
let startAddr = args.first.flatMap(parseAddr) ?? 0x6000
if !args.isEmpty { args = args.dropFirst() }
let endAddr = args.first.flatMap(parseAddr) ?? 0x60AA
if !args.isEmpty { args = args.dropFirst() }
let outPath = args.first

guard endAddr > startAddr else {
    FileHandle.standardError.write(Data("end must be > start\n".utf8))
    exit(2)
}

// MARK: - Reply plumbing
//
// The input callback is a C function pointer, so the pending-request state is a
// file-scope box rather than a captured closure. Single-threaded by design:
// everything runs on the main run loop, one outstanding request at a time.

final class Pending: @unchecked Sendable {
    var wantSubcmd: UInt8 = 0x10
    var wantAddr: UInt32?      // nil = match on subcommand alone
    var data: [UInt8]?
}
let pending = Pending()
var reportBuffer = [UInt8](repeating: 0, count: 64)

final class RawBox: @unchecked Sendable {
    var frames: [[UInt8]] = []
}
let rawBox = RawBox()

final class IMUBox: @unchecked Sendable {
    var samples: [[Int]] = []       // accelX,Y,Z, gyroX,Y,Z per frame
}
let imuBox = IMUBox()

let inputCallback: IOHIDReportCallback = { _, _, _, _, reportID, report, length in
    guard length >= 20 else { return }
    let b = UnsafeBufferPointer(start: report, count: length)
    // Full-mode input report: 3 IMU frames of 12 bytes from offset 13, each six
    // Int16 LE (accel XYZ then gyro XYZ). Apple's driver has already put the
    // controller into 0x30 mode, so these arrive without us asking.
    if rawMode {
        rawBox.frames.append(([UInt8(reportID)] + Array(b.prefix(31))))
        return
    }
    if imuMode {
        let f: [UInt8] = (b[0] == 0x30) ? Array(b) : ([UInt8(reportID)] + Array(b))
        guard f.count >= 25, f[0] == 0x30 else { return }
        func i16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(f[i]) | UInt16(f[i+1]) << 8)) }
        imuBox.samples.append([i16(13), i16(15), i16(17), i16(19), i16(21), i16(23)])
        return
    }
    // Bluetooth frames carry the ID in byte 0; USB-style stacks strip it into
    // reportID. Accept either shape.
    let f: [UInt8] = (b[0] == 0x21) ? Array(b) : ([UInt8(reportID)] + Array(b))
    guard f.count >= 20, f[0] == 0x21, f[14] == pending.wantSubcmd else { return }
    if let want = pending.wantAddr {
        let echoed = UInt32(f[15]) | UInt32(f[16]) << 8 | UInt32(f[17]) << 16 | UInt32(f[18]) << 24
        guard echoed == want else { return }        // ignore the OS driver's interleaved frames
        let n = Int(f[19])
        guard f.count >= 20 + n else { return }
        pending.data = Array(f[20..<(20 + n)])
    } else {
        pending.data = Array(f[15...])              // subcommand payload starts at 15
    }
}

// MARK: - Device

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
// When targeting our own virtual device we cannot match on Switch Pro's
// VID/PID: WaveBird presents different identities per output mode (DualSense is
// 054C/0CE6). Match everything and filter by transport instead.
if wantVirtual {
    IOHIDManagerSetDeviceMatching(mgr, nil)
} else {
    IOHIDManagerSetDeviceMatching(mgr, [
        kIOHIDVendorIDKey as String: kVID,
        kIOHIDProductIDKey as String: kPID,
    ] as CFDictionary)
}
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))

// CRITICAL: WaveBird's own virtual Switch Pro presentation uses the SAME
// VID/PID (0x057E/0x2009). Dumping it would return the synthetic flash this
// tool exists to check — a self-confirming result that looks like success.
// Reject anything not on a real transport, and say which device was chosen.
func str(_ d: IOHIDDevice, _ key: String) -> String? {
    IOHIDDeviceGetProperty(d, key as CFString) as? String
}
let candidates = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
let real = candidates.filter {
    let isVirtual = (str($0, kIOHIDTransportKey) ?? "").lowercased() == "virtual"
    return wantVirtual ? isVirtual : !isVirtual
}.sorted { (str($0, kIOHIDProductKey) ?? "") < (str($1, kIOHIDProductKey) ?? "") }
if !wantVirtual {
    for d in candidates where !real.contains(d) {
        FileHandle.standardError.write(Data(
            "skipping virtual device (serial \(str(d, kIOHIDSerialNumberKey) ?? "?")) — that's WaveBird's own spoof\n".utf8))
    }
}
guard let dev = real.first else {
    FileHandle.standardError.write(Data("""
        No REAL Switch 1 Pro Controller found (VID 0x057E / PID 0x2009 on a non-virtual transport).
        Pair it in System Settings > Bluetooth and press a button so it connects.
        \n
        """.utf8))
    exit(1)
}
let usingMsg = "using: \(str(dev, kIOHIDProductKey) ?? "?") "
    + "transport=\(str(dev, kIOHIDTransportKey) ?? "?") "
    + "serial=\(str(dev, kIOHIDSerialNumberKey) ?? "?")\n"
FileHandle.standardError.write(Data(usingMsg.utf8))
if IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) != kIOReturnSuccess {
    FileHandle.standardError.write(Data("IOHIDDeviceOpen failed — another process may hold it exclusively.\n".utf8))
    exit(1)
}
IOHIDDeviceRegisterInputReportCallback(dev, &reportBuffer, reportBuffer.count, inputCallback, nil)
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

// MARK: - Read loop

var counter: UInt8 = 0
func readChunk(addr: UInt32, len: Int) -> [UInt8]? {
    // Neutral rumble payload (SDL sends the same) so the pad doesn't buzz.
    var pkt: [UInt8] = [0x01, counter & 0x0F,
                        0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40,
                        0x10,
                        UInt8(addr & 0xFF), UInt8((addr >> 8) & 0xFF),
                        UInt8((addr >> 16) & 0xFF), UInt8((addr >> 24) & 0xFF),
                        UInt8(len)]
    counter = counter &+ 1
    pending.wantAddr = addr
    pending.data = nil

    let rc = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x01, &pkt, pkt.count)
    guard rc == kIOReturnSuccess else {
        FileHandle.standardError.write(Data(String(format: "SetReport failed rc=0x%08X\n", rc).utf8))
        return nil
    }
    // Spin the run loop until the matching reply lands or we time out.
    let deadline = Date().addingTimeInterval(1.0)
    while pending.data == nil && Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.01, true)
    }
    return pending.data
}

// MARK: - Raw input report dump

if rawMode {
    FileHandle.standardError.write(Data("Dumping input reports for 8s — move the controller...\n".utf8))
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, true) }
    let frames = rawBox.frames
    guard !frames.isEmpty else {
        FileHandle.standardError.write(Data("no input reports received\n".utf8))
        exit(1)
    }
    print("\(frames.count) reports; showing 4 spread across the capture")
    for i in stride(from: 0, to: frames.count, by: max(1, frames.count / 4)).prefix(4) {
        let f = frames[i]
        print("  " + f.enumerated().map { String(format: "%02X", $1) }.joined(separator: " "))
    }
    // Which byte positions ever change? Static bytes are almost certainly
    // unfilled; varying ones are live data.
    let width = frames.map(\.count).min() ?? 0
    var varying: [Int] = []
    for i in 0..<width where Set(frames.map { $0[i] }).count > 1 { varying.append(i) }
    print("\n  byte indices that VARY across the capture: \(varying)")
    IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    exit(0)
}

// MARK: - Raw IMU sampling (input report 0x30)

if imuMode {
    // The IMU ships disabled and stays that way until a client asks for it —
    // exactly like GCMotion's sensorsActive. Without this the 0x30 frames
    // arrive at full rate with every IMU field zero.
    var enable: [UInt8] = [0x01, 0x00,
                           0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40,
                           0x40, 0x01]
    let erc = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x01, &enable, enable.count)
    let emsg = erc == kIOReturnSuccess
        ? "IMU enable (subcmd 0x40 01) sent\n"
        : String(format: "IMU enable failed rc=0x%08X\n", erc)
    FileHandle.standardError.write(Data(emsg.utf8))
    let settle = Date().addingTimeInterval(1.0)
    while Date() < settle { CFRunLoopRunInMode(.defaultMode, 0.05, true) }
    imuBox.samples.removeAll()
    FileHandle.standardError.write(Data("Sampling raw IMU for 12s — leave the controller flat and still...\n".utf8))
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.05, true) }
    let s = imuBox.samples
    guard s.count > 10 else {
        FileHandle.standardError.write(Data("only \(s.count) IMU frames — is the controller in full (0x30) mode?\n".utf8))
        exit(1)
    }
    func med(_ idx: Int) -> Int {
        let v = s.map { $0[idx] }.sorted(); return v[v.count / 2]
    }
    let ax = med(0), ay = med(1), az = med(2)
    let gx = med(3), gy = med(4), gz = med(5)
    let mag = (Double(ax*ax + ay*ay + az*az)).squareRoot()
    print("raw IMU at rest — \(s.count) frames, median")
    print(String(format: "  accel = (%+6d, %+6d, %+6d)   |a| = %.0f  (%.3f g at 4096/g)", ax, ay, az, mag, mag/4096))
    print(String(format: "  gyro  = (%+6d, %+6d, %+6d)", gx, gy, gz))
    let tilt = atan2((Double(ax*ax + ay*ay)).squareRoot(), Double(abs(az))) * 180 / .pi
    print(String(format: "  tilt from vertical = %.1f deg", tilt))
    print("\n  factory horizontal offsets at 0x6080 for comparison: (-688, 0, 4038)")
    IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    exit(0)
}

// MARK: - Device info (subcommand 0x02)

if infoMode {
    pending.wantSubcmd = 0x02
    pending.wantAddr = nil
    pending.data = nil
    var pkt: [UInt8] = [0x01, 0x00,
                        0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40,
                        0x02]
    let rc = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x01, &pkt, pkt.count)
    guard rc == kIOReturnSuccess else {
        FileHandle.standardError.write(Data(String(format: "SetReport failed rc=0x%08X\n", rc).utf8))
        exit(1)
    }
    let deadline = Date().addingTimeInterval(2.0)
    while pending.data == nil && Date() < deadline {
        CFRunLoopRunInMode(.defaultMode, 0.01, true)
    }
    guard let p = pending.data, p.count >= 12 else {
        FileHandle.standardError.write(Data("no device-info reply\n".utf8))
        exit(1)
    }
    let types = [0x01: "Left Joy-Con", 0x02: "Right Joy-Con", 0x03: "Pro Controller"]
    print("device info (subcommand 0x02):")
    print(String(format: "  firmware        %d.%d  (0x%02X 0x%02X)", p[0], p[1], p[0], p[1]))
    print(String(format: "  controller type 0x%02X  %@", p[2], types[Int(p[2])] ?? "unknown"))
    print(String(format: "  byte[3]         0x%02X  (doc: unknown, always 0x02)", p[3]))
    print("  MAC (big-endian) " + p[4...9].map { String(format: "%02X", $0) }.joined(separator: ":"))
    print(String(format: "  byte[10]        0x%02X  (doc: unknown, always 0x01)", p[10]))
    print(String(format: "  byte[11]        0x%02X  (colors: 0x01 = read from SPI, 0x02 = default)", p[11]))
    print("  raw " + p.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " "))
    IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    exit(0)
}

FileHandle.standardError.write(Data(String(format: "Reading 0x%04X..0x%04X from a real Pro Controller\n\n", startAddr, endAddr).utf8))

var out: [UInt8] = []
var addr = startAddr
var failures = 0
while addr < endAddr {
    let len = min(kMaxRead, Int(endAddr - addr))
    var got: [UInt8]?
    for attempt in 1...5 {                       // the OS driver's traffic can crowd us out
        got = readChunk(addr: addr, len: len)
        if got != nil { break }
        if attempt == 5 {
            FileHandle.standardError.write(Data(String(format: "  0x%04X: no reply after 5 tries\n", addr).utf8))
        }
    }
    guard let chunk = got else {
        failures += 1
        out.append(contentsOf: [UInt8](repeating: 0x00, count: len))
        addr += UInt32(len)
        continue
    }
    out.append(contentsOf: chunk)
    addr += UInt32(len)
}

// MARK: - Output

for row in stride(from: 0, to: out.count, by: 16) {
    let slice = out[row..<min(row + 16, out.count)]
    let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
    print(String(format: "%08X: %@", Int(startAddr) + row, hex))
}
if let outPath {
    try? Data(out).write(to: URL(fileURLWithPath: outPath))
    FileHandle.standardError.write(Data("\nwrote \(out.count) bytes to \(outPath)\n".utf8))
}
if failures > 0 {
    FileHandle.standardError.write(Data("\n\(failures) chunk(s) failed — zero-filled above.\n".utf8))
}
IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
