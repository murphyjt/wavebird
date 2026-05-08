import Foundation

nonisolated enum BLEAdvertisementDecoder {
    static func decodeNintendoMfgData(_ data: Data) -> (vendorID: UInt16, productID: UInt16)? {
        guard data.count >= 9 else { return nil }
        let vid = data.uint16LE(at: 5)
        let pid = data.uint16LE(at: 7)
        return (vid, pid)
    }
}

nonisolated extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        let i = startIndex.advanced(by: offset)
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }
}
