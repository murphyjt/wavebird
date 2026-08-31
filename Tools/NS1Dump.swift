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
    var wantAddr: UInt32?
    var data: [UInt8]?
}
let pending = Pending()
var reportBuffer = [UInt8](repeating: 0, count: 64)

let inputCallback: IOHIDReportCallback = { _, _, _, _, reportID, report, length in
    guard length >= 20 else { return }
    let b = UnsafeBufferPointer(start: report, count: length)
    // Bluetooth frames carry the ID in byte 0; USB-style stacks strip it into
    // reportID. Accept either shape.
    let f: [UInt8] = (b[0] == 0x21) ? Array(b) : ([UInt8(reportID)] + Array(b))
    guard f.count >= 20, f[0] == 0x21, f[14] == 0x10 else { return }
    let echoed = UInt32(f[15]) | UInt32(f[16]) << 8 | UInt32(f[17]) << 16 | UInt32(f[18]) << 24
    guard let want = pending.wantAddr, echoed == want else { return }   // ignore the driver's frames
    let n = Int(f[19])
    guard f.count >= 20 + n else { return }
    pending.data = Array(f[20..<(20 + n)])
}

// MARK: - Device

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [
    kIOHIDVendorIDKey as String: kVID,
    kIOHIDProductIDKey as String: kPID,
] as CFDictionary)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))

// CRITICAL: WaveBird's own virtual Switch Pro presentation uses the SAME
// VID/PID (0x057E/0x2009). Dumping it would return the synthetic flash this
// tool exists to check — a self-confirming result that looks like success.
// Reject anything not on a real transport, and say which device was chosen.
func str(_ d: IOHIDDevice, _ key: String) -> String? {
    IOHIDDeviceGetProperty(d, key as CFString) as? String
}
let candidates = (IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>) ?? []
let real = candidates.filter { (str($0, kIOHIDTransportKey) ?? "").lowercased() != "virtual" }
for d in candidates where !real.contains(d) {
    FileHandle.standardError.write(Data(
        "skipping virtual device (serial \(str(d, kIOHIDSerialNumberKey) ?? "?")) — that's WaveBird's own spoof\n".utf8))
}
guard let dev = real.first else {
    FileHandle.standardError.write(Data("""
        No REAL Switch 1 Pro Controller found (VID 0x057E / PID 0x2009 on a non-virtual transport).
        Pair it in System Settings > Bluetooth and press a button so it connects.
        \n
        """.utf8))
    exit(1)
}
FileHandle.standardError.write(Data(
    "using: transport=\(str(dev, kIOHIDTransportKey) ?? "?") serial=\(str(dev, kIOHIDSerialNumberKey) ?? "?")\n".utf8))
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
