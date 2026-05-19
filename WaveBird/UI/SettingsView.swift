import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var launch: LaunchAtLoginService
    @AppStorage("WaveBird.hideDockIcon") private var hideDockIcon = false
    @AppStorage("WaveBird.scanAtLaunch") private var scanAtLaunch = true

    var body: some View {
        TabView {
            Form {
                Section {
                    Toggle("Launch at login", isOn: Binding(
                        get: { launch.isEnabled },
                        set: { launch.setEnabled($0) }
                    ))
                    if let error = launch.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Toggle("Hide dock icon", isOn: $hideDockIcon)
                    Toggle("Scan for controllers at launch", isOn: $scanAtLaunch)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 420, height: 220)
        .onChange(of: hideDockIcon) { _, newValue in
            applyActivationPolicy(hideDock: newValue)
        }
    }

    private func applyActivationPolicy(hideDock: Bool) {
        if hideDock {
            // Closing the main window first avoids the .regular → .accessory
            // transition leaving the app stuck as a dock-icon ghost.
            for w in NSApp.windows where w.title == "WaveBird" && w.canBecomeMain {
                w.close()
            }
        }
        NSApp.setActivationPolicy(hideDock ? .accessory : .regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
