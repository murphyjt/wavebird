import Foundation

struct Packet {
    var header: Header
    var payload: Payload
}

extension Packet {
    init?(from data: Data) throws {
        self.header = .init(from: data)!
        print("Building payload for event: \(header.eventType)")
        guard
            let payload = IncomingPayloadFactory.make(
                self.header.eventType,
                from: data.suffix(from: header.count)
            )
        else {
            throw NSError(domain: "Invalid payload", code: 0, userInfo: nil)
        }
        self.payload = payload
        // TODO: Maybe this is the right place to verify the CRC32?
    }
}

extension Packet {
    mutating func toData() -> Data {
        header.length += UInt16(payload.count)
        var data = Data(capacity: header.count + Int(payload.count))
        data = header.data(using: data)
        data = payload.data(using: data)
        CRC32Utility.insert(into: &data, at: 8..<12)
        return data
    }
}
