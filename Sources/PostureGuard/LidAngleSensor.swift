import Foundation
import IOKit.hid

/// Reads the hidden lid (hinge) angle sensor present on Apple Silicon MacBooks.
///
/// The sensor is a HID device on the Sensor usage page (0x20) with usage 0x8A.
/// Feature report ID 1 returns the hinge angle in degrees as a little-endian
/// UInt16: 0 ≈ closed, ~90 = screen vertical, ~180 = flat.
final class LidAngleSensor {
    // The manager must outlive the device: releasing it tears down the device
    // connection and every subsequent GetReport fails.
    private let manager: IOHIDManager
    private let device: IOHIDDevice

    init?() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let matching: [String: Any] = [
            kIOHIDPrimaryUsagePageKey: 0x0020,
            kIOHIDPrimaryUsageKey: 0x008A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let dev = devices.first,
              IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return nil }
        device = dev
    }

    /// Current lid angle in degrees, or nil if the read fails.
    func read() -> Double? {
        var report = [UInt8](repeating: 0, count: 8)
        var length: CFIndex = report.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess,
              length >= 3
        else { return nil }
        let raw = UInt16(report[1]) | (UInt16(report[2]) << 8)
        guard raw <= 360 else { return nil }
        return Double(raw)
    }
}
