import CoreBluetooth
import Foundation

final class BLEPeripheralDelegate: NSObject, CBPeripheralDelegate {
    private var continuation: AsyncStream<DSUControllerData>.Continuation!

    lazy var eventStream: AsyncStream<DSUControllerData> = AsyncStream {
        continuation in
        self.continuation = continuation
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let services = peripheral.services {
            for service in services {
                print("🔎 Found service: \(service.uuid)")
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                print(
                    "   • Characteristic: \(characteristic.uuid), properties: \(characteristic.properties)"
                )

                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }

                if characteristic.properties.contains(.notify) {
                    print(
                        "   📡 Subscribing to notifications for: \(characteristic.uuid)"
                    )
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data[5..<20])  // ignore noisy tail
        // byte 9 is Left analog
        // byte 10 is Right analog
        // TODO: Print these so I can figure out the byte mapping
        print(bytes.withUnsafeBytes { Array($0) })
        continuation.yield(GameCubeAdapter.convert(data))
    }

}
