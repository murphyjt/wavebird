import SwiftUI

@main
struct WaveBirdApp: App {
    @State private var coordinator = BridgeCoordinator(
        profiles: [NS2GameCubeProfile()],
        transports: [BLETransport()]
    )

    var body: some Scene {
        WindowGroup("WaveBird") {
            ContentView(coordinator: coordinator)
                .task {
                    await coordinator.start()
                    if !coordinator.isScanning {
                        await coordinator.toggleScan()
                    }
                }
        }
        .windowResizability(.contentSize)
    }
}
