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
    private var longPressFired = false
    private var longPressGeneration = 0

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
        longPressFired = false
        lock.unlock()

        Log.info("prefix down")
        armWatchdog()
        armLongPress()
    }

    func prefixKeyUp() {
        lock.lock()
        watchdogGeneration &+= 1
        longPressGeneration &+= 1
        guard down else {
            lock.unlock()
            Log.warn("prefix up without down")
            return
        }
        down = false
        let elapsed = CFAbsoluteTimeGetCurrent() - pressTime
        let actionUsed = usedAction
        let fired = longPressFired
        if fired {
            longPressFired = false
        }
        lock.unlock()

        if fired {
            Log.info("prefix up (longpress, no tap)")
            return
        }
        Log.info("prefix up")
        if actionUsed {
            return
        }
        if elapsed < (Double(Config.shared.keymap.chordMaxMs) / 1000.0) {
            performTap()
        }
    }

    func markActionUsed() {
        lock.lock()
        usedAction = true
        longPressGeneration &+= 1
        lock.unlock()
        armWatchdog()
    }

    func forceReset(reason: String) {
        lock.lock()
        watchdogGeneration &+= 1
        longPressGeneration &+= 1
        down = false
        usedAction = false
        longPressFired = false
        lock.unlock()
        Log.info("prefix reset reason=\(reason)")
    }

    private func armLongPress() {
        lock.lock()
        longPressGeneration &+= 1
        let generation = longPressGeneration
        lock.unlock()

        let ms = Config.shared.keymap.longPressMs
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ms) / 1000.0)) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let fire = self.longPressGeneration == generation && self.down && !self.usedAction && !self.longPressFired
            if fire {
                self.longPressFired = true
            }
            self.lock.unlock()
            guard fire else { return }
            self.performLongPress(elapsedMs: ms)
            self.armWatchdog()
        }
    }

    private func armWatchdog() {
        lock.lock()
        watchdogGeneration &+= 1
        let generation = watchdogGeneration
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
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
        let action = Config.shared.keymap.tapAction
        Log.info("prefix tap -> \(action.name)")
        if action == .toggleCapsLock {
            // 走真实按键事件：IOHIDSetModifierLockState 直接改系统状态会让
            // WindowServer / 输入法看到的 flags 与状态不同步（表现为"切回中文却只能打英文"）
            let before = HIDCapsLock.shared.isLocked
            KeyPost.key(57)   // kVK_CapsLock
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                let after = HIDCapsLock.shared.isLocked
                if after == before {
                    HIDCapsLock.shared.setLocked(!before)
                    Log.warn("prefixTap caps event ineffective -> hid fallback state=\(!before ? 1 : 0)")
                } else {
                    Log.info("prefixTap toggleCaps via=event before=\(before ? 1 : 0) after=\(after ? 1 : 0)")
                }
            }
            return
        }
        ActionRunner.run(action)
    }

    private func performLongPress(elapsedMs: Int) {
        guard Config.shared.keymap.longPress == "switchInputSource" else {
            return
        }
        Log.info("longpress \(elapsedMs)ms -> switchInputSource begin (\(InputSource.currentSnapshot()))")
        InputSource.switchNext { name in
            if let name = name {
                Log.info("longpress \(elapsedMs)ms -> switchInputSource -> \(name)")
            } else {
                Log.warn("longpress \(elapsedMs)ms -> switchInputSource failed")
            }
        }
    }
}
