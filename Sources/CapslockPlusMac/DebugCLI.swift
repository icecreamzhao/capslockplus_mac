import Foundation
import AppKit
import AVFoundation


/// 命令行入口：所有 --flag 子命令（自检、AX 探针、字典/音频/翻译测试、面板测试）。
/// `run()` 返回 nil 表示"不是子命令"，main.swift 继续启动 App。
enum DebugCLI {
    static func run() -> Int32? {
        if let index = CommandLine.arguments.firstIndex(of: "--ax-selectall"),
           index + 1 < CommandLine.arguments.count {
            return runSelectAllProbe(bundleID: CommandLine.arguments[index + 1])
        }

        if CommandLine.arguments.contains("--input-source-list") {
            print("current=", InputSource.currentSnapshot(), "caps=", HIDCapsLock.shared.isLocked ? 1 : 0)
            for (index, source) in InputSource.selectableSources().enumerated() {
                print(String(format: "%2d  %@  %@", index, InputSource.debugID(source) ?? "?", InputSource.debugName(source) ?? "?"))
            }
            return 0
        }

        if CommandLine.arguments.contains("--ime-diagnose") {
            print(InputSource.diagnose())
            return 0
        }

        if CommandLine.arguments.contains("--ime-reset") {
            // 杀掉 IME 进程再重选中文源。回调走 DispatchQueue.main，所以这里要泵主 run loop，
            // 用信号量阻塞主线程会让 asyncAfter 永远不触发（只有超时）。
            var output: String?
            InputSource.restartIMEServer(reason: "cli") { line in output = line }
            let deadline = Date().addingTimeInterval(4)
            while output == nil && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            guard let line = output else {
                print("imeReset timeout")
                return 2
            }
            print("imeReset \(line)")
            return 0
        }

        if CommandLine.arguments.contains("--clipboard-selftest") {
            return Clipboard.selftest() ? 0 : 1
        }

        if let index = CommandLine.arguments.firstIndex(of: "--clipboard-probe"),
           index + 1 < CommandLine.arguments.count {
            let bundleID = CommandLine.arguments[index + 1]
            var lines: [String] = []
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate(options: [])
                usleep(400_000)
                let text = Clipboard.copySelection()
                lines.append("app=\(bundleID) len=\(text?.count ?? -1) head=\((text ?? "nil").prefix(30))")
            } else {
                lines.append("app not running: \(bundleID)")
            }
            try? lines.joined(separator: "\n").write(toFile: "/tmp/clipprobe.txt", atomically: true, encoding: .utf8)
            return 0
        }

        if CommandLine.arguments.contains("--ax-matrix") || CommandLine.arguments.contains("--clipboard-probe") || CommandLine.arguments.contains("--clipboard-selftest") {
            return runAXMatrixProbe()
        }

        if let index = CommandLine.arguments.firstIndex(of: "--ax-light"),
           index + 1 < CommandLine.arguments.count {
            return runAXLightProbe(bundleID: CommandLine.arguments[index + 1])
        }

        if let index = CommandLine.arguments.firstIndex(of: "--ax-probe"),
           index + 1 < CommandLine.arguments.count {
            return runAXProbe(bundleID: CommandLine.arguments[index + 1])
        }


        if CommandLine.arguments.contains("--panel-clamp-selftest") {
            let delegate = PanelClampSelfTestDelegate()
            NSApplication.shared.delegate = delegate
            NSApplication.shared.run()
            return 1
        }

        if CommandLine.arguments.contains("--panel-html-selftest") {
            let delegate = PanelHTMLSelfTestDelegate()
            NSApplication.shared.delegate = delegate
            NSApplication.shared.run()
            return 1
        }

        if CommandLine.arguments.contains("--panel-selftest") {
            let delegate = PanelSelfTestDelegate()
            NSApplication.shared.delegate = delegate
            NSApplication.shared.run()
            return 1
        }

