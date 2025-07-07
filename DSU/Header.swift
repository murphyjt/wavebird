import Foundation

// Numbers are little-endian in DSU
enum Magic: UInt32 {
    /// DSUC
    case Client = 0x4453_5543
    /// DSUS
    case Server = 0x4453_5553
}

enum Version: UInt16 {
    case v1 = 0x03E9/// 1001
}

/// Length of packet without header but including event type
typealias PacketLength = UInt16

typealias CRC32 = UInt32

/// Client or server ID who sent this packet
typealias SenderID = UInt32

/// Not actually part of header so it counts as length
enum EventType: UInt32 {
    /// Protocol version information (doesn’t seem to be ever requested)
    case Version = 0x100000
    /// Information about connected controllers
    case ConnectedControllers = 0x0010_0001
    /// Actual controllers data
    case ControllerData = 0x100002
    /// (Unofficial) Information about controller motors
    case ControllerMotors = 0x110001
    /// (Unofficial) Rumble controller motor
    case ControllerRumble = 0x110002
}

struct Header {
    var magic: Magic = .Server
    var version: Version = .v1
    /// Event type is 4 bytes. Add payload size to this
    var length: PacketLength = 4
    var senderID: SenderID = 0
    var crc32: CRC32 = 0
    var eventType: EventType = .Version

    init() {}

    /// Minimal-copy initializer. Checksum isn't verified
    init?(from data: Data) {
        guard data.count >= count else { return nil }
        self.magic = data.withUnsafeBytes {
            $0.load(fromByteOffset: 0, as: Magic.self)
        }
        self.version = data.withUnsafeBytes {
            $0.load(fromByteOffset: 4, as: Version.self)
        }
        self.length = data.withUnsafeBytes {
            $0.load(fromByteOffset: 6, as: PacketLength.self)
        }
        self.senderID = data.withUnsafeBytes {
            $0.load(fromByteOffset: 8, as: SenderID.self)
        }
        self.crc32 = data.withUnsafeBytes {
            $0.load(fromByteOffset: 12, as: CRC32.self)
        }
        self.eventType = data.withUnsafeBytes {
            $0.load(fromByteOffset: 16, as: EventType.self)
        }
    }
}

extension Header: Payload {
    var count: Int {
        return 20
    }
    func data(using data: Data) -> Data {
        var data = data
        withUnsafeBytes(of: magic.rawValue.bigEndian) {
            data.append(contentsOf: $0)
        }
        withUnsafeBytes(of: version.rawValue) {
            data.append(contentsOf: $0)
        }
        withUnsafeBytes(of: length) {
            data.append(contentsOf: $0)
        }
        withUnsafeBytes(of: senderID) {
            data.append(contentsOf: $0)
        }
        withUnsafeBytes(of: crc32) {
            data.append(contentsOf: $0)
        }
        withUnsafeBytes(of: eventType.rawValue) {
            data.append(contentsOf: $0)
        }
        return data
    }
}
