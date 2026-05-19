import AppKit
import IOKit.hid

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = BridgeCoordinator(
        profiles: [GameCubeProfile(), ProControllerProfile()],
        transports: [BLETransport()]
    )
    let launch = LaunchAtLoginService()

    private static let hideDockIconKey = "WaveBird.hideDockIcon"

    func applicationWillFinishLaunching(_ notification: Notification) {
        let hideDock = UserDefaults.standard.bool(forKey: Self.hideDockIconKey)
        NSApp.setActivationPolicy(hideDock ? .accessory : .regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        IOHIDRequestAccess(kIOHIDRequestTypePostEvent)
        // Drive start + auto-scan from the delegate so it runs even when the
        // app launches into .accessory mode without the main window.
        Task { @MainActor in
            await coordinator.start()
            if BridgeCoordinator.scanAtLaunch, !coordinator.isScanning {
                await coordinator.toggleScan()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        launch.refresh()
    }
}
