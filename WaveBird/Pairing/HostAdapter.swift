@preconcurrency import IOBluetooth

// macOS host Bluetooth adapter info. NS2 pairing requires the host's 6-byte BT
// address — the value the controller will store at flash 0x1FA000 and key all
// future auto-reconnect / wake-from-sleep behavior against. CoreBluetooth does
// not expose this; IOBluetooth is the only public surface that does.
//
// Sandbox: works with `com.apple.security.device.bluetooth` already in
// WaveBird.entitlements. No additional entitlement or usage-description key.
enum HostAdapter {
    // Returns the adapter address in natural (MSB-first) order, e.g. for
    // "AA:BB:CC:DD:EE:FF" the bytes are [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF].
    // NS2 pairing frames transmit it byte-reversed; the reversal lives in
    // NS2PairingFrames so callers don't have to think about wire-order.
    static func address() -> Data? {
        guard let controller = IOBluetoothHostController.default() else { return nil }
        return parse(controller.addressAsString())
    }

    // IOBluetoothHostController returns "aa-bb-cc-dd-ee-ff" with hyphens; accept
    // colons too in case the format shifts on a future macOS.
    private static func parse(_ raw: String?) -> Data? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split { $0 == "-" || $0 == ":" }
        guard parts.count == 6 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(6)
        for p in parts {
            guard let b = UInt8(p, radix: 16) else { return nil }
            bytes.append(b)
        }
        return Data(bytes)
    }
}
