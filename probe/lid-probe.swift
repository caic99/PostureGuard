// Quick probe: read the hidden MacBook lid angle sensor via IOKit HID.
// Sensor page (0x20), usage 0x8A, feature report ID 1, angle in degrees.
import Foundation
import IOKit.hid

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching: [String: Any] = [
    kIOHIDPrimaryUsagePageKey: 0x0020,
    kIOHIDPrimaryUsageKey: 0x008A,
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("manager open: \(String(format: "0x%08x", openResult))")

guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !deviceSet.isEmpty else {
    print("NO lid angle sensor device found")
    exit(1)
}
print("found \(deviceSet.count) matching device(s)")

for device in deviceSet {
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    print("device: \(product)")
    let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    print("  open: \(String(format: "0x%08x", r))")
    var report = [UInt8](repeating: 0, count: 8)
    var length: CFIndex = report.count
    let res = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
    print("  getReport: \(String(format: "0x%08x", res)) len=\(length) bytes=\(report.map { String(format: "%02x", $0) }.joined(separator: " "))")
    if res == kIOReturnSuccess && length >= 3 {
        let raw = UInt16(report[1]) | (UInt16(report[2]) << 8)
        print("  LID ANGLE = \(raw) degrees")
    }
}
