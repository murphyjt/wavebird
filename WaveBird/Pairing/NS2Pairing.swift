import Foundation
import Security

// Outcome of a successful 4-step NS2 BT pairing exchange. The LTK is the
// shared secret both sides now hold; primaryAddress is the host adapter
// address that was committed to the controller's flash.
struct NS2PairingResult: Sendable {
    let ltk: Data           // 16 bytes, natural (MSB-first) order
    let primaryAddress: Data // 6 bytes, natural (MSB-first) order
}

enum NS2PairingError: Error, CustomStringConvertible {
    case stepTimedOut(step: String)
    case shortResponse(step: String, got: Int)
    case ltkConfirmationMismatch
    case rngFailure

    var description: String {
        switch self {
        case .stepTimedOut(let s):       "pairing step timed out: \(s)"
        case .shortResponse(let s, let g): "pairing response too short at \(s) (got \(g) bytes)"
        case .ltkConfirmationMismatch:   "LTK confirmation did not match expected AES output"
        case .rngFailure:                "SecRandomCopyBytes failed"
        }
    }
}

// Runs the four pairing subcommands in order over a Transport. Caller is
// responsible for ensuring the device is in a state where command/response is
// active (i.e. post-`.ready`). The flow does not subscribe to anything new and
// does not change connection state; on success the controller's flash now
// recognises the host address as a paired peer.
enum NS2Pairing {
    // Response ACK header (8 bytes) per CLAUDE.md §"NS2 BLE protocol gotchas":
    //   [cmd, 0x01, 0x01, sub, 0x10, 0x78, 0x00, 0x00]
    // Followed by an "Unknown" 0x01 status byte before the actual payload for
    // subcmds 0x01/0x02/0x04. Subcmd 0x03 has no further payload.
    private static let ackHeaderLen = 8
    private static let stepTimeout: Duration = .milliseconds(500)

    static func run(
        deviceID: DeviceID,
        transport: any Transport,
        hostAddress: Data
    ) async throws -> NS2PairingResult {
        precondition(hostAddress.count == 6)
        let secondary = secondaryAddress(from: hostAddress)

        // Step 1 — Exchange addresses. We don't need anything from the response
        // body (we'd be told the controller's BT address, which we don't use),
        // but we still wait for the ack so we know the controller accepted the
        // host addresses before continuing.
        try await sendStep(
            "exchange addresses",
            frame: NS2PairingFrames.exchangeAddresses(primary: hostAddress, secondary: secondary),
            deviceID: deviceID,
            transport: transport,
            minBodyLen: 0
        )

        // Step 2 — Exchange keys. Generate ephemeral A1, receive B1, compute LTK.
        let a1 = try randomBytes(16)
        let r2 = try await sendStep(
            "exchange keys",
            frame: NS2PairingFrames.exchangeKeys(hostKey: a1),
            deviceID: deviceID,
            transport: transport,
            minBodyLen: 1 + 16
        )
        // Body layout: [0x01 status, B1_reversed[16]].
        let b1Wire = r2.dropFirst(1).prefix(16)
        let b1 = Data(b1Wire.reversed())
        let ltk = Data(zip(a1, b1).map { $0 ^ $1 })

        // Step 3 — Confirm LTK. Send challenge A2, verify B2 = AES_ECB(rev(LTK), rev(A2)).
        let a2 = try randomBytes(16)
        let r3 = try await sendStep(
            "confirm LTK",
            frame: NS2PairingFrames.confirmLTK(challenge: a2),
            deviceID: deviceID,
            transport: transport,
            minBodyLen: 1 + 16
        )
        let b2Wire = Data(r3.dropFirst(1).prefix(16))
        // The spec says B2_wire = AES(reverse(LTK_wire), reverse(A2_wire)). Our
        // frame builders already reverse A1/A2 on the way to the wire, so the
        // caller-supplied `a2` here is reverse(A2_wire); likewise `ltk` (= a1
        // XOR reverse(b1Wire)) equals reverse(LTK_wire). Both inputs are
        // therefore already in AES form — no further reversals, and no
        // reversal of the AES output either (python emits B2 directly).
        guard let expectedB2Wire = NS2PairingCrypto.aes128ECB(key: ltk, block: a2)
        else { throw NS2PairingError.ltkConfirmationMismatch }
        guard expectedB2Wire == b2Wire else { throw NS2PairingError.ltkConfirmationMismatch }

        // Step 4 — Finalise. Controller commits to flash 0x1FA000.
        _ = try await sendStep(
            "finalise",
            frame: NS2PairingFrames.finalise,
            deviceID: deviceID,
            transport: transport,
            minBodyLen: 0
        )

        return NS2PairingResult(ltk: ltk, primaryAddress: hostAddress)
    }

    // Issues one pairing frame and returns the response body (post-ACK-header).
    // Aborts the flow if the response is missing or shorter than expected.
    @discardableResult
    private static func sendStep(
        _ name: String,
        frame: Data,
        deviceID: DeviceID,
        transport: any Transport,
        minBodyLen: Int
    ) async throws -> Data {
        let resp = try await transport.sendAwaitingResponse(frame, to: deviceID, timeout: stepTimeout)
        guard let resp else { throw NS2PairingError.stepTimedOut(step: name) }
        let body = resp.data.dropFirst(ackHeaderLen)
        guard body.count >= minBodyLen else {
            throw NS2PairingError.shortResponse(step: name, got: resp.data.count)
        }
        return Data(body)
    }

    // Per memory_layout.md: the controller stores two pairing entries that
    // share the same LTK; the second is the first with its LSB decremented.
    // Addresses are in natural (MSB-first) order here, so the LSB is index 5.
    static func secondaryAddress(from primary: Data) -> Data {
        precondition(primary.count == 6)
        var bytes = Array(primary)
        bytes[5] = bytes[5] &- 1
        return Data(bytes)
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var buf = Data(count: count)
        let status = buf.withUnsafeMutableBytes { ptr -> Int32 in
            SecRandomCopyBytes(kSecRandomDefault, count, ptr.baseAddress!)
        }
        guard status == errSecSuccess else { throw NS2PairingError.rngFailure }
        return buf
    }
}
