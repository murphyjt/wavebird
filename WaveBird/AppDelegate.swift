import AppKit

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

    func applicationDidBecomeActive(_ notification: Notification) {
        launch.refresh()
    }
}
