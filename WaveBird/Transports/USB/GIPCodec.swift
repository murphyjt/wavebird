import Foundation

// MARK: - GIP (Game Input Protocol) codec
//
// Wire format for Xbox controllers over the wired vendor interface.
// This implementation was written from the documented wire format; the Linux
// driver project medusalix/xone was consulted as a reference for protocol
// facts (field layouts, GUIDs, command numbers), which are interoperability
// data rather than original code.
//
// Every packet on the interrupt pipe looks like:
//   [command][options][sequence][packet_length varint][(chunk_offset varint
//    if CHUNK)] [payload …]
//
//   • command       — message type (GIPCommand)
//   • options       — client id in the low nibble + flag bits (GIPOptions)
//   • sequence      — increments per adapter; zero is never used
//   • packet_length — varint. The header as a whole is padded to an even
//     number of bytes by OR-ing 0x80 into the LAST length byte and appending
//     a 0x00 byte; that pad byte decodes as an empty continuation, so it
//     contributes nothing to the length.
//   • chunk_offset  — varint; present only when the CHUNK flag is set.
//
// Small messages fit in a single packet (payload ≤ 58). Anything larger
// (identify info blocks are 1–3 KB) is split into chunks: the first chunk
// carries CHUNK|CHUNK_START with chunk_offset = TOTAL transfer length, the
// middle chunks carry CHUNK with their running offset, the last payload
// chunk carries CHUNK|ACKNOWLEDGE, and a final header-only packet (length 0,
// chunk_offset = TOTAL) marks the end. Every packet with ACKNOWLEDGE set
// must be answered with an internal ACK (command 0x01) or the controller
// will retransmit.

enum GIP {
    // Framing limits
    static let headerMinLength = 3
    static let packetMaxLength = 58
    static let chunkBufferMax = 0xFFFF

    // Identity / discovery facts
    static let vidMicrosoft: UInt16 = 0x045E
    // Xbox Wireless Adapters also speak GIP, but over an MT76 radio link that
    // needs its own firmware — never claim them even though they expose the
    // same vendor interface shape.
    static let adapterProductIDs: Set<UInt16> = [0x02E6, 0x02FE, 0x02F9, 0x091E]

    // Interface GUIDs advertised inside the identify info block. Stored in
    // the native little-endian byte order the wire uses.
    static let shareButtonGUID = Data([
        0xFE, 0xD2, 0xDD, 0xEC, 0x87, 0xD3, 0x94, 0x42,
        0xBD, 0x96, 0x1A, 0x71, 0x2E, 0x3D, 0xC7, 0x7D,
    ])  // ECDDD2FE-D387-4294-BD96-1A712E3DC77D

    static let dliCounterGUID = Data([
        0x6B, 0xE5, 0xF2, 0x87, 0xBB, 0xC3, 0xB1, 0x49,
        0x82, 0x65, 0xFF, 0xFF, 0xF3, 0x77, 0x99, 0xEE,
    ])  // 87F2E56B-C3BB-49B1-8265-FFFFF37799EE

    // The wired GIP interface is identified by its class triplet on
    // interface #0 — not by vendor/product IDs.
    static let gipInterfaceClass    = 0xFF
    static let gipInterfaceSubclass = 0x47
    static let gipInterfaceProtocol = 0xD0

    // Gamepad attribute facts
    static let gamepadClass = "Windows.Xbox.Input.Gamepad"
    static let shareByteOffsetFromEnd = 18 // byte the Share state rides on

    // Status/battery bit for status packets
    static let statusConnected: UInt8 = 0x80
}

enum GIPCommand: UInt8 {
    case acknowledge   = 0x01
    case announce      = 0x02
    case status        = 0x03
    case identify      = 0x04
    case power         = 0x05
    case authenticate  = 0x06
    case virtualKey    = 0x07
    case audioControl  = 0x08
    case rumble        = 0x09
    case led           = 0x0A
    case hidReport     = 0x0B
    case firmware      = 0x0C
    case serialNumber  = 0x1E
    case input         = 0x20
    case audioSamples  = 0x60
}

