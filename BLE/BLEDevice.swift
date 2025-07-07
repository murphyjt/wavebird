import Foundation

struct BLEDevice: Identifiable, Equatable, Sendable {
    let id: UUID  // peripheral.identifier
    let name: String?
    let connected: Bool
}
