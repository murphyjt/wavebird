import SwiftUI

@main
struct WaveBirdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("WaveBird", id: "main") {
            ContentView(coordinator: appDelegate.coordinator)
                .frame(width: 512)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Controller", id: "controller-detail") {
            ControllerDetailWindow(coordinator: appDelegate.coordinator)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)

        Settings {
            SettingsView(launch: appDelegate.launch)
        }

        MenuBarExtra("WaveBird", systemImage: "gamecontroller") {
            MenuBarContent(coordinator: appDelegate.coordinator)
        }
    }
}
