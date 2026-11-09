import Foundation
import AppKit
import Carbon

enum InputSource {
    static func selectableSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.filter { source in
            let category = stringProperty(source, kTISPropertyInputSourceCategory as CFString)
            let type = stringProperty(source, kTISPropertyInputSourceType as CFString)
            return category == (kTISCategoryKeyboardInputSource as String) &&
                (type == (kTISTypeKeyboardLayout as String) || type == (kTISTypeKeyboardInputMode as String)) &&
                boolProperty(source, kTISPropertyInputSourceIsEnabled as CFString) &&
                boolProperty(source, kTISPropertyInputSourceIsSelectCapable as CFString)
        }
    }

    static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return id(of: source)
    }

    static func currentName() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return name(of: source)
    }

    /// 现场快照：`<id> (<name>) caps=1`，日志与菜单共用。
    static func currentSnapshot() -> String {
        let idText = currentID() ?? "unknown"
        let nameText = currentName() ?? "-"
        return "\(idText) (\(nameText)) caps=\(HIDCapsLock.shared.isLocked ? 1 : 0)"
    }

    /// 切到下一个可选输入源。
    ///
    /// 全程异步：CGEventTap 跑在主 run loop 上，这里任何 sleep 都会堵住事件管道，
    /// 旧实现的 `usleep(300_000)` 就是偶发按键失灵/切了不生效的来源之一。
    static func switchNext(completion: ((String?) -> Void)? = nil) {
        DispatchQueue.main.async {
            let sources = selectableSources()
            guard sources.count > 1 else {
                let only = sources.first.flatMap { name(of: $0) } ?? "unknown"
                Log.info("inputsource single = \(only)")
                completion?(nil)
                return
            }

            let fromID = currentID()
            let currentIndex = fromID.flatMap { current in
                sources.firstIndex { id(of: $0) == current }
            }
            let target = sources[((currentIndex ?? -1) + 1) % sources.count]
            guard let targetID = id(of: target) else {
                Log.warn("inputsource switch failed reason=no-target-id")
                completion?(nil)
                return
            }

            let caps = HIDCapsLock.shared.isLocked ? 1 : 0
            let status = TISSelectInputSource(target)
            Log.info("inputsource switch from=\(fromID ?? "unknown") to=\(targetID) caps=\(caps) status=\(status)")

            guard status == noErr else {
                completion?(nil)
                return
            }

            verify(targetID: targetID, attempt: 1, completion: completion)
        }
    }

    private static func verify(targetID: String, attempt: Int, completion: ((String?) -> Void)?) {
        let delay: TimeInterval = attempt == 1 ? 0.15 : 0.12
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let now = currentID()
            if now == targetID {
                let stage = attempt == 1 ? "ok" : "retry-ok"
                Log.info("inputsource switched to=\(targetID) caps=\(HIDCapsLock.shared.isLocked ? 1 : 0) verify=\(stage)")
                completion?(currentName() ?? targetID)
                return
            }

            if attempt == 1 {
                if let target = selectableSources().first(where: { id(of: $0) == targetID }) {
                    _ = TISSelectInputSource(target)
                }
                verify(targetID: targetID, attempt: 2, completion: completion)
                return
            }

            Log.warn("inputsource switch verify=fail current=\(now ?? "unknown") caps=\(HIDCapsLock.shared.isLocked ? 1 : 0)")
            completion?(nil)
        }
    }

    private static var observer: CFNotificationObserver?

    /// 监听系统级输入源切换，用于事后还原时间轴（偶发问题主要靠这个定位）。
    /// 把输入法现场完整打出来（"只能打英文"时点菜单里的诊断项）
    static func diagnose() -> String {
        var lines: [String] = []
        lines.append("caps=\(HIDCapsLock.shared.isLocked ? 1 : 0) current=\(currentSnapshot())")
        lines.append("front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        for source in selectableSources() {
            let selected = boolProperty(source, kTISPropertyInputSourceIsSelected)
            let enabled = boolProperty(source, kTISPropertyInputSourceIsEnabled)
            lines.append("  src id=\(id(of: source) ?? "?") name=\(name(of: source) ?? "?") selected=\(selected ? 1 : 0) enabled=\(enabled ? 1 : 0)")
        }
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
            let keys: [(String, CFString)] = [
                ("inputSourceID", kTISPropertyInputSourceID),
                ("inputModeID", kTISPropertyInputModeID),
                ("category", kTISPropertyInputSourceCategory),
                ("type", kTISPropertyInputSourceType)
            ]
            for (label, key) in keys {
                let value = TISGetInputSourceProperty(current, key)
                lines.append("  current.\(label)=\(value.map { "\($0)" } ?? "nil")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 强制切到中文输入法（非 keylayout 的输入源），已是中文源就重新 select 一次做重激活
    static func forceChineseInput(completion: ((String) -> Void)? = nil) {
        let sources = selectableSources()
        let currentValue = currentID()
        guard let chinese = sources.first(where: { (id(of: $0) ?? "").contains("inputmethod") }) else {
            completion?("no-chinese-source")
            return
        }
        let chineseID = id(of: chinese) ?? "?"
        if currentValue == chineseID {
            TISSelectInputSource(chinese)
            completion?("reassert=\(chineseID)")
        } else {
            let status = TISSelectInputSource(chinese)
            completion?("selected=\(chineseID) status=\(status) from=\(currentValue ?? "?")")
        }
    }

    /// 切到别的输入源再切回来，强制 IME 重新激活（卡在英文模式时的复位手段）
    static func cycleToReset(completion: ((String) -> Void)? = nil) {
        let sources = selectableSources()
        let currentID = currentID()
        guard let other = sources.first(where: { id(of: $0) != currentID }),
              let current = sources.first(where: { id(of: $0) == currentID }) else {
            completion?("no-target")
            return
        }
        let otherID = id(of: other) ?? "?"
        let status = TISSelectInputSource(other)
        Log.info("inputsource cycle step1 -> \(otherID) status=\(status)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let back = TISSelectInputSource(current)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let now = currentSnapshot()
                Log.info("inputsource cycle step2 status=\(back) now=\(now)")
                completion?("other=\(otherID) ok=\(back == noErr ? 1 : 0) now=\(now)")
            }
        }
    }

    /// 重新选中当前输入源（同源重选，一般无副作用）
    @discardableResult
    static func reselectCurrent() -> Bool {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        let status = TISSelectInputSource(current)
        Log.info("inputsource reselect status=\(status) current=\(currentSnapshot())")
        return status == noErr
    }

    static func startObserving() {
        guard observer == nil else { return }
        observer = CFNotificationObserver(name: kTISNotifySelectedKeyboardInputSourceChanged as CFString) {
            Log.info("inputsource changed -> \(currentSnapshot())")
        }
    }

    static func stopObserving() {
        observer?.stop()
        observer = nil
    }

    private static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue() == kCFBooleanTrue
    }

    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    static func debugID(_ source: TISInputSource) -> String? { id(of: source) }
    static func debugName(_ source: TISInputSource) -> String? { name(of: source) }

    private static func id(of source: TISInputSource) -> String? {
        stringProperty(source, kTISPropertyInputSourceID as CFString)
    }

    private static func name(of source: TISInputSource) -> String? {
        stringProperty(source, kTISPropertyLocalizedName as CFString)
    }
}

/// 分布式通知的薄封装（TIS 的输入源变化通知走 distributed center）。
final class CFNotificationObserver {
    private let name: CFString
    private let handler: () -> Void
    private var registered = false

    init(name: CFString, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
        let box = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            box,
            { _, observation, _, _, _ in
                guard let observation = observation else { return }
                Unmanaged<CFNotificationObserver>.fromOpaque(observation)
                    .takeUnretainedValue()
                    .handle()
            },
            name,
            nil,
            .deliverImmediately
        )
        registered = true
    }

    private func handle() {
        handler()
    }

    func stop() {
        guard registered else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name),
            nil
        )
        registered = false
    }

    deinit { stop() }
}
