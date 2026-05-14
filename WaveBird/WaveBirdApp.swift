import SwiftUI

@main
struct WaveBirdApp: App {
    @State private var coordinator = BridgeCoordinator(
        profiles: [NS2GameCubeProfile(), NS2ProControllerProfile()],
        transports: [BLETransport()]
    )

    var body: some Scene {
        WindowGroup("WaveBird") {
            ContentView(coordinator: coordinator)
                .frame(minWidth: 600, maxWidth: 724)
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
