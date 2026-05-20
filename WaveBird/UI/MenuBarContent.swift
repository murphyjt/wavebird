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

        let connected = coordinator.listEntries.filter {
            $0.live?.connectionState == .ready
        }
        Section("Connected Controllers") {
            if connected.isEmpty {
                Text("No controllers connected")
            } else {
                ForEach(connected) { entry in
                    Button {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "controller-detail", value: entry.id)
                    } label: {
                        Label(entry.displayName, systemImage: "gamecontroller.fill")
                    }
                }
            }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        Button("Quit WaveBird") { NSApp.terminate(nil) }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
