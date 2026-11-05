import Foundation
import CoreGraphics

enum TapAction: String {
    case toggleCapsLock
    case escape
    case none
}

final class CapsState {
    private let lock = NSLock()
    private var down = false
    private var pressTime: CFAbsoluteTime = 0
    private var usedAction = false
    private var watchdogGeneration = 0

    var isDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return down
    }

    func prefixKeyDown() {
        lock.lock()
        if down {
            lock.unlock()
            armWatchdog()
            return
        }
        down = true
        pressTime = CFAbsoluteTimeGetCurrent()
        usedAction = false
        lock.unlock()

        Log.info("prefix down")
        armWatchdog()
    }

    func prefixKeyUp() {
        lock.lock()
        watchdogGeneration &+= 1
        guard down else {
            lock.unlock()
            Log.warn("prefix up without down")
            return
        }
        down = false
        let elapsed = CFAbsoluteTimeGetCurrent() - pressTime
        let shouldTap = elapsed < (Double(Config.shared.keymap.chordMaxMs) / 1000.0) && !usedAction
        lock.unlock()

        Log.info("prefix up")
        if shouldTap {
            performTap()
        }
    }

    func markActionUsed() {
        lock.lock()
        usedAction = true
        lock.unlock()
        armWatchdog()
    }

    private func armWatchdog() {
        lock.lock()
        watchdogGeneration &+= 1
        let generation = watchdogGeneration
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let expired = self.watchdogGeneration == generation && self.down
            if expired {
                self.down = false
            }
            self.lock.unlock()
            if expired {
                Log.warn("prefix watchdog reset")
            }
        }
    }

    private func performTap() {
        switch Config.shared.keymap.tap {
        case .toggleCapsLock:
            let on = !HIDCapsLock.shared.isLocked
            HIDCapsLock.shared.setLocked(on)
            Log.info("prefixTap -> toggleCaps state=\(on ? "on" : "off")")
        case .escape:
            KeyPost.key(53)
        case .none:
            break
        }
    }
}
