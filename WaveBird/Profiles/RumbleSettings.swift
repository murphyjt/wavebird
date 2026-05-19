import Foundation
import Observation
import os

// Per-controller rumble configuration. One instance lives in BridgeCoordinator
// per connected device (keyed by DeviceID); the encoder reads a snapshot via
// the encodeRumble parameter, so the BLE write queue never touches main-actor
// state. The Observation framework's registrar is thread-safe; the inner lock
// guards the snapshot struct against torn reads when the encoder samples it.
//
// Persistence: each PID gets its own UserDefaults blob. Settings load from
// disk on init and save on every mutation. Per-PID (not per-device-instance)
// so the same physical controller carries its tuning across re-pairings, and
// so different controllers (Pro 2 vs GC) don't share state.
@Observable
final class RumbleSettings: @unchecked Sendable {
    enum Preset: String, CaseIterable, Identifiable, Codable {
        case sdl
        case blueRetro
        case custom

        var id: String { rawValue }
        var label: String {
            switch self {
            case .sdl:       return "SDL"
            case .blueRetro: return "BlueRetro"
            case .custom:    return "Custom"
            }
        }

        // SDL is symmetric, drives only left HF + right LF; amp scales chosen so cmd_amp
        // at max reproduces SDL's 113/453 field values.
        // BR has per-LRA carriers and drives all four bands; amp scales reproduce BR's
        // 95/807 field values.
        // .custom has no defaults — it's a marker for "user has deviated."
        var defaults: Defaults? {
            switch self {
            case .sdl:
                return Defaults(
                    leftHiFreq: 0x187,  rightHiFreq: 0x187,
                    leftLoFreq: 0x112,  rightLoFreq: 0x112,
                    leftHiAmpScale: 113.0/255,  leftLoAmpScale: 0,
                    rightHiAmpScale: 0,         rightLoAmpScale: 453.0/1023
                )
            case .blueRetro:
                return Defaults(
                    leftHiFreq: 0x0E1, rightHiFreq: 0x1E1,
                    leftLoFreq: 0x100, rightLoFreq: 0x180,
                    leftHiAmpScale: 95.0/255,  leftLoAmpScale: 807.0/1023,
                    rightHiAmpScale: 95.0/255, rightLoAmpScale: 807.0/1023
                )
            case .custom:
                return nil
            }
        }
    }

    struct Defaults: Sendable {
        var leftHiFreq, rightHiFreq: UInt16
        var leftLoFreq, rightLoFreq: UInt16
        var leftHiAmpScale, leftLoAmpScale: Double
        var rightHiAmpScale, rightLoAmpScale: Double
    }

    struct Snapshot: Sendable, Codable {
        var preset: Preset
        var intensity: Double
        var leftHiFreq, rightHiFreq: UInt16
        var leftLoFreq, rightLoFreq: UInt16
        var leftHiAmpScale, leftLoAmpScale: Double
        var rightHiAmpScale, rightLoAmpScale: Double

        static let initial: Snapshot = {
            // SDL preset is the no-setting default.
            let d = Preset.sdl.defaults!
            return Snapshot(
                preset: .sdl,
                intensity: 1.0,
                leftHiFreq: d.leftHiFreq,   rightHiFreq: d.rightHiFreq,
                leftLoFreq: d.leftLoFreq,   rightLoFreq: d.rightLoFreq,
                leftHiAmpScale: d.leftHiAmpScale,   leftLoAmpScale: d.leftLoAmpScale,
                rightHiAmpScale: d.rightHiAmpScale, rightLoAmpScale: d.rightLoAmpScale
            )
        }()
    }

    // Carrier-frequency slider range. The hf_freq / lf_freq fields are 9-bit
    // (max 0x1FF = 511). Observed Switch-firmware values span 225–481; the [50, 511]
    // window covers the full field with a floor that avoids divisor-feel issues.
    static let safeFrequencyRange: ClosedRange<UInt16> = 50...511

    let productID: UInt16

    // GC has a single on/off motor (see GameCubeProfile.encodeRumble), so the
    // preset/freq/amp tunables are inert — only `intensity` is meaningful for it.
    var isGameCube: Bool { productID == 0x2073 }

    @ObservationIgnored
    private let lock: OSAllocatedUnfairLock<Snapshot>

    init(productID: UInt16) {
        self.productID = productID
        let loaded = Self.load(productID: productID) ?? .initial
        self.lock = OSAllocatedUnfairLock(initialState: loaded)
    }

    // Picking a preset resets all eight tunable fields to that preset's defaults.
    // Selecting .custom is a no-op (no defaults to load); a slider mutation is what
    // moves the state into .custom.
    var preset: Preset {
        get { access(keyPath: \.preset); return lock.withLock { $0.preset } }
        set {
            guard let d = newValue.defaults else {
                // .custom selection — only meaningful if we're already custom; otherwise ignore.
                if lock.withLock({ $0.preset }) != .custom {
                    withMutation(keyPath: \.preset) {
                        lock.withLock { $0.preset = .custom }
                    }
                    persist()
                }
                return
            }
            withMutation(keyPath: \.preset) {
            withMutation(keyPath: \.leftHiFreq) {
            withMutation(keyPath: \.rightHiFreq) {
            withMutation(keyPath: \.leftLoFreq) {
            withMutation(keyPath: \.rightLoFreq) {
            withMutation(keyPath: \.leftHiAmpScale) {
            withMutation(keyPath: \.leftLoAmpScale) {
            withMutation(keyPath: \.rightHiAmpScale) {
            withMutation(keyPath: \.rightLoAmpScale) {
                lock.withLock {
                    $0.preset = newValue
                    $0.leftHiFreq = d.leftHiFreq
                    $0.rightHiFreq = d.rightHiFreq
                    $0.leftLoFreq = d.leftLoFreq
                    $0.rightLoFreq = d.rightLoFreq
                    $0.leftHiAmpScale = d.leftHiAmpScale
                    $0.leftLoAmpScale = d.leftLoAmpScale
                    $0.rightHiAmpScale = d.rightHiAmpScale
                    $0.rightLoAmpScale = d.rightLoAmpScale
                }
            }}}}}}}}}
            persist()
        }
    }

