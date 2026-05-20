import SwiftUI

struct SettingsView: View {
    @Bindable var launch: LaunchAtLoginService
    @AppStorage("WaveBird.hideDockIcon") private var hideDockIcon = false
    @AppStorage("WaveBird.openInBackground") private var openInBackground = false

    var body: some View {
        TabView {
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
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 420, height: 224)
    }
}