struct GIPOptions: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt8

    static let acknowledge = GIPOptions(rawValue: 0x10)
    static let `internal`  = GIPOptions(rawValue: 0x20)
    static let chunkStart  = GIPOptions(rawValue: 0x40)
    static let chunk       = GIPOptions(rawValue: 0x80)

    var clientID: UInt8 { rawValue & 0x0F }
    var containsChunk: Bool { rawValue & GIPOptions.chunk.rawValue != 0 }
    var containsChunkStart: Bool { rawValue & GIPOptions.chunkStart.rawValue != 0 }
    var containsAcknowledge: Bool { rawValue & GIPOptions.acknowledge.rawValue != 0 }
    var containsInternal: Bool { rawValue & GIPOptions.internal.rawValue != 0 }
}

struct GIPHeader: Sendable, Equatable {
    var command: GIPCommand
    var options: GIPOptions
    var sequence: UInt8
    var packetLength: Int
    var chunkOffset: Int = 0
}

struct GIPMessage: Sendable {
    let header: GIPHeader
    let payload: Data
}

// MARK: - varints

enum GIPVarint {
    static func encode(_ value: UInt32, into out: inout [UInt8]) -> Int {
        // 7 bits per byte, high bit = "more bytes follow".
        var v = value
        var i = 0
        while i < MemoryLayout<UInt32>.size {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
            i += 1
            if v == 0 { break }
        }
        return i
    }

    static func decode(_ data: Data, at start: Int) -> (value: UInt32, consumed: Int)? {
        // All indices are relative to data.startIndex: a Data slice keeps its
        // storage offset, so 0-based absolute indexing would read out of
        // range — the crash this parser hit the moment the pad streamed.
        var value: UInt32 = 0
        var i = 0
        let base = data.startIndex + start
        while i < MemoryLayout<UInt32>.size && base + i < data.endIndex {
            let b = data[base + i]
            value |= UInt32(b & 0x7F) << (i * 7)
            i += 1
            if b & 0x80 == 0 { break }
        }
        guard i > 0 else { return nil }
        return (value, i)
    }
}

// MARK: - header encode/decode

enum GIPHeaderCodec {
    /// Header size WITHOUT the even-padding byte.
    static func actualHeaderLength(packetLength: Int, chunkOffset: Int, isChunk: Bool) -> Int {
        var len = GIP.headerMinLength
        var v = UInt32(packetLength)
        repeat {
            len += 1
            v >>= 7
        } while v != 0
        if isChunk {
            var o = UInt32(chunkOffset)
            while o != 0 {
                len += 1
                o >>= 7
            }
        }
        return len
    }

    /// Header size rounded up to an even byte count.
    static func headerLength(packetLength: Int, chunkOffset: Int, isChunk: Bool) -> Int {
        let len = actualHeaderLength(packetLength: packetLength, chunkOffset: chunkOffset, isChunk: isChunk)
        return len + (len % 2)
    }

    static func encode(_ header: GIPHeader) -> Data {
        var out: [UInt8] = [header.command.rawValue, header.options.rawValue, header.sequence]
        _ = GIPVarint.encode(UInt32(header.packetLength), into: &out)
        if actualHeaderLength(packetLength: header.packetLength,
                              chunkOffset: header.chunkOffset,
                              isChunk: header.options.containsChunk) % 2 != 0 {
            out[out.count - 1] |= 0x80   // mark the odd (padded) length field
            out.append(0x00)
        }
        if header.options.containsChunk {
            _ = GIPVarint.encode(UInt32(header.chunkOffset), into: &out)
        }
        return Data(out)
    }

    /// Returns (header, headerLength) or nil if the data is too short.
    static func decode(_ data: Data) -> (header: GIPHeader, headerLength: Int)? {
        guard data.count >= GIP.headerMinLength else { return nil }
        // startIndex-relative: Data may be a slice (removeFirst advances
        // startIndex instead of rebasing), and absolute data[0]/[1]/[2]
        // indexing on such a slice is exactly the trap that killed the read
        // loop once a pad streamed its first packet.
        let s = data.startIndex
        var header = GIPHeader(command: .acknowledge, options: GIPOptions(rawValue: 0), sequence: 0, packetLength: 0)
        header.command = GIPCommand(rawValue: data[s]) ?? .acknowledge
        header.options = GIPOptions(rawValue: data[s + 1])
        header.sequence = data[s + 2]

        guard let (length, consumed) = GIPVarint.decode(data, at: 3) else { return nil }
        var headerLength = 3 + consumed
        header.packetLength = Int(length)

        if header.options.containsChunk {
            guard let (offset, consumed2) = GIPVarint.decode(data, at: headerLength) else { return nil }
            header.chunkOffset = Int(offset)
            headerLength += consumed2
        }
        return (header, headerLength)
    }
}