        if let index = CommandLine.arguments.firstIndex(of: "--audio-test"),
           index + 1 < CommandLine.arguments.count {
            let relative = CommandLine.arguments[index + 1]
            let file = (AudioPlayer.audioRoot as NSString).appendingPathComponent(relative)
            do {
                let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: file))
                print("ok duration=\(String(format: "%.2f", player.duration))s file=\(relative)")
                return 0
            } catch {
                print("FAILED: \(error.localizedDescription) file=\(relative)")
                return 1
            }
        }

        if let index = CommandLine.arguments.firstIndex(of: "--dict-test"),
           index + 1 < CommandLine.arguments.count {
            let query = CommandLine.arguments[index + 1]
            let entries = OfflineDictionary.shared.lookup(query)
            print("candidates=\(OfflineDictionary.candidates(for: query))")
            print("hits=\(entries.count)")
            for entry in entries {
                print("[\(entry.source)] \(entry.headword) /\(entry.phonetic ?? "-")/ audio=\(entry.audioPath ?? "-")")
                for line in entry.lines.prefix(10) {
                    print("   ", line)
                }
            }
            return entries.isEmpty ? 1 : 0
        }

        if let index = CommandLine.arguments.firstIndex(of: "--translate-test"),
           index + 1 < CommandLine.arguments.count {
            let query = CommandLine.arguments[index + 1]
            let semaphore = DispatchSemaphore(value: 0)
            TranslateService.fetchRaw(query) { translation, message in
                if let translation = translation {
                    print("query=\(translation.query)")
                    print("phonetic=\(translation.phonetic ?? "-")")
                    print("lines=\(translation.lines.count) web=\(translation.webLines.count)")
                    print(translation.displayText)
                } else {
                    print("FAILED: \(message ?? "unknown")")
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 15)
            return 0
        }

        if CommandLine.arguments.contains("--tiling-selftest") {
            return runTilingSelfTest()
        }

        if CommandLine.arguments.contains("--probe-tiling") {
            print("ax_trusted=\(AX.isTrusted ? 1 : 0) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
            for line in WindowActions.describeTiling() {
                print(line)
            }
            return 0
        }

        if CommandLine.arguments.contains("--transform-selftest") {
            return runTransformSelfTest()
        }

        if CommandLine.arguments.contains("--selftest") {
            return runSelfTest()
        }

        if CommandLine.arguments.contains("--login-item-enable") {
            let ok = LoginItem.enable()
            print("login-item-enable \(ok ? "ok" : "fail")")
            return ok ? 0 : 1
        }

        if CommandLine.arguments.contains("--login-item-disable") {
            let ok = LoginItem.disable()
            print("login-item-disable \(ok ? "ok" : "fail")")
            return ok ? 0 : 1
        }


        return nil
    }
}

final class PanelSelfTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let entry = DictEntry(source: "oalecd9", headword: "hello", phonetic: "həˈləʊ",
                              body: "verb\t打招呼\nnoun\t你好", audioBre: nil, audioAme: nil, html: nil)
        TranslatePanel.shared.show(entry: entry, audio: nil)
        let firstOrigin = TranslatePanel.shared.debugOrigin
        let firstTop = TranslatePanel.shared.debugTop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // 模拟"结果回来再渲染一次"：位置必须原地不动
            let longer = DictEntry(source: "oalecd9", headword: "hello", phonetic: "həˈləʊ",
                                   body: "verb\t打招呼\nnoun\t你好\nnoun\t喂\n例\thello there 你好呀", audioBre: nil, audioAme: nil, html: nil)
            TranslatePanel.shared.show(entry: longer, audio: nil)
            let secondOrigin = TranslatePanel.shared.debugOrigin
            let secondTop = TranslatePanel.shared.debugTop
            print("origin1=\(firstOrigin) origin2=\(secondOrigin) top1=\(firstTop) top2=\(secondTop)")
            print("appActive=\(NSApp.isActive ? 1 : 0) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") panelKey=\(TranslatePanel.shared.isKeyWindow ? 1 : 0)")
            let expected = "verb  打招呼\nnoun  你好\nnoun  喂\n例  hello there 你好呀"
            let report = TranslatePanel.shared.debugSelectAllBody()
            print("expected=\(expected.debugDescription)")
            print(report)
            let picked = TranslatePanel.shared.selectionText
            // 顶边和横坐标不动即可：内容变长应该向下长，底部 origin.y 变化是正常的
            let stable = abs(firstOrigin.x - secondOrigin.x) < 0.5 && abs(firstTop - secondTop) < 0.5
            print("stable=\(stable ? 1 : 0)")

            // 关掉浮层后必须把 App 激活状态还回去，否则目标 App 会把 AX 选区清空
            TranslatePanel.shared.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let active = NSApp.isActive ? 1 : 0
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
                print("afterDismiss active=\(active) frontmost=\(front)")
                let restored = active == 0
                exit((picked == expected && stable && restored) ? 0 : 1)
            }
        }
    }
}


