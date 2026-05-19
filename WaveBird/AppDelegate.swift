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

        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(windowDidBecomeKey(_:)),
                       name: NSWindow.didBecomeKeyNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(windowWillClose(_:)),
                       name: NSWindow.willCloseNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(defaultsDidChange(_:)),
                       name: UserDefaults.didChangeNotification,
                       object: nil)

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

    @objc private func windowDidBecomeKey(_ n: Notification) {
        reevaluateActivationPolicy()
    }

    @objc private func windowWillClose(_ n: Notification) {
        // willClose fires while isVisible is still true; defer one runloop
        // tick so the re-evaluation sees the post-close state and avoids the
        // .regular → .accessory dock-ghost.
        DispatchQueue.main.async { [self] in
            reevaluateActivationPolicy()
        }
    }

    @objc private func defaultsDidChange(_ n: Notification) {
        reevaluateActivationPolicy()
    }

    private func reevaluateActivationPolicy() {
        let hideDock = UserDefaults.standard.bool(forKey: Self.hideDockIconKey)
        // Any user-facing window keeps the dock icon. canBecomeMain filters
        // out the MenuBarExtra popover and other transient panels.
        let userWindowVisible = NSApp.windows.contains { w in
            w.isVisible && w.canBecomeMain
        }
        let desired: NSApplication.ActivationPolicy =
            (userWindowVisible || !hideDock) ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        if desired == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
