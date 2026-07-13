import Foundation

// Glue between two Joy-Con 2 DeviceRecords (L + R) and a single shared
// VirtualHIDDevice. Lives in BridgeCoordinator memory; nil unless both sides
// are currently .ready. The class is reference type so the dispatch tasks
// (one per Joy-Con side) can update the per-side state without copying.
//
// Why one pair, not many: in practice users only run a single Joy-Con pair at
// a time. Forming new pairs from extra Joy-Cons would require pair-identity
// persistence (which L goes with which R) and a UI to disambiguate. Defer
// until that comes up.
final class JoyConPair: @unchecked Sendable {
    let leftID: DeviceID
    let rightID: DeviceID
    var virtualHID: VirtualHIDDevice?
    var session: (any HIDOutputSession)?
    var activeOutputModeID: String = ""
    // Mapping profile driving the merged VHID (activeOutputModeID stays the
    // base mode). Set in activateJoyConPair, cleared on teardown.
    var mappingProfileID: String? = nil
    var leftState: ControllerState = .zero
    var rightState: ControllerState = .zero

    init(leftID: DeviceID, rightID: DeviceID) {
        self.leftID = leftID
        self.rightID = rightID
    }

    func includes(_ id: DeviceID) -> Bool {
        id == leftID || id == rightID
    }

    func partner(of id: DeviceID) -> DeviceID? {
        if id == leftID { return rightID }
        if id == rightID { return leftID }
        return nil
    }
}
