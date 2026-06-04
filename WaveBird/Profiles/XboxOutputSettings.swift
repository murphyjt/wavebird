import Foundation
import Observation
import os

// Per-controller advanced options for the Xbox output mode. Currently one knob:
// whether to stream the GIP input report (0x20) that SDL/HIDAPI consumers
// (Dolphin, …) read. The faithful report 0x01 (GameController / Steam) is always
// sent; this only gates the extra GIP stream. Same per-serial model as
// AxisSettings/RumbleSettings: persisted to UserDefaults by serial, sampled off
// main by the dispatch task through a lock-guarded Snapshot, Observation for the
// UI binding.
//
// "GIP" (Game Input Protocol) is the Xbox One/Series controller protocol — not
// "XInput", which is the older Windows-only Xbox 360 API. On macOS these reports
// reach apps via SDL's HIDAPI GIP driver, not XInput.
@Observable
final class XboxOutputSettings: @unchecked Sendable {
    struct Snapshot: Sendable, Codable {
        var sendGIPReports: Bool = true
        // Whether the Guide button (NS2 Home) is forwarded to SDL as the GIP
        // virtual-key (report 0x07). Independent of sendGIPReports but only
        // meaningful when it's on, since 0x07 rides the same GIP stream.
        var sendGuideToSDL: Bool = true
        // Whether the Guide button (NS2 Home) reaches macOS / GameController
        // consumers (Steam, browsers, the system overlay) via report 0x01's
        // button 13. Off masks that bit; the 0x07 SDL path above is unaffected.
        var sendGuideToSystem: Bool = true
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

    var sendGIPReports: Bool {
        get { access(keyPath: \.sendGIPReports); return lock.withLock { $0.sendGIPReports } }
        set {
            withMutation(keyPath: \.sendGIPReports) { lock.withLock { $0.sendGIPReports = newValue } }
            persist()
        }
    }

    var sendGuideToSDL: Bool {
        get { access(keyPath: \.sendGuideToSDL); return lock.withLock { $0.sendGuideToSDL } }
        set {
            withMutation(keyPath: \.sendGuideToSDL) { lock.withLock { $0.sendGuideToSDL = newValue } }
            persist()
        }
    }

    var sendGuideToSystem: Bool {
        get { access(keyPath: \.sendGuideToSystem); return lock.withLock { $0.sendGuideToSystem } }
        set {
            withMutation(keyPath: \.sendGuideToSystem) { lock.withLock { $0.sendGuideToSystem = newValue } }
            persist()
        }
    }

    func snapshot() -> Snapshot { lock.withLock { $0 } }

    // MARK: - Persistence

    private static func defaultsKey(serial: String) -> String {
        "WaveBird.xbox.\(serial)"
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
