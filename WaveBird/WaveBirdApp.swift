import SwiftUI

@main
struct WaveBirdApp: App {
    @State private var coordinator = BridgeCoordinator(
        profiles: [NS2GameCubeProfile()],
        transports: [BLETransport()]
    )

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .task { await coordinator.start() }
        }
    }
}