// MARK: - inbound stream assembly

/// Turns a byte stream from the interrupt pipe into complete messages,
/// concatenating consecutive packets and reassembling chunked transfers.
struct GIPStreamParser {
    private(set) var pending = Data()              // unconsumed bytes from the pipe
    private var assembly: TransferAccumulator?

    /// One chunked inbound transfer being assembled. `options` and
    /// `sequence` are kept from the FIRST chunk so the completed message can
    /// be reconstructed with the transfer's own identity.
    struct TransferAccumulator {
        var totalLength: Int
        var command: GIPCommand
        var options: GIPOptions
        var sequence: UInt8
        var data = Data()

        mutating func append(_ payload: Data) {
            data.append(payload)
        }
    }

    /// An ACK the controller is owed because its packet carried the ACK bit.
    /// Chunked transfers are ACKed PER CHUNK — the pad sends chunk N+1 only
    /// after chunk N is acknowledged — even though no complete message is
    /// visible until the last chunk, so the parser must surface ACK requests
    /// separately or the pad retransmits chunk 1 forever.
    struct GIPAckRequest {
        let command: GIPCommand
        let options: GIPOptions
        let ackedLength: Int
        let total: Int?
    }

    private(set) var ackRequests: [GIPAckRequest] = []

    /// Removes and returns the ACKs owed so far (call after each feed).
    mutating func drainAcks() -> [GIPAckRequest] {
        let acks = ackRequests
        ackRequests = []
        return acks
    }

    /// Total length of the in-flight chunked transfer, if any (the ACK path
    /// uses it to compute `remaining`).
    var assemblyTotal: Int? { assembly?.totalLength }

    /// Feeds raw endpoint bytes and returns complete messages in order.
    /// Several GIP packets may share one USB transfer, and one packet may
    /// straddle two transfers, so the buffer is drained greedily.
    mutating func feed(_ bytes: Data) -> [GIPMessage] {
        pending.append(bytes)
        var out: [GIPMessage] = []
        while true {
            guard let (header, headerLength) = GIPHeaderCodec.decode(pending) else { break }
            guard pending.count >= headerLength + header.packetLength else { break }
            // Absolute indices in the Data's own coordinate space.
            let start = pending.startIndex
            let payload = pending.subdata(in: (start + headerLength)..<(start + headerLength + header.packetLength))
            // Rebase to index 0 — subdata(in:) copies into fresh storage —
            // because every 0-based parser below assumes startIndex == 0.
            pending = pending.subdata(in: (start + headerLength + header.packetLength)..<pending.endIndex)

            if header.options.containsChunkStart {
                // First chunk of a transfer: chunk_offset holds the TOTAL
                // length, and this chunk's running offset is treated as 0.
                guard header.chunkOffset <= GIP.chunkBufferMax, header.chunkOffset > 0 else { continue }
                assembly = TransferAccumulator(totalLength: header.chunkOffset,
                                               command: header.command,
                                               options: header.options,
                                               sequence: header.sequence)
            }

            // ACK requirements are recorded before dispatch, matching the
            // controller's expectation: every ACK-bit packet is acknowledged
            // as it arrives. The ACK's `ackedLength` mirrors the wire rule —
            // the first chunk reports just its own length (its stored offset
            // is the TOTAL, which must not be counted), later chunks report
            // offset + length.
            if header.options.containsAcknowledge {
                ackRequests.append(GIPAckRequest(
                    command: header.command,
                    options: header.options,
                    ackedLength: header.options.containsChunkStart
                        ? header.packetLength
                        : header.chunkOffset + header.packetLength,
                    total: header.options.containsChunk ? assembly?.totalLength : nil))
            }

            if header.options.containsChunk {
                guard var asm = assembly else {
                    // No transfer open: drop. (Some older pads send extra
                    // empty completions; those are also dropped here.)
                    continue
                }
                if header.command != asm.command { continue }   // conflicting packet
                if header.packetLength == 0 {
                    // Empty chunk = transfer complete. The completed message
                    // belongs to the ORIGINAL transfer, so it carries the
                    // first chunk's options/sequence (with ACK + CHUNK_START
                    // cleared) rather than the empty completion chunk's own
                    // header — otherwise a reassembled identify would be
                    // dispatched with CHUNK-only options and no INTERNAL bit.
                    let done = asm.data
                    assembly = nil
                    var finalHeader = header
                    finalHeader.options = GIPOptions(rawValue: asm.options.rawValue
                        & ~(GIPOptions.acknowledge.rawValue | GIPOptions.chunkStart.rawValue))
                    finalHeader.sequence = asm.sequence
                    out.append(GIPMessage(header: finalHeader, payload: done))
                } else {
                    asm.append(payload)
                    assembly = asm
                }
            } else {
                out.append(GIPMessage(header: header, payload: payload))
            }
        }
        return out
    }
}

