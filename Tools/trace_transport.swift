import Foundation
import IOKit.hid

print("Scanning for all HID devices...")

let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(manager, nil) // Match all devices
IOHIDManagerOpen(manager, 0)

guard let deviceSet = IOHIDManagerCopyDevices(manager) else {
    print("No devices found.")
    exit(0)
}

let devices = deviceSet as! Set<IOHIDDevice>
for device in devices {
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
    let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
    let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
    
    if product.contains("Pro Controller") || (vid == 0x057E && pid == 0x2009) {
        let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "Unknown"
        let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String ?? "Unknown"
        
        print("MATCH FOUND:")
        print("  Product: \(product)")
        print("  Manufacturer: \(manufacturer)")
        print("  VID/PID: \(String(format: "0x%04X", vid))/\(String(format: "0x%04X", pid))")
        print("  Transport Property: \"\(transport)\"")
        print("---------------------------------------")
    }
}