    // Intensity is a master gain orthogonal to the preset's freq/amp tuning, so
    // moving this slider does NOT mark the preset as .custom.
    var intensity: Double {
        get { access(keyPath: \.intensity); return lock.withLock { $0.intensity } }
        set {
            let c = min(max(newValue, 0), 1)
            withMutation(keyPath: \.intensity) {
                lock.withLock { $0.intensity = c }
            }
            persist()
        }
    }

    var leftHiFreq: UInt16 {
        get { access(keyPath: \.leftHiFreq); return lock.withLock { $0.leftHiFreq } }
        set {
            let c = Self.clampFreq(newValue)
            withMutation(keyPath: \.leftHiFreq) {
                withMutation(keyPath: \.preset) {
                    lock.withLock { $0.leftHiFreq = c; $0.preset = .custom }
                }
            }
            persist()
        }
    }
    var rightHiFreq: UInt16 {
        get { access(keyPath: \.rightHiFreq); return lock.withLock { $0.rightHiFreq } }
        set {
            let c = Self.clampFreq(newValue)
            withMutation(keyPath: \.rightHiFreq) {
                withMutation(keyPath: \.preset) {
                    lock.withLock { $0.rightHiFreq = c; $0.preset = .custom }
                }
            }
            persist()
        }
    }
    var leftLoFreq: UInt16 {
        get { access(keyPath: \.leftLoFreq); return lock.withLock { $0.leftLoFreq } }
        set {
            let c = Self.clampFreq(newValue)
            withMutation(keyPath: \.leftLoFreq) {
                withMutation(keyPath: \.preset) {
                    lock.withLock { $0.leftLoFreq = c; $0.preset = .custom }
                }
            }
            persist()
        }
    }
    var rightLoFreq: UInt16 {
        get { access(keyPath: \.rightLoFreq); return lock.withLock { $0.rightLoFreq } }
        set {
            let c = Self.clampFreq(newValue)
            withMutation(keyPath: \.rightLoFreq) {
                withMutation(keyPath: \.preset) {
                    lock.withLock { $0.rightLoFreq = c; $0.preset = .custom }
                }
            }
            persist()
        }
    }

    var leftHiAmpScale: Double {
        get { access(keyPath: \.leftHiAmpScale); return lock.withLock { $0.leftHiAmpScale } }
        set {
            let c = Self.clampScale(newValue)
            withMutation(keyPath: \.leftHiAmpScale) {
                withMutation(keyPath: \.preset) {
                    lock.withLock { $0.leftHiAmpScale = c; $0.preset = .custom }
                }
            }
            persist()
        }
    }
    var leftLoAmpScale: Double {
        get { access(keyPath: \.leftLoAmpScale); return lock.withLock { $0.leftLoAmpScale } }
        set {
            let c = Self.clampScale(newValue)
            withMutation(keyPath: \.leftLoAmpScale) {
                withMutation(keyPath: \.preset) {
                    lock.withLock { $0.leftLoAmpScale = c; $0.preset = .custom }
                }
            }
            persist()
        }
    }
    var rightHiAmpScale: Double {
        get { access(keyPath: \.rightHiAmpScale); return lock.withLock { $0.rightHiAmpScale } }
        set {
            let c = Self.clampScale(newValue)
            withMutation(keyPath: \.rightHiAmpScale) {
                withMutation(keyPath: \.preset) {
                    lock.withLock { $0.rightHiAmpScale = c; $0.preset = .custom }
                }
            }
            persist()
        }
    }
    var rightLoAmpScale: Double {
        get { access(keyPath: \.rightLoAmpScale); return lock.withLock { $0.rightLoAmpScale } }
        set {
            let c = Self.clampScale(newValue)
            withMutation(keyPath: \.rightLoAmpScale) {
                withMutation(keyPath: \.preset) {
                    lock.withLock { $0.rightLoAmpScale = c; $0.preset = .custom }
                }
            }
            persist()
        }
    }

    func snapshot() -> Snapshot { lock.withLock { $0 } }

    static func clampFreq(_ value: UInt16) -> UInt16 {
        min(max(value, safeFrequencyRange.lowerBound), safeFrequencyRange.upperBound)
    }
    static func clampScale(_ value: Double) -> Double { min(max(value, 0), 1) }

    // MARK: - Persistence

    private static func defaultsKey(productID: UInt16) -> String {
        String(format: "WaveBird.rumble.0x%04X", productID)
    }

    private static func load(productID: UInt16) -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(productID: productID)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func persist() {
        let snap = lock.withLock { $0 }
        guard let data = try? JSONEncoder().encode(snap) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey(productID: productID))
    }
}