final class PanelHTMLSelfTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let query = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "hello"
        let wantedSource = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
        let entries = OfflineDictionary.shared.lookup(query)
        guard let entry = entries.first(where: { $0.html != nil && (wantedSource == nil || $0.source == wantedSource) }) else {
            print("FAIL no html entry (hits=\(entries.count))")
            exit(1)
        }
        print("entry=\(entry.source) htmlLen=\(entry.html?.count ?? 0) assets=\(DictEntry.assetsDirectory(for: entry.source))")
        TranslatePanel.shared.show(entry: entry, audio: entry.audioPath)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            print(TranslatePanel.shared.debugSelectAllWeb())
            let picked = TranslatePanel.shared.selectionText ?? ""
            TranslatePanel.shared.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                print("afterDismiss active=\(NSApp.isActive ? 1 : 0) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
                exit(picked.isEmpty ? 1 : 0)
            }
        }
    }
}

/// 只看焦点元素，不递归——给会卡死客户端的浏览器（Firefox）用
/// 给前台 App 发一次 Cmd+A 造出选区，再读 AX——用来分辨"浏览器不暴露选区"还是"当时没选区"
func runSelectAllProbe(bundleID: String) -> Int32 {
    var lines: [String] = []
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        try? "app not running".write(toFile: "/tmp/axselectall.txt", atomically: true, encoding: .utf8)
        return 2
    }
    app.activate(options: [])
    usleep(300_000)
    if let source = CGEventSource(stateID: .combinedSessionState),
       let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
       let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
    usleep(600_000)
    lines.append("trusted=\(AXIsProcessTrusted() ? 1 : 0)")
    let direct = AX.selectedText(forPID: app.processIdentifier)
    lines.append("directLen=\(direct?.count ?? -1)")
    let deep = AX.selectedTextDeep(forPID: app.processIdentifier)
    lines.append("deepLen=\(deep?.count ?? -1)")
    lines.append("deepHead=\((deep ?? "nil").prefix(40))")
    try? lines.joined(separator: "\n").write(toFile: "/tmp/axselectall.txt", atomically: true, encoding: .utf8)
    return 0
}

/// 扫一遍当前前台 App 集合，报告每个 App 的选区可读性（不需要事先有选区，看属性是否存在）
func runAXMatrixProbe() -> Int32 {
    let outPath = "/tmp/axmatrix.txt"
    var lines: [String] = []
    func flush() { try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8) }
    let selfPID = ProcessInfo.processInfo.processIdentifier
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
        .sorted { ($0.bundleIdentifier ?? "") < ($1.bundleIdentifier ?? "") }

    lines.append("bundle\tmanual\trole\tselectedText\tmarker\tvalueLen")
    flush()
    for app in apps {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let manual = AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        usleep(250_000)

        var role = "-", hasText = "-", hasMarker = "-", valueLen = "-"
        if let element = AX.elementAttribute(ax, kAXFocusedUIElementAttribute as CFString) {
            let list = AX.attributeNames(of: element)
            role = AX.stringAttribute(element, kAXRoleAttribute as CFString) ?? "-"
            hasText = list.contains(kAXSelectedTextAttribute as String) ? "yes" : "no"
            hasMarker = list.contains("AXSelectedTextMarkerRange") ? "yes" : "no"
            if let text = AX.copyAttribute(element, kAXSelectedTextAttribute as CFString).value as? String {
                valueLen = String(text.count)
            }
        } else {
            role = "no-focused"
        }
        lines.append("\(app.bundleIdentifier ?? "?")\t\(manual.rawValue)\t\(role)\t\(hasText)\t\(hasMarker)\t\(valueLen)")
        flush()
    }
    return 0
}

