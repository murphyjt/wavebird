import AppKit
import SwiftUI

// View modifier that watches NSEvent's `.flagsChanged` while attached and
// flips `state` on each rising edge of the Option key (press, not release).
// Used in profile pickers to reveal advanced/in-development output modes
// without giving them a permanent UI affordance. Scope is the view's
// lifetime — when the host view disappears, the monitor is torn down.
extension View {
    func optionTogglesAdvanced(_ state: Binding<Bool>) -> some View {
        modifier(OptionToggleAdvancedModifier(showAdvanced: state))
    }
}

private struct OptionToggleAdvancedModifier: ViewModifier {
    @Binding var showAdvanced: Bool
    @State private var box = MonitorBox()

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    @MainActor
    private func install() {
        guard box.monitor == nil else { return }
        box.monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let nowDown = event.modifierFlags.contains(.option)
            if nowDown && !box.optionWasDown {
                showAdvanced.toggle()
            }
            box.optionWasDown = nowDown
            return event
        }
    }

    @MainActor
    private func remove() {
        if let monitor = box.monitor {
            NSEvent.removeMonitor(monitor)
            box.monitor = nil
            box.optionWasDown = false
        }
    }
}

// Class-backed storage so the @State can carry the opaque monitor token
// (NSEvent.addLocalMonitorForEvents returns `Any?`) without tripping over
// Sendable requirements on the wrapped value.
@MainActor
private final class MonitorBox {
    var monitor: Any?
    var optionWasDown = false
}
