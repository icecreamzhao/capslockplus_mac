import Foundation
import IOKit

@_silgen_name("IOHIDGetModifierLockState")
func IOHIDGetModifierLockState(_ handle: io_service_t, _ selector: Int32) -> Bool

@_silgen_name("IOHIDSetModifierLockState")
func IOHIDSetModifierLockState(_ handle: io_service_t, _ selector: Int32, _ state: Bool) -> IOReturn

let kIOHIDCapsLockStateSelector: Int32 = 1

final class HIDCapsLock {
    static let shared = HIDCapsLock()

    private let lock = NSLock()
    private var handle: io_service_t = 0

    private init() {}

    private func service() -> io_service_t {
        lock.lock()
        defer { lock.unlock() }
        if handle == 0 {
            handle = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
            if handle == 0 {
                Log.error("hid service unavailable")
            }
        }
        return handle
    }

    var isLocked: Bool {
        let service = self.service()
        guard service != 0 else { return false }
        return IOHIDGetModifierLockState(service, kIOHIDCapsLockStateSelector)
    }

    func setLocked(_ on: Bool) {
        let service = self.service()
        guard service != 0 else { return }
        let result = IOHIDSetModifierLockState(service, kIOHIDCapsLockStateSelector, on)
        if result != 0 {
            Log.warn("hid setLocked failed result=\(result)")
        }
    }

    @discardableResult
    func reconcile(desired: Bool) -> Bool {
        guard isLocked != desired else { return false }
        setLocked(desired)
        return true
    }

    deinit {
        lock.lock()
        if handle != 0 {
            _ = IOObjectRelease(handle)
            handle = 0
        }
        lock.unlock()
    }
}
