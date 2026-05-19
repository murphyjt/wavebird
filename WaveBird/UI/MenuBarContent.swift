import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var coordinator: BridgeCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open WaveBird") { openMainWindow() }

        Divider()

        Toggle("Scan for Controllers", isOn: Binding(
            get: { coordinator.isScanning },
            set: { _ in Task { await coordinator.toggleScan() } }
        ))

        Divider()

        let connected = coordinator.listEntries.filter {
            $0.live?.connectionState == .ready
        }
        Section("Connected Controllers") {
            if connected.isEmpty {
                Text("No controllers connected")
            } else {
                ForEach(connected) { entry in
                    Button {
                        coordinator.pendingDetailEntryID = entry.id
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "controller-detail")
                    } label: {
                        Label(entry.displayName, systemImage: "gamecontroller.fill")
                    }
                }
            }
        }

        Divider()

        SettingsLink { Text("Settings…") }
        Button("Quit WaveBird") { NSApp.terminate(nil) }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
