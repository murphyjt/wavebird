import Foundation
import Observation
import os

// Per-controller input-axis configuration — currently Y-axis inversion for each
// stick. One instance per controller serial lives in BridgeCoordinator,
// persisted to UserDefaults by serial like RumbleSettings, so each physical
// controller carries its own preference across re-pairings (pairs use
// "Lserial+Rserial"). The dispatch task reads a Sendable snapshot off-main; the
// inner lock guards it against torn reads. The Observation registrar is
// thread-safe for the UI bindings.
@Observable
final class AxisSettings: @unchecked Sendable {
    struct Snapshot: Sendable, Codable {
        var invertLeftY: Bool = false
        var invertRightY: Bool = false
        static let initial = Snapshot()
    }

    let serial: String

    @ObservationIgnored
    private let lock: OSAllocatedUnfairLock<Snapshot>

    init(serial: String) {
        self.serial = serial
        let loaded = Self.load(serial: serial) ?? .initial
        self.lock = OSAllocatedUnfairLock(initialState: loaded)
    }

    var invertLeftY: Bool {
        get { access(keyPath: \.invertLeftY); return lock.withLock { $0.invertLeftY } }
        set {
            withMutation(keyPath: \.invertLeftY) { lock.withLock { $0.invertLeftY = newValue } }
            persist()
        }
    }

    var invertRightY: Bool {
        get { access(keyPath: \.invertRightY); return lock.withLock { $0.invertRightY } }
        set {
            withMutation(keyPath: \.invertRightY) { lock.withLock { $0.invertRightY = newValue } }
            persist()
        }
    }

    func snapshot() -> Snapshot { lock.withLock { $0 } }

    // MARK: - Persistence

    private static func defaultsKey(serial: String) -> String {
        "WaveBird.axis.\(serial)"
    }

    private static func load(serial: String) -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(serial: serial)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func persist() {
        let snap = lock.withLock { $0 }
        guard let data = try? JSONEncoder().encode(snap) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey(serial: serial))
    }
}