func runAXLightProbe(bundleID: String) -> Int32 {
    var lines: [String] = []
    let outPath = "/tmp/axlight.txt"
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        try? "app not running".write(toFile: outPath, atomically: true, encoding: .utf8)
        return 2
    }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    lines.append("manualA11y=\(AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue)")
    lines.append("enhancedUI=\(AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)")
    let front = NSWorkspace.shared.frontmostApplication
    lines.append("front=\(front?.bundleIdentifier ?? "?") frontpid=\(front?.processIdentifier ?? 0) targetpid=\(app.processIdentifier)")
    usleep(700_000)   // Chromium 建树是异步的，设完属性马上读会拿到 -25212
    let focused = AX.copyAttribute(ax, kAXFocusedUIElementAttribute as CFString)
    lines.append("focusedErr=\(focused.status.rawValue)")
    if let raw = focused.value, CFGetTypeID(raw) == AXUIElementGetTypeID() {
        let element = raw as! AXUIElement
        lines.append("attrs=\(AX.attributeNames(of: element))")
        let selected = AX.copyAttribute(element, kAXSelectedTextAttribute as CFString)
        lines.append("AXSelectedText err=\(selected.status.rawValue) value=\((selected.value as? String) ?? "-")")
        let marker = AX.copyAttribute(element, "AXSelectedTextMarkerRange" as CFString)
        lines.append("markerRange err=\(marker.status.rawValue)")
        if marker.status == .success, let parameter = marker.value {
            let text = AX.copyParameterized(element, "AXStringForTextMarkerRange" as CFString, parameter)
            lines.append("markerText err=\(text.status.rawValue) value=\((text.value as? String) ?? "-")")
        }
    }
    lines.append("reader=\(AX.selectedText(forPID: app.processIdentifier) ?? "nil")")
    try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    return 0
}

func runAXProbe(bundleID: String) -> Int32 {
    var lines: [String] = []
    let outPath = "/tmp/axprobe.txt"
    func flush() {
        try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }
    lines.append("started pid=\(ProcessInfo.processInfo.processIdentifier) target=\(bundleID)")
    flush()
    lines.append("trusted=\(AXIsProcessTrusted() ? 1 : 0)")
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        lines.append("app not running")
        try? lines.joined(separator: "\n").write(toFile: "/tmp/axprobe.txt", atomically: true, encoding: .utf8)
        return 2
    }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    lines.append("enhancedUI=\(AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)")
    lines.append("manualA11y=\(AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue)")

    // 不依赖焦点：把 Safari 的窗口树走一遍，找任何带选区的元素
    var scanned = 0
    var hits: [String] = []
    func walk(_ el: AXUIElement, _ depth: Int) {
        guard scanned < 2000, depth <= 8 else { return }
        scanned += 1
        let role = AX.stringAttribute(el, kAXRoleAttribute as CFString) ?? "?"
        if role == "AXWebArea" || role == "AXStaticText" || role == "AXTextField" || role == "AXTextArea" {
            let selected = AX.copyAttribute(el, kAXSelectedTextAttribute as CFString)
            let text = (selected.value as? String) ?? ""
            var markerInfo = ""
            let marker = AX.copyAttribute(el, "AXSelectedTextMarkerRange" as CFString)
            if marker.status == .success, let parameter = marker.value {
                let text = AX.copyParameterized(el, "AXStringForTextMarkerRange" as CFString, parameter)
                markerInfo = " markerStatus=\(text.status.rawValue) markerText=\((text.value as? String) ?? "-")"
            } else {
                markerInfo = " marker=none"
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hits.append("HIT role=\(role) selected=\(text.prefix(40))")
            } else if role == "AXWebArea" {
                hits.append("WEBAREA empty selErr=\(selected.status.rawValue)\(markerInfo) attrs=\(AX.attributeNames(of: el))")
            }
        }
        for child in AX.elementArrayAttribute(el, kAXChildrenAttribute as CFString) ?? [] {
            walk(child, depth + 1)
        }
    }
    for window in AX.elementArrayAttribute(ax, kAXWindowsAttribute as CFString) ?? [] {
        let title = AX.stringAttribute(window, kAXTitleAttribute as CFString) ?? "-"
        lines.append("window: \(title)")
        flush()
        walk(window, 0)
        flush()
    }
    lines.append("scanned=\(scanned)")
    let readerResult = AX.selectedTextDeep(forPID: app.processIdentifier)
    lines.append("readerResult=\(readerResult ?? "nil")")
    flush()
    lines.append(contentsOf: hits.prefix(6))
    try? lines.joined(separator: "\n").write(toFile: "/tmp/axprobe.txt", atomically: true, encoding: .utf8)
    return 0
}

