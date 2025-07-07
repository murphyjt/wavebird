import Foundation
import Network

final class DSUServer {
    let BUFFER_SIZE = 1024

    var packetNumber: UInt32 = 0
    let controllerManager: ControllerManager

    init(controllerManager: ControllerManager) {
        self.controllerManager = controllerManager
    }

    var slot1Task: Task<Void, Never>?

    func listen(on port: NWEndpoint.Port = 26760) async throws {
        let listener = try NWListener(using: .udp, on: port)

        listener.newConnectionHandler = { connection in
            print("Connected to \(connection.endpoint)")
            connection.start(queue: .global())
            self.receive(on: connection)
        }

        listener.start(queue: .global())
        print("DSU server started on port \(port)")
    }

    /// Continues to receive data
    func receive(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: BUFFER_SIZE
        ) { data, contentContext, isComplete, error in
            Task {
                guard let data = data else {
                    print("No data")
                    exit(EXIT_FAILURE)
                }
                print(
                    "In: (\(data.count) bytes) \(data.map {String(format: "%02X", $0)}.joined(separator: " "))"
                )

                do {
                    let packet = try Packet(from: data)!
                    print(packet.header)
                    print(packet.payload)
                    let valid = CRC32Utility.verify(
                        data: data,
                        crcRange: 8..<12
                    )
                    print("CRC32 is valid: \(valid)")

                    switch packet.header.eventType {
                    case .ConnectedControllers:
                        print("Received ConnectedControllersQuery")
                        for slot
                            in (packet.payload as! ConnectedControllersQuery)
                            .slots
                        {
                            guard
                                let controller = await self.controllerManager
                                    .getControllerInfo(forSlot: Int(slot))
                            else {
                                let payload = DSUConnectedControllers(
                                    slot: slot,
                                    state: .Disconnected
                                )
                                var responseHeader = Header()
                                responseHeader.eventType = .ConnectedControllers
                                var packet = Packet(
                                    header: responseHeader,
                                    payload: payload
                                )
                                let out = packet.toData()
                                print(
                                    "Sending DSUConnectedControllers: \(out.count) bytes"
                                )
                                connection.send(
                                    content: out,
                                    completion: .idempotent
                                )
                                continue
                            }

                            let payload = DSUConnectedControllers(
                                slot: slot,
                                state: controller.latestEvent?.state
                                    ?? .Connected,  // TODO: Probably a bug
                                model: controller.latestEvent?.model
                                    ?? .NotApplicable,
                                connectionType: controller.latestEvent?
                                    .connectionType ?? .NotApplicable,
                                batteryStatus: controller.latestEvent?
                                    .batteryStatus ?? .NotApplicable
                            )
                            print(payload)
                            var responseHeader = Header()
                            responseHeader.eventType = .ConnectedControllers
                            var packet = Packet(
                                header: responseHeader,
                                payload: payload
                            )
                            let out = packet.toData()
                            //                        print("Sending (\(out.count) bytes) \(out.map {String(format: "%02X", $0)}.joined(separator: " "))")
                            connection.send(
                                content: out,
                                completion: .idempotent
                            )
                        }
                    case .ControllerData:
                        // TODO: Task on timer to send latest event report
                        print("Received ControllerDataQuery")
                        let incoming = packet.payload as! ControllerDataQuery
                        let controllerInfo = await self.controllerManager
                            .getControllerInfo(forSlot: Int(incoming.slot))
                        guard let controllerInfo else {
                            break
                        }
                        guard var latestEvent = controllerInfo.latestEvent
                        else {
                            break
                        }
                        var responseHeader = Header()
                        responseHeader.eventType = .ControllerData
                        latestEvent.packetNumber = self.packetNumber
                        self.packetNumber += 1
                        var packet = Packet(
                            header: responseHeader,
                            payload: latestEvent
                        )
                        let out = packet.toData()
                        //                    print("Sending (\(out.count) bytes) \(out.map {String(format: "%02X", $0)}.joined(separator: " "))")
                        connection.send(content: out, completion: .idempotent)
                        // And continue to send events
                        if self.slot1Task != nil {
                            break
                        }
                        self.slot1Task = Task {
                            print(
                                ">>> Sending ControllerData for slot \(incoming.slot)"
                            )
                            while true {
                                let controllerInfo =
                                    await self.controllerManager
                                    .getControllerInfo(
                                        forSlot: Int(incoming.slot)
                                    )
                                guard let controllerInfo else {
                                    break
                                }
                                guard
                                    var latestEvent = controllerInfo.latestEvent
                                else {
                                    break
                                }
                                var responseHeader = Header()
                                responseHeader.eventType = .ControllerData
                                latestEvent.packetNumber = self.packetNumber
                                self.packetNumber += 1
                                var packet = Packet(
                                    header: responseHeader,
                                    payload: latestEvent
                                )
                                let out = packet.toData()
                                //                    print("Sending (\(out.count) bytes) \(out.map {String(format: "%02X", $0)}.joined(separator: " "))")
                                connection.send(
                                    content: out,
                                    completion: .idempotent
                                )
                                try? await Task.sleep(nanoseconds: 1_000_000)  // 1000 hz
                            }
                        }
                    default:
                        print("Unsupported event type")
                    }

                    // TODO: Only support one kind of message so far

                } catch {
                    print("Failed to parse packet")
                }
            }

            if error == nil {
                self.receive(on: connection)
            } else {
                print("Connection error: \(String(describing: error))")
            }
        }
    }
}
