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
                    Toggle("Hide dock icon when closed", isOn: $hideDockIcon)
                    Toggle("Scan for controllers at launch", isOn: $scanAtLaunch)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 420, height: 220)
    }
}
