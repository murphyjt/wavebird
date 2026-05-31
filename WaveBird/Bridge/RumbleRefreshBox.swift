import Foundation

// Holds the active Xbox rumble refresh task for one device. Lock-protected so the
// handler closure (any executor) and the main-actor coordinator can both cancel safely.
final class RumbleRefreshBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var counter: UInt8 = 0

    func replace(with newTask: Task<Void, Never>) {
        lock.withLock {
            task?.cancel()
            task = newTask
        }
    }

    func cancel() {
        lock.withLock {
            task?.cancel()
            task = nil
        }
    }

    // Monotonically increment the per-device transmit counter so successive
    // GC/Pro vibration payloads differ in their tid nibble and the controller
    // doesn't dedupe them. UInt8 wraparound is fine — only the low 4 bits matter.
    func nextCounter() -> UInt8 {
        lock.withLock {
            counter = counter &+ 1
            return counter
        }
    }
}
