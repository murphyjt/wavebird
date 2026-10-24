import SwiftUI

@main
struct WaveBirdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("WaveBird.openInBackground") private var openInBackground = false

    var body: some Scene {
        Window("WaveBird", id: "main") {
            ContentView(coordinator: appDelegate.coordinator)
                .frame(width: 512)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(openInBackground ? .suppressed : .automatic)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateChecker.check(userInitiated: true) }
            }
        }

        WindowGroup("Controller", id: "controller-detail", for: String.self) { $entryID in
            if let entryID {
                ControllerDetailWindow(coordinator: appDelegate.coordinator, entryID: entryID)
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)

        Window("Profiles", id: "profiles") {
            ProfilesView(coordinator: appDelegate.coordinator)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 720, height: 540)

        Settings {
            SettingsView(launch: appDelegate.launch)
        }

        MenuBarExtra("WaveBird", systemImage: "gamecontroller") {
            MenuBarContent(coordinator: appDelegate.coordinator)
        }
    }
}
