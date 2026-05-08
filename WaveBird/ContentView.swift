import SwiftUI

@Observable
final class HIDTestHarness {
    var deviceCreated = false
    var lastError: String?
    var pressCount = 0

    @ObservationIgnored
    private var device: VirtualHIDDevice?

    func press() async {
        if device == nil {
            guard let newDevice = VirtualHIDDevice(
                descriptor: VirtualHIDDevice.placeholderGamepadDescriptor,
                vendorID: 0x057E,
                productID: 0xF000,
                productName: "WaveBird Test Gamepad"
            ) else {
                lastError = "Failed to create virtual HID device — check entitlement"
                return
            }
            await newDevice.activate()
            device = newDevice
            deviceCreated = true
        }
        pressCount += 1
        let aPressed = pressCount.isMultiple(of: 2) == false
        let report = Self.makeReport(buttonA: aPressed)
        do {
            try await device?.dispatch(report)
            lastError = nil
        } catch {
            lastError = "dispatch error: \(error.localizedDescription)"
        }
    }

    static func makeReport(buttonA: Bool) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[6] = buttonA ? 0x01 : 0x00
        return Data(bytes)
    }
}

struct ContentView: View {
    @State private var harness = HIDTestHarness()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("WaveBird HID Test")
                .font(.headline)
            Text(harness.deviceCreated ? "Virtual gamepad active" : "Tap to create virtual gamepad")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Toggle Button A (\(harness.pressCount))") {
                Task { await harness.press() }
            }
            .controlSize(.large)
            if let error = harness.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(minWidth: 360, minHeight: 240)
    }
}

#Preview {
    ContentView()
}
