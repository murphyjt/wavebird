import Foundation
import zlib

struct CRC32Utility {
    /// Calculates CRC32 of a `Data` buffer, zeroing out a subrange (e.g., the CRC32 field itself).
    static func calculate(data: Data, zeroing range: Range<Int>) -> UInt32 {
        var crc: UInt = 0

        guard range.lowerBound >= 0, range.upperBound <= data.count else {
            fatalError("CRC zeroing range out of bounds")
        }

        data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)

            if range.lowerBound > 0 {
                crc = crc32(crc, ptr, UInt32(range.lowerBound))
            }

            let zeros = [UInt8](repeating: 0, count: range.count)
            crc = crc32(crc, zeros, UInt32(zeros.count))

            let afterStart = range.upperBound
            let afterLength = data.count - afterStart
            if afterLength > 0 {
                crc = crc32(
                    crc,
                    ptr.advanced(by: afterStart),
                    UInt32(afterLength)
                )
            }
        }

        return UInt32(truncatingIfNeeded: crc)
    }

    /// Verifies CRC32 stored in `crcRange` matches calculated value (assumes little-endian).
    static func verify(data: Data, crcRange: Range<Int>) -> Bool {
        guard crcRange.count == 4,
            crcRange.upperBound <= data.count
        else {
            return false
        }

        let expectedCRC: UInt32 = data.subdata(in: crcRange).withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }

        let actualCRC = calculate(data: data, zeroing: crcRange)
        return actualCRC == expectedCRC
    }

    /// Inserts the calculated CRC32 into the `data` at `crcRange`, encoded as little-endian.
    static func insert(into data: inout Data, at crcRange: Range<Int>) {
        let crc = calculate(data: data, zeroing: crcRange)
        var littleEndianCRC = crc.littleEndian

        guard crcRange.count == 4,
            crcRange.upperBound <= data.count
        else {
            fatalError("CRC insert range out of bounds or incorrect size")
        }

        withUnsafeBytes(of: &littleEndianCRC) { crcBytes in
            data.replaceSubrange(crcRange, with: crcBytes)
        }
    }
}
