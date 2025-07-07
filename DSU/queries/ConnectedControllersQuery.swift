import Foundation

struct ConnectedControllersQuery: Payload {
    func data(using data: Data) -> Data {
        return data  // TODO: Stub
    }

    var count: Int {
        return 4 + slots.count  // Number of ports to report on + slots of interest
    }
    var slots: [UInt8]
    /// Each byte represent number of slot you should report about. Each value is less than 4.
}

extension ConnectedControllersQuery {
    init?(from data: Data) {
        guard data.count >= 4 else {
            return nil
        }
        let count: Int = Int(
            data.withUnsafeBytes {
                $0.load(as: Int32.self)
            }
        )

        // Extra data is discarded
        guard data.count >= 4 + count else {
            return nil
        }
        let baseOffset = data.startIndex
        self.slots = data[baseOffset + 4..<baseOffset + 4 + count].map {
            UInt8($0)
        }
    }
}

extension ConnectedControllersQuery: CustomStringConvertible {
    var description: String {
        return "ConnectedControllersQuery(\(slots))"
    }
}
