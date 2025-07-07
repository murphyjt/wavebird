import CoreBluetooth
import Foundation

final class BLECentralDelegate: NSObject, CBCentralManagerDelegate {
    private var continuation: AsyncStream<BLEDevice>.Continuation!

    lazy var deviceStream: AsyncStream<BLEDevice> = AsyncStream {
        continuation in
        self.continuation = continuation
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            print("🔍 Scanning for BLE devices...")
            central.scanForPeripherals(withServices: nil, options: nil)
        } else {
            print("Bluetooth not ready: \(central.state.rawValue)")
            central.stopScan()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard
            let mfgData = advertisementData[
                CBAdvertisementDataManufacturerDataKey
            ] as? Data
        else { return }
        let bytes = [UInt8](mfgData)
        if bytes.count >= 2 {
            let manufacturerID = UInt16(bytes[1]) << 8 | UInt16(bytes[0])
            if manufacturerID == 0x0553 {
                let device = BLEDevice(
                    id: peripheral.identifier,
                    name: peripheral.name,
                    connected: false
                )
                continuation.yield(device)
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        print("✅ Connected to peripheral: \(peripheral.name ?? "Unknown")")
        let device = BLEDevice(
            id: peripheral.identifier,
            name: peripheral.name,
            connected: true
        )
        continuation.yield(device)
    }
}
