import Foundation

enum ControllerDataQueryType: Int {
    case All = 0
    case Slot = 1
    case MAC = 2
}

struct ControllerDataQuery: Payload {
    let count = 8

    var type: ControllerDataQueryType
    var slot: UInt8 = 0
    var mac: Data = Data(repeating: 0, count: 6)

    func data(using data: Data) -> Data {
        return data
    }

    init?(from data: Data) {
        guard data.count >= count else { return nil }
        self.type = data.withUnsafeBytes {
            $0.load(fromByteOffset: 0, as: ControllerDataQueryType.self)
        }
        self.slot = data.withUnsafeBytes {
            $0.load(fromByteOffset: 1, as: UInt8.self)
        }
        let base = data.startIndex
        self.mac = data[base + 2..<base + 8]
    }
}
