import IOKit.hid
import SwiftUI

@main
struct WaveBirdApp: App {
    @State private var coordinator = BridgeCoordinator(
        profiles: [GameCubeProfile(), ProControllerProfile()],
        transports: [BLETransport()]
    )

    var body: some Scene {
        WindowGroup("WaveBird") {
            ContentView(coordinator: coordinator)
                .frame(minWidth: 600, maxWidth: 724)
                .task {
                    // HIDVirtualDevice requires Accessibility TCC permission (kIOHIDRequestTypePostEvent).
                    // After denial, re-enable in System Settings → Privacy → Accessibility.
                    IOHIDRequestAccess(kIOHIDRequestTypePostEvent)
                    await coordinator.start()
                    if !coordinator.isScanning {
                        await coordinator.toggleScan()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