// MARK: - outbound packet builders

enum GIPOutbound {
    /// Ask the controller for its identity info block (cmd 0x04, INTERNAL,
    /// no payload).
    static func identify(clientID: UInt8, sequence: UInt8) -> Data {
        let header = GIPHeader(command: .identify,
                               options: GIPOptions(rawValue: (clientID & 0x0F) | GIPOptions.internal.rawValue),
                               sequence: sequence, packetLength: 0)
        return GIPHeaderCodec.encode(header)
    }

    /// Wake the controller (power mode ON = 0x00).
    static func powerOn(clientID: UInt8, sequence: UInt8) -> Data {
        let header = GIPHeader(command: .power,
                               options: GIPOptions(rawValue: (clientID & 0x0F) | GIPOptions.internal.rawValue),
                               sequence: sequence, packetLength: 1)
        return GIPHeaderCodec.encode(header) + Data([0x00])
    }

    /// Guide-ring LED — best effort (the 1537 lights the ring anyway).
    static func led(clientID: UInt8, sequence: UInt8, mode: UInt8 = 0x01, brightness: UInt8 = 0x64) -> Data {
        let header = GIPHeader(command: .led,
                               options: GIPOptions(rawValue: (clientID & 0x0F) | GIPOptions.internal.rawValue),
                               sequence: sequence, packetLength: 3)
        return GIPHeaderCodec.encode(header) + Data([0x00, mode, brightness])
    }

    /// Rumble (cmd 0x09). NOTE: the options carry only the client id — no
    /// INTERNAL bit — which is how the controller recognises rumble frames.
    static func rumble(clientID: UInt8, sequence: UInt8, payload: Data) -> Data {
        let header = GIPHeader(command: .rumble,
                               options: GIPOptions(rawValue: clientID & 0x0F),
                               sequence: sequence, packetLength: payload.count)
        return GIPHeaderCodec.encode(header) + payload
    }

    /// Internal ACK (cmd 0x01), 9-byte payload:
    /// [unknown, command, options, length u16le, pad[2], remaining u16le].
    /// `length`    = acked chunk_offset + acked packet_length
    /// `remaining` = total inbound transfer length − acked length (chunked only)
    static func acknowledge(clientID: UInt8, sequence: UInt8,
                            ackedCommand: GIPCommand, ackedOptions: GIPOptions,
                            ackedLength: Int, transferTotal: Int?) -> Data {
        let opts = GIPOptions(rawValue: (clientID & 0x0F) | GIPOptions.internal.rawValue)
        let header = GIPHeader(command: .acknowledge, options: opts, sequence: sequence, packetLength: 9)
        let length = UInt16(clamping: ackedLength)
        var remaining: UInt16 = 0
        if ackedOptions.containsChunk, let total = transferTotal {
            remaining = UInt16(clamping: total - ackedLength)
        }
        var payload = [
            0x00,
            ackedCommand.rawValue,
            ackedOptions.rawValue & 0x0F,
            UInt8(length & 0xFF), UInt8(length >> 8),
            0x00, 0x00,
            UInt8(remaining & 0xFF), UInt8(remaining >> 8),
        ]
        return GIPHeaderCodec.encode(header) + Data(payload)
    }
}

