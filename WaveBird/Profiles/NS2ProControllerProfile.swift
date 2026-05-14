@preconcurrency import CoreBluetooth
import Foundation

struct NS2ProControllerProfile: ControllerProfile {
    let name = "Nintendo Switch 2 Pro Controller"

    // Pro reports buttons | analog | IMU | rumble + Pro-specific bit 0x08.
    // (GC uses 0x27; JoyCons use 0x37 which adds mouse 0x10.)
    private static let featureMask: UInt8 = 0x2F

    var bleMatcher: BLEMatcher? {
        let responseHandles = [NS2Handle.commandResponse1, NS2Handle.commandResponse2]
        let responseChannels: [ResponseChannel] = responseHandles.compactMap { h in
            NS2Handle.uuid(h, for: .pro).map { ResponseChannel(uuid: $0, handle: h) }
        }
        return BLEMatcher(
            productID: 0x2069,
            serviceUUID: CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0"),
            // Subscribe to shared Report 0x05 (handle 0x000A). Report 0x09 carries the same
            // sticks/buttons plus battery + motion via the per-controller input handle, but
            // 0x05 is sufficient for what we currently expose through CoreHID.
            inputCharacteristic: CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2"),
            outputCharacteristic: NS2Handle.uuid(NS2Handle.commandWriteShared, for: .pro),
            responseCharacteristics: responseChannels,
            initCommands: [
                NS2Commands.handshake,
                NS2Commands.factoryDataRead,
                NS2Commands.leftStickCalibrationRead,
                NS2Commands.rightStickCalibrationRead,
                NS2Commands.firmwareInfo,
                NS2Commands.connectionVibration,
                NS2Commands.player1LED,
                NS2Commands.setFeatureMask(Self.featureMask),
                NS2Commands.sendVibrationData,
                NS2Commands.enableFeatures(Self.featureMask),
            ]
        )
    }

    var usbMatcher: USBMatcher? { nil }

    let hidVendorID: UInt16 = 0x057E
    let hidProductID: UInt16 = 0x2069

    var hidDescriptor: Data { VirtualHIDDevice.standardGamepadDescriptor }

    // Pro descriptor: 4 sticks + 2 triggers + hat + 16 buttons. See VirtualHIDDevice
    // for layout. ZL/ZR are digital on Pro — we drive both the trigger axes (0/0xFF)
    // and dedicated button slots, matching SDL's dual-mapping convention.
    func buildHIDReport(_ state: ControllerState) -> Data {
        let s = state.buttons
        var bytes = [UInt8](repeating: 0, count: 9)
        bytes[0] = UInt8(bitPattern: state.leftStick.x)
        bytes[1] = UInt8(bitPattern: state.leftStick.y)
        bytes[2] = UInt8(bitPattern: state.rightStick.x)
        bytes[3] = UInt8(bitPattern: state.rightStick.y)
        bytes[4] = s.contains(.zl) ? 0xFF : 0x00
        bytes[5] = s.contains(.zr) ? 0xFF : 0x00
        bytes[6] = VirtualHIDDevice.hatValue(
            up: s.contains(.dpadUp),
            right: s.contains(.dpadRight),
            down: s.contains(.dpadDown),
            left: s.contains(.dpadLeft)
        ) & 0x0F

        var b: UInt16 = 0
        if s.contains(.b)       { b |= 1 << 0 }   // 1  — SOUTH
        if s.contains(.a)       { b |= 1 << 1 }   // 2  — EAST
        if s.contains(.y)       { b |= 1 << 2 }   // 3  — WEST
        if s.contains(.x)       { b |= 1 << 3 }   // 4  — NORTH
        if s.contains(.l)       { b |= 1 << 4 }   // 5  — LEFT_SHOULDER
        if s.contains(.r)       { b |= 1 << 5 }   // 6  — RIGHT_SHOULDER
        if s.contains(.zl)      { b |= 1 << 6 }   // 7  — ZL
        if s.contains(.zr)      { b |= 1 << 7 }   // 8  — ZR
        if s.contains(.minus)   { b |= 1 << 8 }   // 9  — BACK / Minus
        if s.contains(.plus)    { b |= 1 << 9 }   // 10 — START / Plus
        if s.contains(.stickL)  { b |= 1 << 10 }  // 11 — LEFT_STICK click
        if s.contains(.stickR)  { b |= 1 << 11 }  // 12 — RIGHT_STICK click
        if s.contains(.home)    { b |= 1 << 12 }  // 13 — GUIDE / Home
        if s.contains(.capture) { b |= 1 << 13 }  // 14 — Capture
        if s.contains(.c)       { b |= 1 << 14 }  // 15 — C
        bytes[7] = UInt8(b & 0xFF)
        bytes[8] = UInt8(b >> 8)
        return Data(bytes)
    }

