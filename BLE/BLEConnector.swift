import CoreBluetooth

actor BLEConnector {
    private var centralManager: CBCentralManager
    private let delegate: BLECentralDelegate
    private let controllerManager: ControllerManager

    // Per-controller stream management
    private var streams: [UUID: AsyncStream<Data>.Continuation] = [:]

    init(controllerManager: ControllerManager) {
        delegate = BLECentralDelegate()
        centralManager = CBCentralManager(delegate: delegate, queue: nil)
        self.controllerManager = controllerManager
    }

    private var foundPeripherals: [CBPeripheral: BLEPeripheralDelegate?] = [:]

    func startListening() async {
        print("Start listening")
        for await device in delegate.deviceStream {
            print("🎮 Found Nintendo device!")
            print("Discovered device: \(device.name ?? "Unnamed")")

            if !device.connected {
                guard
                    let peripheral = centralManager.retrievePeripherals(
                        withIdentifiers: [device.id]).first
                else { continue }
                let peripheralDelegate = BLEPeripheralDelegate()
                foundPeripherals[peripheral] = peripheralDelegate
                peripheral.delegate = peripheralDelegate
                centralManager.connect(peripheral, options: nil)
            } else {
                guard
                    let peripheral = centralManager.retrievePeripherals(
                        withIdentifiers: [device.id]).first
                else { continue }
                let slotAssignment = await controllerManager.assignSlot(
                    for: ControllerID(id: peripheral.identifier)
                )
                // TODO: Above just assumes the slot is assigned
                print("Assigned device to slot \(slotAssignment!)")
                Task {
                    print("Start listening for peripheral events...")
                    guard let delegate = foundPeripherals[peripheral] else {
                        return
                    }
                    for await event in delegate!.eventStream {
                        await controllerManager.updateController(
                            for: ControllerID(id: peripheral.identifier),
                            data: event
                        )
                    }
                }
                peripheral.discoverServices(nil)
            }

        }
    }
}