// MARK: - identify info block

struct GIPIdentifyInfo: Sendable {
    var clientCommands: [(command: UInt8, length: UInt8, options: UInt8)] = []
    var firmwareVersions: [(major: UInt16, minor: UInt16)] = []
    var audioFormats: [UInt16] = []
    var classes: [String] = []
    var interfaces: [Data] = []        // 16-byte GUIDs
    var hidDescriptor: Data? = nil

    var isGamepad: Bool { classes.contains(GIP.gamepadClass) }
    // Share-button presence (pads advertising the share GUID — 1697 S,
    // Series X|S, Elite 2, GameSir G7 Pro, …). The original 1537 never
    // advertises it.
    var supportsShare: Bool { interfaces.contains(GIP.shareButtonGUID) }
    // Dynamic-latency-input counter pads (Series X|S wired). Changes where
    // the share byte sits relative to the end of the input packet.
    var supportsDLI: Bool { interfaces.contains(GIP.dliCounterGUID) }

    /// `payload` is the full IDENTIFY message body.
    ///
    /// Layout: a 16-byte header, then a table of 8 u16le element offsets
    /// (measured from payload+16), then the elements themselves. Each
    /// element is `count` followed by `count` fixed-size records — except
    /// classes, where each record is a u16le-length-prefixed ASCII string.
    /// An offset of 0 means the element is absent.
    static func parse(_ payload: Data) -> GIPIdentifyInfo? {
        guard payload.count >= 16 + 16 else { return nil }
        var info = GIPIdentifyInfo()

        func offset(_ index: Int) -> Int {
            Int(payload[16 + index * 2]) | (Int(payload[17 + index * 2]) << 8)
        }
        func element(at rawOffset: Int, itemLength: Int? = nil) -> (count: Int, bytes: Data)? {
            guard rawOffset != 0 else { return nil }         // absent when 0
            let base = 16 + rawOffset
            guard base < payload.count else { return nil }
            let count = Int(payload[base])
            guard count > 0 else { return nil }
            if let itemLength {
                let total = count * itemLength
                guard base + 1 + total <= payload.count else { return nil }
                return (count, payload.subdata(in: (base + 1)..<(base + 1 + total)))
            }
            return (count, Data()) // variable-length (classes) — handled below
        }

        // client commands: count × 24-byte descriptor
        if let (count, bytes) = element(at: offset(0), itemLength: 24) {
            for i in 0..<count {
                let b = bytes.subdata(in: (i * 24)..<(i * 24 + 24))
                // descriptor: marker,u1,cmd,len,u2[3],options,u3[15]
                if b.count == 24 {
                    info.clientCommands.append((command: b[2], length: b[3], options: b[7]))
                }
            }
        }
        // firmware versions: count × (u16le major, u16le minor)
        if let (count, bytes) = element(at: offset(1), itemLength: 4) {
            for i in 0..<count {
                let b = bytes.subdata(in: (i * 4)..<(i * 4 + 4))
                if b.count == 4 {
                    info.firmwareVersions.append((major: UInt16(b[0]) | UInt16(b[1]) << 8,
                                                  minor: UInt16(b[2]) | UInt16(b[3]) << 8))
                }
            }
        }
        // audio formats: count × u16le
        if let (count, bytes) = element(at: offset(2), itemLength: 2) {
            for i in 0..<count {
                let b = bytes.subdata(in: (i * 2)..<(i * 2 + 2))
                if b.count == 2 {
                    info.audioFormats.append(UInt16(b[0]) | UInt16(b[1]) << 8)
                }
            }
        }
        // classes: count, then [u16le length + ASCII] per class
        let classesOff = offset(5)
        if classesOff != 0 {
            let base = 16 + classesOff
            if base < payload.count {
                let count = Int(payload[base])
                var p = base + 1
                for _ in 0..<count {
                    guard p + 2 <= payload.count else { break }
                    let strLen = Int(payload[p]) | (Int(payload[p + 1]) << 8)
                    p += 2
                    guard p + strLen <= payload.count, strLen > 0 else { break }
                    if let s = String(bytes: payload[p..<(p + strLen)], encoding: .ascii) {
                        info.classes.append(s)
                    }
                    p += strLen
                }
            }
        }
        // interfaces: count × 16-byte GUID
        if let (count, bytes) = element(at: offset(6), itemLength: 16) {
            for i in 0..<count {
                let b = bytes.subdata(in: (i * 16)..<(i * 16 + 16))
                if b.count == 16 { info.interfaces.append(b) }
            }
        }
        return info
    }
}

