import Foundation
import IOKit.ps

/// Reports whether the Mac is on AC power and notifies when the source changes.
final class PowerSource {
    var onChange: (() -> Void)?
    private var runLoopSource: CFRunLoopSource?

    static func isOnAC() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue()
        else { return true }
        return (type as String) == kIOPSACPowerValue
    }

    func startObserving() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let me = Unmanaged<PowerSource>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { me.onChange?() }
        }
        guard let src = IOPSNotificationCreateRunLoopSource(callback, ctx)?.takeRetainedValue() else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        runLoopSource = src
    }

    deinit {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }
}
