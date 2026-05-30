import AppKit
import SwiftUI

extension View {
    // Mirrors macOS's "hold Option to reveal an alternate action" pattern (e.g.
    // Quit → Force Quit). Binding stays true only while Option is physically
    // down; flips back to false on release. Used by the controller row to swap
    // Disconnect → Split for a Joy-Con pair.
    func optionHeld(_ state: Binding<Bool>) -> some View {
        modifier(OptionHeldModifier(held: state))
    }
}

private struct OptionHeldModifier: ViewModifier {
    @Binding var held: Bool
    @State private var box = MonitorBox()

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    @MainActor
    private func install() {
        guard box.monitor == nil else { return }
        // Seed from the current modifier state so the binding is correct even
        // if Option was already down when the view appeared.
        held = NSEvent.modifierFlags.contains(.option)
        box.monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            held = event.modifierFlags.contains(.option)
            return event
        }
    }

    @MainActor
    private func remove() {
        if let monitor = box.monitor {
            NSEvent.removeMonitor(monitor)
            box.monitor = nil
        }
        held = false
    }
}

// Class-backed storage so the @State can carry the opaque monitor token
// (NSEvent.addLocalMonitorForEvents returns `Any?`) without tripping over
// Sendable requirements on the wrapped value.
@MainActor
private final class MonitorBox {
    var monitor: Any?
}
