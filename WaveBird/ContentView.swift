import SwiftUI

@Observable
final class ScanLog {
    private(set) var events: [String] = []
    private(set) var isScanning = false

    private let transport = BLETransport()

    @ObservationIgnored
    private var consumer: Task<Void, Never>?

    func toggle() async {
        if isScanning {
            await transport.stopDiscovery()
            isScanning = false
        } else {
            consumer = consumer ?? Task { [weak self] in
                guard let self else { return }
                for await event in transport.events {
                    await MainActor.run { self.append(event) }
                }
            }
            await transport.startDiscovery(matchers: [])
            isScanning = true
        }
    }

    private func append(_ event: TransportEvent) {
        let line: String
        switch event {
        case .discovered(let id, let info):
            let name = info.localName ?? "—"
            let pid = String(format: "0x%04X", info.productID)
            line = "discovered  \(name)  PID=\(pid)  \(id.raw.uuidString.prefix(8))"
        case .connecting(let id):
            line = "connecting  \(id.raw.uuidString.prefix(8))"
        case .connected(let id):
            line = "connected   \(id.raw.uuidString.prefix(8))"
        case .disconnected(let id, let reason):
            line = "disconnected \(id.raw.uuidString.prefix(8)) (\(reason))"
        case .reportReceived(let id, let data):
            line = "report      \(id.raw.uuidString.prefix(8)) \(data.count)B"
        case .error(_, let message):
            line = "error       \(message)"
        }
        events.append(line)
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
}

struct ContentView: View {
    @State private var log = ScanLog()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("WaveBird")
                    .font(.headline)
                Spacer()
                Button(log.isScanning ? "Stop Scan" : "Start Scan") {
                    Task { await log.toggle() }
                }
                .controlSize(.large)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(log.events.indices.reversed(), id: \.self) { i in
                        Text(log.events[i])
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240)
            .background(Color.secondary.opacity(0.08))
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