// MARK: - gamepad input

struct GIPGamepadInput: Sendable {
    var buttons: UInt16
    var triggerLeft: UInt16     // 0..1023
    var triggerRight: UInt16    // 0..1023
    var stickLeftX: Int16
    var stickLeftY: Int16       // positive = up
    var stickRightX: Int16
    var stickRightY: Int16      // positive = up

    /// The Share byte always rides at a fixed offset from the END of the
    /// packet (18; DLI pads add their 8-byte counter → 26). Returns nil when
    /// the packet is too short to carry it.
    static func shareByte(payload: Data, supportsDLI: Bool) -> UInt8? {
        let offset = GIP.shareByteOffsetFromEnd + (supportsDLI ? 8 : 0)
        guard payload.count >= offset else { return nil }
        return payload[payload.count - offset]
    }

    static func parse(_ payload: Data) -> GIPGamepadInput? {
        guard payload.count >= 14 else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(payload[i]) | (UInt16(payload[i + 1]) << 8) }
        return GIPGamepadInput(buttons: u16(0),
                               triggerLeft: u16(2),
                               triggerRight: u16(4),
                               stickLeftX: Int16(bitPattern: u16(6)),
                               stickLeftY: Int16(bitPattern: u16(8)),
                               stickRightX: Int16(bitPattern: u16(10)),
                               stickRightY: Int16(bitPattern: u16(12)))
    }
}

// MARK: - rumble

enum GIPRumble {
    // Motor indices inside the rumble frame.
    static let motorR: UInt8  = 0x01
    static let motorL: UInt8  = 0x02
    static let motorRT: UInt8 = 0x04
    static let motorLT: UInt8 = 0x08

    static let stopMotors = motorR | motorL | motorRT | motorLT
    static let stopDuration: UInt8 = 0xFF
    static let stopRepeat: UInt8 = 0xEB

    /// 16-bit magnitude (0..65535) → 0..100.
    static func amplitude(_ magnitude: UInt16) -> UInt8 {
        UInt8(min(100, (Int(magnitude) * 100 + 32767) / 65535))
    }

    /// Builds the 9-byte rumble payload:
    /// [unknown, motors, LT, RT, L, R, duration, delay, repeat].
    /// Trigger amplitudes (impulse triggers / GameSir trigger rumble) ride in
    /// the LT/RT fields; pads without trigger motors ignore them. Duration
    /// 0xFF = run until the stop frame (xone leaves duration=0xFF and
    /// repeat=0xEB on live frames too — only the amplitudes change; 0x00
    /// duration = 0 ms, which the pad honours as an immediate stop, so it
    /// must never appear on an active frame). All-zero amplitudes produce the
    /// classic stop frame (max duration, all motors), which some pads also
    /// need to start emitting input.
    static func payload(leftAmp: UInt16, rightAmp: UInt16,
                        leftTriggerAmp: UInt16 = 0, rightTriggerAmp: UInt16 = 0) -> Data {
        let l = amplitude(leftAmp)
        let r = amplitude(rightAmp)
        let lt = amplitude(leftTriggerAmp)
        let rt = amplitude(rightTriggerAmp)
        let complete = l > 0 || r > 0 || lt > 0 || rt > 0
        if !complete {
            return Data([0x00, stopMotors, 0x00, 0x00, 0x00, 0x00, stopDuration, 0x00, stopRepeat])
        }
        return Data([0x00, stopMotors, lt, rt, l, r, stopDuration, 0x00, stopRepeat])
    }
}
