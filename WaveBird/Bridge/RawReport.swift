import Foundation

// Unparsed transport report handed from the main-actor event router to a
// per-device dispatch task. The parse (profile.parseBLE/USBReport) runs inside
// that task — off the main actor for solo devices — so input processing no
// longer shares a thread with the UI. reportID is nil for the BLE shared input
// (Report 0x05, unprefixed on the wire); set for USB / secondary inputs.
struct RawReport: Sendable {
    let reportID: UInt8?
    let data: Data
}
