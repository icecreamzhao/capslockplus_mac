import Foundation
import IOKit

@_silgen_name("IOHIDGetModifierLockState")
func IOHIDGetModifierLockState(_ handle: io_connect_t, _ selector: Int32, _ state: UnsafeMutablePointer<Bool>) -> kern_return_t

@_silgen_name("IOHIDSetModifierLockState")
func IOHIDSetModifierLockState(_ handle: io_connect_t, _ selector: Int32, _ state: Bool) -> kern_return_t

let kIOHIDCapsLockStateSelector: Int32 = 1

final class HIDCapsLock {
    static let shared = HIDCapsLock()

    private let lock = NSLock()
    private var lastKnownLocked = false

    private init() {}

    private func withConnection<T>(_ body: (io_connect_t) -> T?) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else {
            Log.error("hid service unavailable")
            return nil
        }
        var conn: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, 1, &conn)
        _ = IOObjectRelease(service)
        guard opened == KERN_SUCCESS, conn != 0 else {
            Log.warn("hid open failed kr=\(opened)")
            return nil
        }
        defer { _ = IOServiceClose(conn) }
        return body(conn)
    }

    var isLocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        let state = withConnection { conn -> Bool? in
            var value = false
            let kr = IOHIDGetModifierLockState(conn, kIOHIDCapsLockStateSelector, &value)
            guard kr == KERN_SUCCESS else {
                Log.warn("hid isLocked failed kr=\(kr)")
                return nil
            }
            return value
        }
        guard let state = state else { return lastKnownLocked }
        lastKnownLocked = state
        return state
    }

    func setLocked(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _ = withConnection { conn -> Void? in
            let kr = IOHIDSetModifierLockState(conn, kIOHIDCapsLockStateSelector, on)
            if kr == KERN_SUCCESS {
                lastKnownLocked = on
            } else {
                Log.warn("hid setLocked failed kr=\(kr)")
            }
            return ()
        }
    }

    @discardableResult
    func reconcile(desired: Bool) -> Bool {
        guard isLocked != desired else { return false }
        setLocked(desired)
        return true
    }
}
