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

    /// 杀掉输入法进程再重选中文源——「输入源是中文、caps 是关的，但打出来还是英文」的复位手段。
    ///
    /// 实测取证：故障时 `imeDiagnose` 显示 `current=com.apple.inputmethod.SCIM.ITABC (简体拼音) caps=0`、
    /// ABC `selected=0`，也就是说 TIS 层面完全正常；卡住的是苹果拼音 IME 进程内部的中/英状态。
    /// 这个状态在 TIS 里没有对应的输入模式可选中（全量枚举 331 个输入源，SCIM 只暴露 Pinyin 一个
    /// keyboard input mode，没有 English 变体），也没有公开 API 读写；重选同源、切到 ABC 再切回来都不清它。
    /// 唯一确定的复位是重建 IME 进程：imklaunchagent 会在下一次按键时拉起一个干净实例，中/英回到中文。
    /// 必须 SIGKILL：实测 `pkill -f`（SIGTERM）返回 0、进程却活着（pid 不变），IME 自己拦了 SIGTERM。
    /// 代价：正在进行的拼音组合会丢，重建那一下约 1 秒没有输入法。
    static func restartIMEServer(reason: String = "menu", completion: ((String) -> Void)? = nil) {
        // 先留证据：故障是偶发的，等它下次发生，这段现场就是唯一的线索
        let before = run("/usr/bin/pgrep", ["-fl", "Input Methods/SCIM"]).map { $0.output.isEmpty ? "(not-running)" : $0.output } ?? "(spawn-failed)"
        Log.info("imeRestart begin reason=\(reason) caps=\(HIDCapsLock.shared.isLocked ? 1 : 0) current=\(currentSnapshot()) ime=\(before.replacingOccurrences(of: "\n", with: " | "))")
        // 把完整现场（全部输入源的 selected/enabled + 前台 App）落进日志：
        // 故障分两种形态——切源没落地 vs 源是中文但 IME 内部卡英文——这份 dump 是唯一的区分依据
        for line in diagnose().split(separator: "\n") {
            Log.info("imeRestart dump | \(line)")
        }

        let killed = (run("/usr/bin/pkill", ["-9", "-f", "/Input Methods/SCIM.app/"])?.status ?? -1) == 0
        Log.info("imeRestart pkill killed=\(killed ? 1 : 0)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            forceChineseInput { result in
                let line = "imeRestart killed=\(killed ? 1 : 0) \(result) now=\(currentSnapshot())"
                Log.info(line)
                completion?(line)
            }
        }
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
