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
    private var lockIntent: Bool
    private var suppressUntil: CFAbsoluteTime = 0

    init() {
        lockIntent = HIDCapsLock.shared.isLocked
    }

    var isDown: Bool {
        lock.lock()
        defer { lock.unlock() }
        return down
    }

    func markActionUsed() {
        lock.lock()
        defer { lock.unlock() }
        usedAction = true
    }

    func capsFlagsChanged() {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if now < suppressUntil {
            lock.unlock()
            return
        }
        down.toggle()
        let isDownNow = down
        if isDownNow {
            pressTime = now
            usedAction = false
        }
        let shouldTap = !isDownNow
            && (now - pressTime) < (Double(Config.shared.keymap.chordMaxMs) / 1000.0)
            && !usedAction
        lock.unlock()

        if isDownNow {
            Log.info("capsDown")
            reconcile()
        } else {
            Log.info("capsUp")
            if shouldTap {
                performTap()
            }
            reconcile()
        }
    }

    private func reconcile() {
        lock.lock()
        let desired = lockIntent
        lock.unlock()

        guard HIDCapsLock.shared.isLocked != desired else { return }

        lock.lock()
        suppressUntil = CFAbsoluteTimeGetCurrent() + 0.03
        lock.unlock()
        HIDCapsLock.shared.reconcile(desired: desired)
    }

    private func performTap() {
        switch Config.shared.keymap.tap {
        case .toggleCapsLock:
            lock.lock()
            lockIntent.toggle()
            let on = lockIntent
            suppressUntil = CFAbsoluteTimeGetCurrent() + 0.03
            lock.unlock()
            HIDCapsLock.shared.setLocked(on)
            Log.info("capsTap -> toggleCaps state=\(on ? "on" : "off")")
        case .escape:
            KeyPost.key(53)
        case .none:
            break
        }
    }
}
