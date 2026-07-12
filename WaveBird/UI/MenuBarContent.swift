import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var coordinator: BridgeCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open WaveBird") { openMainWindow() }

        Divider()

        if let reason = coordinator.transportUnavailableReason {
            Label(reason, systemImage: "exclamationmark.triangle.fill")
            Divider()
        }

        if let issue = coordinator.hidAccessIssue {
            Button {
                openAccessibilitySettings()
            } label: {
                Label(issue.menuTitle, systemImage: "exclamationmark.triangle.fill")
            }
            Divider()
        }

        let connected = coordinator.listEntries.filter {
            $0.live?.connectionState == .ready
        }
        Section("Connected Controllers") {
            if connected.isEmpty {
                Text("No controllers connected")
            } else {
                ForEach(connected) { entry in
                    // Bluetooth-menu shape: each controller opens a submenu with
                    // its actions. Keeps Disconnect out of single-click reach so
                    // a misclick can't drop a controller mid-game.
                    Menu {
                        Button("Controller Info…") {
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: "controller-detail", value: entry.id)
                        }
                        if let id = entry.live?.id {
                            Divider()
                            Button("Disconnect") {
                                Task { await coordinator.disconnectController(id) }
                            }
                        }
                    } label: {
                        Label(coordinator.listDisplayName(for: entry), systemImage: "gamecontroller.fill")
                    }
                }
            }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        Button("Check for Updates…") { UpdateChecker.check(userInitiated: true) }
        Button("Quit") { NSApp.terminate(nil) }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
