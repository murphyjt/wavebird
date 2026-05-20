import SwiftUI

// Wraps ControllerDetailSheet for presentation as its own Window (not a sheet
// on the main window). The entryID is passed as the WindowGroup value at
// openWindow time, so each window owns its own selection independently.
struct ControllerDetailWindow: View {
    @Bindable var coordinator: BridgeCoordinator
    let entryID: String
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ControllerDetailSheet(coordinator: coordinator, entryID: entryID) {
            dismissWindow()
        }
        .frame(width: 544, height: 640)
    }
}