func runSelfTest() -> Int32 {
    var failures: [String] = []
    var seen = Set<KeyCombo>()

    for (chordText, actionText) in Config.defaultPairs {
        guard let combo = ChordParser.parse(chordText) else {
            failures.append("bad chord \(chordText)")
            continue
        }
        if !seen.insert(combo).inserted {
            failures.append("duplicate chord \(chordText)")
        }
        if Action.parse(actionText) == nil {
            failures.append("unknown action \(actionText)")
        }
    }
    if TapAction(rawValue: "toggleCapsLock") == nil {
        failures.append("unknown tap action")
    }

    // 往返自检：动作的 name 必须能被 parse 回同一个动作。
    // 这条是防"新增动作时忘了同步 name 或解析表"——两处手工映射，漏一处编译照样过。
    for (key, action) in Action.fixedTable {
        guard let roundTrip = Action.parse(action.name) else {
            failures.append("name not parseable key=\(key) name=\(action.name)")
            continue
        }
        if roundTrip != action {
            failures.append("name drift key=\(key) name=\(action.name) -> \(roundTrip.name)")
        }
    }

    if failures.isEmpty {
        print("selftest OK (\(seen.count) bindings)")
        return 0
    }
    for failure in failures {
        FileHandle.standardError.write(Data("selftest FAILED: \(failure)\n".utf8))
    }
    return 1
}

func runTransformSelfTest() -> Int32 {
    let cases: [(String, String, String)] = [
        ("upper", "Hello world", "HELLO WORLD"),
        ("lower", "Hello World", "hello world"),
        ("title", "hello world", "Hello World"),
        ("camel", "user profile name", "userProfileName"),
        ("camel", "user_profile_name", "userProfileName"),
        ("camel", "userProfileID", "userProfileId"),
        ("pascal", "user-profile name", "UserProfileName"),
        ("snake", "userProfileName", "user_profile_name"),
        ("kebab", "userProfileName", "user-profile-name"),
        ("constant", "userProfileName", "USER_PROFILE_NAME"),
        ("sort", "b\na\nc", "a\nb\nc"),
        ("sortdesc", "a\nc\nb", "c\nb\na"),
        ("unique", "a\na\nb", "a\nb"),
        ("reverse", "a\nb\nc", "c\nb\na"),
        ("trim", "  a  \n  b  ", "a\nb"),
        ("jsonmin", "{\"a\": 1, \"b\": [2, 3]}", "{\"a\":1,\"b\":[2,3]}"),
        ("urlencode", "a b&c", "a%20b%26c"),
        ("urldecode", "a%20b", "a b"),
        ("ascii2cjk", "Hello, world! (yes)", "Hello， world！ （yes）"),
        ("cjk2ascii", "Hello， world！", "Hello, world!"),
        ("punctoggle", "Hello, world!", "Hello， world！"),
        ("punctoggle", "Hello， world！", "Hello, world!"),
        ("punctoggle", "他说：\"好的\"", "他说:\"好的\"")
    ]

    var failures = 0
    for (kind, input, expected) in cases {
        guard let output = TextTransform.apply(kind, to: input) else {
            print("FAIL \(kind): nil (unknown kind)")
            failures += 1
            continue
        }
        if output != expected {
            print("FAIL \(kind): got \(output.debugDescription) want \(expected.debugDescription)")
            failures += 1
        }
    }

    // json 类对非法输入返回 nil 是预期行为，所以只校验"未知 kind 必须被拒绝"
    if TextTransform.apply("nosuchkind", to: "x") != nil {
        print("FAIL: 未知 kind 没有被拒绝")
        failures += 1
    }

    if failures == 0 {
        print("transform selftest OK (\(cases.count) cases, \(TextTransform.kinds.count) kinds)")
        return 0
    }
    print("transform selftest FAILED: \(failures)")
    return 1
}

