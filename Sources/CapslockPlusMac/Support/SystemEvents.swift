import Foundation
import AppKit
import IOKit
import IOKit.hid

private func hidDeviceNotificationCallback(
    refcon: UnsafeMutableRawPointer?,
    iterator: io_iterator_t
) {
    guard let refcon = refcon else { return }
    let events = Unmanaged<SystemEvents>.fromOpaque(UnsafeRawPointer(refcon)).takeUnretainedValue()
    events.hidDevicesChanged(iterator: iterator)
}

final class SystemEvents {
    static let shared = SystemEvents()

    var onWake: (() -> Void)?
    var onHIDDeviceChange: (() -> Void)?

    private var wakeObserver: NSObjectProtocol?
    private var wakeRetry: DispatchWorkItem?
    private var notificationPort: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?
    private var iterator: io_iterator_t = 0

    private init() {}

    func start() {
        guard wakeObserver == nil else { return }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Log.info("wake recover")
            self.onWake?()

            self.wakeRetry?.cancel()
            let retry = DispatchWorkItem { [weak self] in
                self?.wakeRetry = nil
                self?.onWake?()
            }
            self.wakeRetry = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: retry)
        }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Log.error("hid notify port failed")
            return
        }
        notificationPort = port

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            IOServiceMatching(kIOHIDDeviceKey),
            hidDeviceNotificationCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            Log.error("hid notify failed kr=\(result)")
            if iterator != 0 {
                _ = IOObjectRelease(iterator)
            }
            cleanupHID()
            return
        }

        self.iterator = iterator
        consume(iterator)
    }

    func stop() {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        wakeRetry?.cancel()
        wakeRetry = nil

        cleanupHID()
    }

    fileprivate func hidDevicesChanged(iterator: io_iterator_t) {
        consume(iterator)
        DispatchQueue.main.async { [weak self] in
            self?.onHIDDeviceChange?()
        }
    }

    private func consume(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            _ = IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func cleanupHID() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if iterator != 0 {
            _ = IOObjectRelease(iterator)
            iterator = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
    }
}
