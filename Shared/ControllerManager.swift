import Foundation

struct ControllerInfo {
    let id: ControllerID
    var slot: Int
    var latestEvent: DSUControllerData?
}

struct ControllerID: Hashable {
    let id: UUID
}

enum SlotAvailability: Equatable {
    case free
    case occupied(ControllerID)
}

actor ControllerManager {
    private let maxSlots = 4
    private var controllers: [ControllerID: ControllerInfo] = [:]
    private var slots: [SlotAvailability] = Array(repeating: .free, count: 4)

    /// Returns assigned slot number or nil if no slot is available
    func assignSlot(for id: ControllerID) -> Int? {
        // TODO: Consolidate state
        print("ControllerManager assignSlot")
        guard controllers.count < maxSlots else { return nil }
        guard let assignedSlot = slots.firstIndex(where: { $0 == .free }) else {
            return nil
        }
        slots[assignedSlot] = .occupied(id)
        controllers[id] = ControllerInfo(
            id: id,
            slot: assignedSlot,
            latestEvent: nil
        )
        return assignedSlot
    }

    func releaseSlot(for id: ControllerID) {
        print("ControllerManager releaseSlot")
        if let slot = controllers[id]?.slot {
            slots[slot] = .free
        }
        controllers[id] = nil
    }

    func updateController(for id: ControllerID, data: DSUControllerData) {
        print("ControllerManager updateController")
        if var controller = controllers[id] {
            controller.latestEvent = data
            controllers[id] = controller
        }
    }

    func allControllers() -> [ControllerInfo] {
        Array(controllers.values)
    }

    func getSlot(for id: ControllerID) -> Int? {
        controllers[id]?.slot
    }

    func getControllerInfo(forSlot slot: Int) -> ControllerInfo? {
        // TODO: Fix slot mapping
        return controllers.first { $0.value.slot == slot }?.value
    }

    func getEvent(forSlot slot: Int) -> DSUControllerData? {
        if case let .occupied(id) = slots[slot] {
            return controllers[id]?.latestEvent
        } else {
            return nil
        }
    }
}