    // Pro layout: L/R are the top bumpers, ZL/ZR are the bottom digital
    // triggers. Pro has no analog trigger, so analog peg to 0xFF on press.
    func standardShoulders(_ state: ControllerState) -> StandardShoulders {
        let b = state.buttons
        return StandardShoulders(
            leftBumper: b.contains(.l),
            rightBumper: b.contains(.r),
            leftTriggerDigital: b.contains(.zl),
            rightTriggerDigital: b.contains(.zr),
            leftTriggerAnalog: b.contains(.zl) ? 0xFF : 0,
            rightTriggerAnalog: b.contains(.zr) ? 0xFF : 0
        )
    }

    func parseBLEReport(_ data: Data, calibration: StickCalibrationPair) -> ControllerState? {
        guard data.count >= 62 else { return nil }
        return Self.parse0x05(data, offset: 0, calibration: calibration)
    }

    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: StickCalibrationPair) -> ControllerState? {
        guard reportID == 0x05, data.count >= 62 else { return nil }
        return Self.parse0x05(data, offset: 0, calibration: calibration)
    }

    // Shared Report 0x05 layout (hid_reports.md). Pro-specific button semantics: bit 7 is
    // ZR (not Z), bits 8/9 are Minus/Plus (not Start), bits 10/11 are stick clicks.
    static func parse0x05(_ data: Data, offset: Int, calibration: StickCalibrationPair) -> ControllerState {
        let base = data.startIndex.advanced(by: offset)
        let (lx, ly) = NS2Sticks.unpack(data, at: base + 10)
        let (rx, ry) = NS2Sticks.unpack(data, at: base + 13)

        let btn = UInt32(data[base + 4])
            | (UInt32(data[base + 5]) << 8)
            | (UInt32(data[base + 6]) << 16)
            | (UInt32(data[base + 7]) << 24)

        var buttons: ButtonSet = []
        if btn & (1 << 0)  != 0 { buttons.insert(.y) }
        if btn & (1 << 1)  != 0 { buttons.insert(.x) }
        if btn & (1 << 2)  != 0 { buttons.insert(.b) }
        if btn & (1 << 3)  != 0 { buttons.insert(.a) }
        if btn & (1 << 6)  != 0 { buttons.insert(.r) }
        if btn & (1 << 7)  != 0 { buttons.insert(.zr) }
        if btn & (1 << 8)  != 0 { buttons.insert(.minus) }
        if btn & (1 << 9)  != 0 { buttons.insert(.plus) }
        if btn & (1 << 10) != 0 { buttons.insert(.stickR) }
        if btn & (1 << 11) != 0 { buttons.insert(.stickL) }
        if btn & (1 << 12) != 0 { buttons.insert(.home) }
        if btn & (1 << 13) != 0 { buttons.insert(.capture) }
        if btn & (1 << 14) != 0 { buttons.insert(.c) }
        if btn & (1 << 16) != 0 { buttons.insert(.dpadDown) }
        if btn & (1 << 17) != 0 { buttons.insert(.dpadUp) }
        if btn & (1 << 18) != 0 { buttons.insert(.dpadRight) }
        if btn & (1 << 19) != 0 { buttons.insert(.dpadLeft) }
        if btn & (1 << 22) != 0 { buttons.insert(.l) }
        if btn & (1 << 23) != 0 { buttons.insert(.zl) }

        return ControllerState(
            leftStick:  SIMD2(NS2Sticks.axis(lx, calibration.left, axis: .x),
                              NS2Sticks.axis(ly, calibration.left, axis: .y, invert: true)),
            rightStick: SIMD2(NS2Sticks.axis(rx, calibration.right, axis: .x),
                              NS2Sticks.axis(ry, calibration.right, axis: .y, invert: true)),
            triggerL: 0,
            triggerR: 0,
            buttons: buttons,
            imu: nil,
            timestamp: .now
        )
    }
}
