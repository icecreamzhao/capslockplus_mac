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
            // 合成的 caps 按键事件不会改系统锁状态（实测 toggled=0），只有 HID 直设有效
            let on = !HIDCapsLock.shared.isLocked
            HIDCapsLock.shared.setLocked(on)
            Log.info("prefixTap -> toggleCaps state=\(on ? "on" : "off") now=\(HIDCapsLock.shared.isLocked ? 1 : 0)")
            return
        }
        ActionRunner.run(action)
    }

    private func performLongPress(elapsedMs: Int) {
        guard Config.shared.keymap.longPress == "switchInputSource" else {
            return
        }
        // 大写锁定开着时切到中文输入法，新激活的 IME 会以英文模式初始化（之后就卡住），先关掉
        if HIDCapsLock.shared.isLocked {
            HIDCapsLock.shared.setLocked(false)
            Log.warn("longpress caps was locked -> turned off before switching IME")
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
