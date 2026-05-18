import CommonCrypto
import Foundation

// NS2 Bluetooth pairing command frames (command 0x15, subcommands 0x01..0x04).
//
// The controller does NOT use SMP — Nintendo runs their own pseudo-OOB key
// exchange over the same command channel (write 0x0014, response 0x001A) as
// the rest of init. Frame envelope is identical to NS2Commands:
//   [cmdID, 0x91, 0x01, subID, 0x00, payloadLen, 0x00, 0x00, …payload]
//
// All multi-byte fields on the wire (addresses, keys, challenges, AES
// ciphertext) are transmitted byte-reversed. Callers pass values in natural
// (MSB-first) order; reversal happens inside these builders so callers don't
// have to think about wire-order.
//
// References:
// - ndeadly switch2_controller_research/commands.md §Command-0x15
// - ndeadly switch2_controller_research/bluetooth_interface.md §Pairing
enum NS2PairingFrames {
    // Cmd 0x15/0x01 — Exchange addresses.
    // Payload: [0x00, count, host_addr_reversed[6] * count].
    // The console always sends count=2 with the second address being the first
    // with its LSB decremented by one; that derivation is the caller's job
    // (see NS2Pairing.secondaryAddress).
    static func exchangeAddresses(primary: Data, secondary: Data) -> Data {
        precondition(primary.count == 6 && secondary.count == 6)
        var payload = Data([0x00, 0x02])
        payload.append(Data(primary.reversed()))
        payload.append(Data(secondary.reversed()))
        return frame(cmd: 0x15, sub: 0x01, payload: payload)
    }

    // Cmd 0x15/0x04 — Exchange keys.
    // Payload: [0x00, A1_reversed[16]]. Response carries B1_reversed; the
    // documented value of B1 in natural order is 5CF6EE792CDF05E1BA2B6325C41A5F10.
    static func exchangeKeys(hostKey a1: Data) -> Data {
        precondition(a1.count == 16)
        var payload = Data([0x00])
        payload.append(Data(a1.reversed()))
        return frame(cmd: 0x15, sub: 0x04, payload: payload)
    }

    // Cmd 0x15/0x02 — Confirm LTK challenge/response.
    // Payload: [0x00, A2_reversed[16]]. Response carries B2_reversed where
    // B2 = AES128_ECB(key: reverse(LTK), plaintext: reverse(A2)).
    static func confirmLTK(challenge a2: Data) -> Data {
        precondition(a2.count == 16)
        var payload = Data([0x00])
        payload.append(Data(a2.reversed()))
        return frame(cmd: 0x15, sub: 0x02, payload: payload)
    }

    // Cmd 0x15/0x03 — Finalise pairing. The controller commits host
    // addresses + LTK to its flash at 0x1FA000.
    static let finalise: Data = frame(cmd: 0x15, sub: 0x03, payload: Data([0x00]))

    private static func frame(cmd: UInt8, sub: UInt8, payload: Data) -> Data {
        precondition(payload.count <= Int(UInt8.max))
        var out = Data([cmd, 0x91, 0x01, sub, 0x00, UInt8(payload.count), 0x00, 0x00])
        out.append(payload)
        return out
    }
}

// AES-128 ECB for the single 16-byte LTK confirmation block. CryptoKit does
// not expose ECB; this is the smallest CommonCrypto wrapper that gets the job
// done. ECB is correct here precisely because we only ever encrypt one block.
enum NS2PairingCrypto {
    static func aes128ECB(key: Data, block: Data) -> Data? {
        precondition(key.count == 16 && block.count == 16)
        var out = Data(count: 16)
        var bytesWritten = 0
        let status = key.withUnsafeBytes { keyPtr -> Int32 in
            block.withUnsafeBytes { blockPtr -> Int32 in
                out.withUnsafeMutableBytes { outPtr -> Int32 in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, 16,
                        nil,
                        blockPtr.baseAddress, 16,
                        outPtr.baseAddress, 16,
                        &bytesWritten
                    )
                }
            }
        }
        guard status == kCCSuccess, bytesWritten == 16 else { return nil }
        return out
    }
}
