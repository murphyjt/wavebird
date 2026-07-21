import Foundation
import os

// Per-device "last meaningful input" timestamps. Written from the off-main
// dispatch tasks (so it stays a Sendable `let` captured by value, never self)
// and read by the coordinator's idle sweep on the main actor. The unfair lock
// matches the RumbleSettings / XboxOutputSettings snapshot pattern. ContinuousClock is
// monotonic, so it's immune to wall-clock and sleep skew.
final class ActivityTracker: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [DeviceID: ContinuousClock.Instant]())

    func touch(_ id: DeviceID, at t: ContinuousClock.Instant) {
        lock.withLock { $0[id] = t }
    }

    func seed(_ id: DeviceID) { touch(id, at: .now) }

    func remove(_ id: DeviceID) {
        lock.withLock { $0[id] = nil }
    }

    func lastActivity(for id: DeviceID) -> ContinuousClock.Instant? {
        lock.withLock { $0[id] }
    }
}
