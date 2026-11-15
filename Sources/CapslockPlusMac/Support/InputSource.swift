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
            let front = AppFocus.frontBundleID()
            let status = TISSelectInputSource(target)
            Log.info("inputsource switch from=\(fromID ?? "unknown") to=\(targetID) caps=\(caps) front=\(front) status=\(status)")

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
                Log.info("inputsource switched to=\(targetID) caps=\(HIDCapsLock.shared.isLocked ? 1 : 0) front=\(AppFocus.frontBundleID()) verify=\(stage)")
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
                lines.append("  current.\(label)=\(propertyString(current, key) ?? "nil")")
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

    /// 输入法卡住时的修复。按形态分两条路，不要一上来就杀进程：
    ///
    /// 1. **源已是中文 + IME 进程活着** → 卡的是**前台 App 的输入上下文**。
    ///    实测 Terminal.app：TIS 是「简体拼音」、iPhone Mirroring 有候选框，唯独 Terminal 仍然按 ABC
    ///    收字符；切到别处打几个字再切回来才恢复。这种情况只做一次焦点往返，让它重建上下文，
    ///    不杀进程（杀了会丢正在拼的字，还空档约 1 秒）。
    /// 2. **源不是中文 / IME 没在跑** → 重建进程：SIGKILL（SIGTERM 被 IME 吞掉）→ 等旧 pid 消失
    ///    → 重选中文源 → 0.45s / 1.1s 两次确认。
    ///
    /// 为什么要二次确认：HIToolbox 在 IME 进程死掉后会把全局源**回落成 ABC**。
    /// 旧实现固定 0.8s 重选一次就宣布成功，日志里出现过 10 秒后 `current=com.apple.keylayout.ABC`，
    /// 也就是"修完了"其实没修。
    static func restartIMEServer(reason: String = "menu", completion: ((String) -> Void)? = nil) {
        let front = AppFocus.frontBundleID()
        let pidBefore = imePID()
        Log.info("imeRestart begin reason=\(reason) front=\(front) caps=\(HIDCapsLock.shared.isLocked ? 1 : 0) current=\(currentSnapshot()) imePid=\(pidBefore.map(String.init) ?? "none")")
        for line in diagnose().split(separator: "\n") {
            Log.info("imeRestart dump | \(line)")
        }

        let current = currentID() ?? ""
        if current.contains("inputmethod"), pidBefore != nil {
            Log.info("imeRestart mode=context front=\(front) reason=source-ok-ime-alive")
            nudge(front: front, prefix: "imeRestart") { result in
                let line = "imeRestart mode=context front=\(front) result=\(result)"
                Log.info(line)
                completion?(line)
            }
            return
        }

        let killed = (run("/usr/bin/pkill", ["-9", "-f", "/Input Methods/SCIM.app/"])?.status ?? -1) == 0
        Log.info("imeRestart pkill killed=\(killed ? 1 : 0) pid=\(pidBefore.map(String.init) ?? "none")")

        waitForIMEGone(oldPid: pidBefore, deadline: Date().addingTimeInterval(2.5)) {
            forceChineseInput { result in
                Log.info("imeRestart reselect \(result)")
                confirmChinese(attempt: 1, front: front, killed: killed, completion: completion)
            }
        }
    }

    /// 等旧 IME 进程真的退出，再重选——旧的 0.8s 固定等待会撞在进程拆除过程中
    private static func waitForIMEGone(oldPid: pid_t?, deadline: Date, then: @escaping () -> Void) {
        guard let oldPid = oldPid else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: then)
            return
        }
        if imePID() != oldPid || Date() >= deadline {
            Log.info("imeRestart old-pid-gone pid=\(oldPid) now=\(imePID().map(String.init) ?? "none")")
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            waitForIMEGone(oldPid: oldPid, deadline: deadline, then: then)
        }
    }

    private static func confirmChinese(attempt: Int, front: String, killed: Bool,
                                       completion: ((String) -> Void)?) {
        let delay: TimeInterval = attempt == 1 ? 0.45 : 1.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let current = currentID() ?? "?"
            let isIME = current.contains("inputmethod")
            Log.info("imeRestart confirm attempt=\(attempt) current=\(current) imePid=\(imePID().map(String.init) ?? "none")")
            if isIME || attempt >= 3 {
                finishRestart(killed: killed, front: front, fellBack: !isIME, completion: completion)
                return
            }
            Log.warn("imeRestart fallback current=\(current) -> reselect attempt=\(attempt)")
            forceChineseInput { _ in
                confirmChinese(attempt: attempt + 1, front: front, killed: killed, completion: completion)
            }
        }
    }

    private static func finishRestart(killed: Bool, front: String, fellBack: Bool,
                                      completion: ((String) -> Void)?) {
        let line = "imeRestart killed=\(killed ? 1 : 0) fallback=\(fellBack ? 1 : 0) now=\(currentSnapshot()) front=\(front)"
        Log.info(line)
        nudge(front: front, prefix: "imeRestart") { result in
            completion?(result == "noop" ? line : "\(line) nudge=\(result)")
        }
    }

    /// 对「切源后输入上下文不跟」的 App（配置 imeNudgeApps）做一次焦点往返
    private static func nudge(front: String, prefix: String, completion: @escaping (String) -> Void) {
        guard Config.shared.imeNudgeApps.contains(front) else {
            completion("noop")
            return
        }
        AppFocus.bounce(bundleID: front) { result in
            Log.info("\(prefix) nudge app=\(front) \(result)")
            completion(result)
        }
    }

    private static func imePID() -> pid_t? {
        guard let out = run("/usr/bin/pgrep", ["-f", "/Input Methods/SCIM.app/"])?.output, !out.isEmpty else {
            return nil
        }
        return out.split(separator: "\n").first.flatMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 跑一个外部命令，返回退出码 + stdout。用来取 IME 进程现场和发信号。
    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Log.warn("imeRestart spawn failed path=\(path) reason=\(error.localizedDescription)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
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

    /// 诊断用：把属性值转成人能读的字符串。
    /// 旧的 `"\($0)"` 打的是 CFTypeRef 指针地址（`0x00000078c4b9cd00`），等于没打。
    private static func propertyString(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        let object = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
        if CFGetTypeID(object) == CFStringGetTypeID() {
            return (object as! CFString) as String
        }
        if CFGetTypeID(object) == CFBooleanGetTypeID() {
            return (object as! CFBoolean) == kCFBooleanTrue ? "1" : "0"
        }
        return nil
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
