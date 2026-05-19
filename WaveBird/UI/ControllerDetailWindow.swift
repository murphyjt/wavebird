import SwiftUI

// Wraps ControllerDetailSheet for presentation as its own Window (not a sheet
// on the main window). The current selection is whatever
// coordinator.pendingDetailEntryID points to; callers set it before opening
// the window.
struct ControllerDetailWindow: View {
    @Bindable var coordinator: BridgeCoordinator
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let id = coordinator.pendingDetailEntryID {
                ControllerDetailSheet(coordinator: coordinator, entryID: id) {
                    dismissWindow(id: "controller-detail")
                }
            } else {
                // No selection yet — show a calm placeholder. Auto-dismissing
                // here races with openWindow, which can briefly evaluate the
                // body with a stale nil and close the window we just opened.
                Text("No controller selected")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 544, height: 640)
    }
}
