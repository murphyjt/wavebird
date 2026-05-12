@preconcurrency import CoreBluetooth
import Foundation

protocol ControllerProfile: Sendable {
    var name: String { get }
    var bleMatcher: BLEMatcher? { get }
    var usbMatcher: USBMatcher? { get }

    var hidDescriptor: Data { get }
    var hidVendorID: UInt16 { get }
    var hidProductID: UInt16 { get }

    func buildHIDReport(_ state: ControllerState) -> Data
    func parseBLEReport(_ data: Data, calibration: StickCalibrationPair) -> ControllerState?
    func parseUSBReport(_ data: Data, reportID: UInt8, calibration: StickCalibrationPair) -> ControllerState?
}

// Per-axis stick calibration extracted from controller flash. All values are in the
// raw 12-bit ADC space. `max` is the deflection above `neutral`, `min` is below.
struct StickCalibration: Sendable, Equatable {
    var neutralX: UInt16
    var neutralY: UInt16
    var maxX: UInt16
    var maxY: UInt16
    var minX: UInt16
    var minY: UInt16
}

struct StickCalibrationPair: Sendable, Equatable {
    var left: StickCalibration? = nil
    var right: StickCalibration? = nil
}

struct BLEMatcher: Sendable {
    let productID: UInt16
    let serviceUUID: CBUUID
    let inputCharacteristic: CBUUID
    let outputCharacteristic: CBUUID?
    let responseCharacteristics: [ResponseChannel]
    let initCommands: [Data]
}

struct ResponseChannel: Sendable {
    let uuid: CBUUID
    let handle: UInt16
}

struct USBMatcher: Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let initWrites: [USBInitStep]
}

struct USBInitStep: Sendable {
    let reportID: UInt8
    let payload: Data
}

enum TransportMatcher: Sendable {
    case ble(BLEMatcher)
    case usb(USBMatcher)
}
