import Foundation
import Testing
@testable import WaveBird

struct NS2ConsoleTests {
    // Hardware capture published with joycon2android's ConsolePacketParserTest.
    private let restingRight = Data([0x02, 0x18, 0, 0, 7, 0, 0xF8, 0x7F, 0, 0, 0, 0, 0, 0, 0, 0x1E])

    private func state(left: Bool, bit: Int? = nil) throws -> ControllerState {
        var input = restingRight
        if let bit { input[2 + bit / 8] |= 1 << (bit % 8) }
        let shared = try #require(NS2Console.sharedReport(input, left: left))
        return try #require(JoyConProfile(side: left ? .left : .right)
            .parseBLEReport(shared, calibration: ControllerCalibration()))
    }

    @Test func capturedStickAndIdleButtons() throws {
        let right = try state(left: false)
        #expect(right.buttons.isEmpty)
        #expect(right.rightStick == SIMD2<Int16>(0, 1))
        #expect(right.leftStick == .zero)
        #expect(right.imu == nil)
        let left = try state(left: true)
        #expect(left.leftStick == SIMD2<Int16>(0, 1))
        #expect(left.rightStick == .zero)
    }

    @Test func everyLeftButton() throws {
        let expected: [(Int, ButtonSet)] = [
            (0, .dpadDown), (1, .dpadRight), (2, .dpadLeft), (3, .dpadUp),
            (4, .l), (5, .zl), (6, .minus), (7, .stickL), (8, .capture), (14, .sr), (15, .sl),
        ]
        for (bit, button) in expected { #expect(try state(left: true, bit: bit).buttons == button) }
        for bit in [9, 10, 11, 12, 13] { #expect(try state(left: true, bit: bit).buttons.isEmpty) }
    }

    @Test func everyRightButton() throws {
        let expected: [(Int, ButtonSet)] = [
            (0, .b), (1, .a), (2, .y), (3, .x), (4, .r), (5, .zr),
            (6, .plus), (7, .stickR), (8, .home), (12, .c), (14, .sr), (15, .sl),
        ]
        for (bit, button) in expected { #expect(try state(left: false, bit: bit).buttons == button) }
        for bit in [9, 10, 11, 13] { #expect(try state(left: false, bit: bit).buttons.isEmpty) }
    }

    @Test func pairPreservesBothSticksAndShoulders() throws {
        var l = restingRight; l[2] = 0x30; l[5] = 0xFF; l[6] = 0x0F; l[7] = 0
        var r = restingRight; r[2] = 0x33; r[5] = 0; r[6] = 0xF0; r[7] = 0xFF
        let leftReport = try #require(NS2Console.sharedReport(l, left: true))
        let rightReport = try #require(NS2Console.sharedReport(r, left: false))
        let left = try #require(JoyConProfile(side: .left).parseBLEReport(leftReport, calibration: ControllerCalibration()))
        let right = try #require(JoyConProfile(side: .right).parseBLEReport(rightReport, calibration: ControllerCalibration()))
        let merged = JoyConPairProfile.merge(left: left, right: right)
        #expect(merged.leftStick == SIMD2<Int16>(2047, 2047))
        #expect(merged.rightStick == SIMD2<Int16>(-2047, -2047))
        #expect(merged.buttons == [.l, .zl, .r, .zr, .a, .b])
        #expect(merged.shoulders.leftBumper && merged.shoulders.rightBumper)
        #expect(merged.shoulders.leftTriggerAnalog == 255 && merged.shoulders.rightTriggerAnalog == 255)
        let surviving = JoyConPairProfile.merge(left: left, right: nil)
        #expect(surviving.rightStick == .zero)
        #expect(!surviving.buttons.contains(.a))
    }

    @Test func malformedAndSlicedPackets() throws {
        for length in 0..<8 {
            #expect(NS2Console.sharedReport(Data(repeating: 0, count: length), left: true) == nil)
        }
        var bad = restingRight; bad[4] = 0
        #expect(NS2Console.sharedReport(bad, left: false) == nil)
        let sliced = (Data([0xFF]) + restingRight).dropFirst()
        #expect(NS2Console.sharedReport(sliced, left: false) == NS2Console.sharedReport(restingRight, left: false))
    }

    @Test func consoleCommandFramingAndNoPairingWrites() {
        #expect(NS2Console.frame(NS2Commands.handshake) == Data(repeating: 0, count: 17) + Data([7, 0x91, 1, 1, 0, 0, 0, 0]))
        #expect(NS2Console.spiRead(0x13000, length: 0x40) == Data([2, 0x91, 1, 4, 0, 8, 0, 0, 0x40, 0x7E, 0, 0, 0, 0x30, 1, 0]))
        #expect(NS2Console.initCommands.allSatisfy { $0.first != 0x15 })
    }

    @Test func lateNintendoReturnRestoresIdentityAndCalibration() {
        let id = DeviceID(transport: .ble, raw: UUID())
        let cal = StickCalibration(neutralX: 2048, neutralY: 2048,
                                   maxX: 1800, maxY: 1800, minX: 1800, minY: 1800)
        var record = DeviceRecord(id: id, profile: JoyConProfile(side: .left),
                                  advertisement: AdvertisementInfo(vendorID: 0x057E, productID: 0x2067, localName: nil, rssi: nil),
                                  connectionState: .connected, virtualHID: nil, serial: "Nintendo-serial",
                                  calibration: ControllerCalibration(left: cal), outputModeID: "switchPro")
        record.setConsoleProtocol(true)
        #expect(record.serial == "console-\(id.raw.uuidString)")
        #expect(record.calibration.left == nil)
        record.setConsoleProtocol(true) // Repeated events must not overwrite the saved identity.
        record.setConsoleProtocol(false)
        #expect(record.serial == "Nintendo-serial")
        #expect(record.calibration.left == cal)
        #expect(!record.usesConsoleProtocol)
    }

    @Test func repliesMatchCommandSubcommandAndSPIAddress() {
        let response = Data([2, 1, 1, 4, 0x10, 0x78, 0, 0, 0x40, 0, 0, 0, 0, 0x30, 1, 0])
        let request = NS2Console.spiRead(0x13000, length: 0x40)
        #expect(NS2Console.reply(response, to: request, console: false) == response)
        #expect(NS2Console.reply(Data(repeating: 0, count: 17) + response, to: request, console: true) == response)
        #expect(NS2Console.reply(response, to: NS2Console.spiRead(0x13080, length: 0x40), console: true) == nil)
        #expect(NS2Console.reply(response, to: NS2Commands.handshake, console: true) == nil)
        #expect(NS2Console.reply(Data([2, 1, 1, 4]), to: request, console: true) == nil)
        #expect(NS2Console.reply(response, to: Data([2, 0x91, 1, 4]), console: true) == nil)
    }
}
