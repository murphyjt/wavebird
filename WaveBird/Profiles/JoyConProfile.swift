@preconcurrency import CoreBluetooth
import Foundation

// Joy-Con 2 (L or R). Both halves subscribe to shared Report 0x05; each
// populates only its own stick and its own button bits, leaving the other
// half's fields zero. The pair coordinator merges two single-side states
// into one virtual HID — solo Joy-Con play is not supported.
struct JoyConProfile: ControllerProfile {
    enum Side: Sendable {
        case left, right
    }

    let side: Side

    var name: String {
        switch side {
        case .left:  "Joy-Con 2 (L)"
        case .right: "Joy-Con 2 (R)"
        }
    }

    // Same set as Pro minus .unknown3 (Pro-only) and .mouse (we don't expose
    // the mouse feature on macOS). .imu enabled so the merged state can carry
    // motion from either Joy-Con.
    private static let features: NS2Feature = [.buttons, .analog, .imu, .rumble]

    private var ns2Variant: NS2ControllerType {
        switch side {
        case .left:  .joyConL
        case .right: .joyConR
        }
    }

    var bleMatcher: BLEMatcher? {
        let responseHandles = [NS2Handle.commandResponse1, NS2Handle.commandResponse2]
        let responseChannels: [ResponseChannel] = responseHandles.compactMap { h in
            NS2Handle.uuid(h, for: ns2Variant).map { ResponseChannel(uuid: $0, handle: h) }
        }
        return BLEMatcher(
            productID: hidProductID,
            serviceUUID: CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD0"),
            inputCharacteristic: CBUUID(string: "AB7DE9BE-89FE-49AD-828F-118F09DF7FD2"),
            outputCharacteristic: NS2Handle.uuid(NS2Handle.commandWriteShared, for: ns2Variant),
            responseCharacteristics: responseChannels,
            initCommands: [
                NS2Commands.handshake,
                NS2Commands.factoryDataRead,
                // Each Joy-Con stores its single stick's calibration in the
                // "primary" slot (flash 0x130A8, read via the 0x13080 block) —
                // regardless of side. For R, handleCommandResponse below remaps
                // the response into rightCalibration so the right-stick parser
                // picks it up.
                NS2Commands.leftStickCalibrationRead,
                NS2Commands.firmwareInfo,
                NS2Commands.pairingInfoRead,
                NS2Commands.connectionVibration,
                NS2Commands.player1LED,
                NS2Commands.setFeatureMask(Self.features),
                NS2Commands.sendVibrationData,
                NS2Commands.enableFeatures(Self.features),
            ],
            vibrationCharacteristic: NS2Handle.uuid(0x0012, for: ns2Variant)
        )
    }

    var usbMatcher: USBMatcher? { nil }

    let hidVendorID: UInt16 = 0x057E
    var hidProductID: UInt16 {
        switch side {
        case .left:  0x2067
        case .right: 0x2066
        }
    }

    var vendorPassthroughDescriptor: Data { VirtualHIDDevice.ns2VendorDescriptor(reportID: 0x05, byteCount: 63) }

    // Mirror Pro's 15 ms heartbeat for HD rumble continuity.
    var rumbleRefreshInterval: Duration? { .milliseconds(15) }

    func handleCommandResponse(request: Data, response: Data) -> ControllerMetadata? {
        // R's single stick lives in the same flash slot Pro/GC use for the left
        // stick. Remap that response into rightCalibration so the right-stick
        // parser sees it via calibration.right. L falls through to the default
        // handler, which already lands the response in leftCalibration.
        if side == .right,
           request.first == 0x02,
           NS2Responses.flashReadAddress(of: request) == 0x13080,
           let cal = NS2Responses.parseStickCalibration(response.dropFirst(16)) {
            return ControllerMetadata(rightCalibration: cal)
        }
        return NS2Responses.parseStandard(request: request, response: response)
    }

    func parseBLEReport(_ data: Data, calibration: ControllerCalibration) -> ControllerState? {
        NS2Report0x05.decode(data).map { decode($0, calibration: calibration) }
    }

    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: ControllerCalibration) -> ControllerState? {
        guard reportID == 0x05 else { return nil }
        return NS2Report0x05.decode(data).map { decode($0, calibration: calibration) }
    }

    // Each Joy-Con populates only its own half of Report 0x05.
    //   L: left stick (offset 0xA) + L-side button bits.
    //   R: right stick (offset 0xD) + R-side button bits.
    private func decode(_ d: NS2Report0x05.Decoded, calibration: ControllerCalibration) -> ControllerState {
        let table: [NS2ButtonBits.Entry]
        let leftStick: SIMD2<Int16>
        let rightStick: SIMD2<Int16>
        switch side {
        case .left:
            table = NS2ButtonBits.joyConL
            leftStick = NS2Sticks.decode(d.leftStickRaw, calibration.left)
            rightStick = .zero
        case .right:
            table = NS2ButtonBits.joyConR
            leftStick = .zero
            rightStick = NS2Sticks.decode(d.rightStickRaw, calibration.right)
        }
        let buttons = NS2ButtonBits.decode(d.buttonBits, table: table)

        let shoulders: StandardShoulders
        switch side {
        case .left:
            shoulders = StandardShoulders(
                leftBumper: buttons.contains(.l),
                rightBumper: false,
                leftTriggerDigital: buttons.contains(.zl),
                rightTriggerDigital: false,
                leftTriggerAnalog: buttons.contains(.zl) ? 0xFF : 0,
                rightTriggerAnalog: 0
            )
        case .right:
            shoulders = StandardShoulders(
                leftBumper: false,
                rightBumper: buttons.contains(.r),
                leftTriggerDigital: false,
                rightTriggerDigital: buttons.contains(.zr),
                leftTriggerAnalog: 0,
                rightTriggerAnalog: buttons.contains(.zr) ? 0xFF : 0
            )
        }

        return ControllerState(
            leftStick:  leftStick,
            rightStick: rightStick,
            triggerL:   0,
            triggerR:   0,
            buttons:    buttons,
            imu:        nil,
            timestamp:  .now,
            shoulders:  shoulders
        )
    }

    // Single LRA per Joy-Con. The pair coordinator preserves the convention
    // that L carries leftAmp + left-side carrier/scale fields and R carries
    // the right half when splitting a stereo RumbleCommand across the two
    // devices.
    func encodeRumble(_ cmd: RumbleCommand, sequence: UInt8, settings: RumbleSettings.Snapshot) -> Data? {
        switch side {
        case .left:
            JoyConSharedRumble.encode(
                amp: cmd.leftAmp,
                freqOverride: cmd.leftFreqOverride,
                hiFreq: settings.leftHiFreq,
                loFreq: settings.leftLoFreq,
                hiAmpScale: settings.leftHiAmpScale,
                loAmpScale: settings.leftLoAmpScale,
                intensity: settings.intensity,
                sequence: sequence
            )
        case .right:
            JoyConSharedRumble.encode(
                amp: cmd.rightAmp,
                freqOverride: cmd.rightFreqOverride,
                hiFreq: settings.rightHiFreq,
                loFreq: settings.rightLoFreq,
                hiAmpScale: settings.rightHiAmpScale,
                loAmpScale: settings.rightLoAmpScale,
                intensity: settings.intensity,
                sequence: sequence
            )
        }
    }
}
