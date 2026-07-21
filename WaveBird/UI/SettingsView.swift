import SwiftUI

struct SettingsView: View {
    @Bindable var launch: LaunchAtLoginService
    @AppStorage("WaveBird.hideDockIcon") private var hideDockIcon = false
    @AppStorage("WaveBird.openInBackground") private var openInBackground = false
    @AppStorage("WaveBird.idleDisconnectMinutes") private var idleDisconnectMinutes = 10

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: Binding(
                    get: { launch.isEnabled },
                    set: { launch.setEnabled($0) }
                ))
                Toggle("Open in background", isOn: $openInBackground)
                if let error = launch.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Toggle("Hide Dock icon when no windows are open", isOn: $hideDockIcon)
                if hideDockIcon && openInBackground {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("WaveBird will only appear in the menu bar — look for the controller icon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Picker("Disconnect idle controller after", selection: $idleDisconnectMinutes) {
                    Text("Never").tag(0)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
    }
}