func runTilingSelfTest() -> Int32 {
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let window = CGRect(x: 100, y: 100, width: 400, height: 300)
    let cases: [(String, CGRect)] = [
        ("left", CGRect(x: 0, y: 0, width: 500, height: 800)),
        ("right", CGRect(x: 500, y: 0, width: 500, height: 800)),
        ("top", CGRect(x: 0, y: 0, width: 1000, height: 400)),
        ("bottom", CGRect(x: 0, y: 400, width: 1000, height: 400)),
        ("maximize", CGRect(x: 0, y: 0, width: 1000, height: 800)),
        ("center", CGRect(x: 300, y: 250, width: 400, height: 300))
    ]
    var failures = 0
    for (kind, expected) in cases {
        guard let got = WindowActions.targetRect(kind: kind, windowFrame: window, visible: visible) else {
            print("FAIL \(kind): nil")
            failures += 1
            continue
        }
        if got != expected {
            print("FAIL \(kind): got \(got) want \(expected)")
            failures += 1
        }
    }
    // 奇数宽度不能出现缝或重叠
    let odd = CGRect(x: 0, y: 0, width: 1001, height: 801)
    if let l = WindowActions.targetRect(kind: "left", windowFrame: window, visible: odd),
       let r = WindowActions.targetRect(kind: "right", windowFrame: window, visible: odd) {
        if l.maxX != r.minX || r.maxX != odd.maxX || l.width + r.width != odd.width {
            print("FAIL odd width seam: left=\(l) right=\(r) visible=\(odd)")
            failures += 1
        }
    } else {
        print("FAIL odd width: nil")
        failures += 1
    }
    if WindowActions.targetRect(kind: "diagonal", windowFrame: window, visible: visible) != nil {
        print("FAIL: 未知 kind 没有被拒绝")
        failures += 1
    }

    if failures == 0 {
        print("tiling selftest OK (\(cases.count) cases + odd width + unknown kind)")
        return 0
    }
    print("tiling selftest FAILED: \(failures)")
    return 1
}

final class PanelClampSelfTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let entry = DictEntry(source: "oalecd9", headword: "hello", phonetic: "həˈləʊ",
                              body: "verb\t打招呼\nnoun\t你好", audioBre: nil, audioAme: nil, html: nil)
        TranslatePanel.shared.show(entry: entry, audio: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let result = TranslatePanel.shared.debugForceOffscreenAndClamp() else {
                print("FAIL no screen")
                exit(1)
            }
            let inside = result.after.minY >= result.visible.minY - 0.5
                && result.after.maxY <= result.visible.maxY + 0.5
                && result.after.maxX <= result.visible.maxX + 0.5
                && result.after.minX >= result.visible.minX - 0.5
            print("before=\(result.before) after=\(result.after) visible=\(result.visible) inside=\(inside ? 1 : 0)")
            TranslatePanel.shared.dismiss()
            exit(inside ? 0 : 1)
        }
    }
}
