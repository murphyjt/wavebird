import Foundation

let manager = ControllerManager()

print("Joystick server started.")

Task {
    let connector = BLEConnector(controllerManager: manager)
    await connector.startListening()
}

Task {
    let server = DSUServer(controllerManager: manager)
    try? await server.listen()
}

RunLoop.current.run()
