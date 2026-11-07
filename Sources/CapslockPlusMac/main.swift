import Foundation
import AppKit
import AVFoundation

final class PanelSelfTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let entry = DictEntry(source: "oalecd9", headword: "hello", phonetic: "həˈləʊ",
                              body: "verb\t打招呼\nnoun\t你好", audioBre: nil, audioAme: nil)
        TranslatePanel.shared.show(entry: entry, audio: nil)
        let firstOrigin = TranslatePanel.shared.debugOrigin
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // 模拟"结果回来再渲染一次"：位置必须原地不动
            let longer = DictEntry(source: "oalecd9", headword: "hello", phonetic: "həˈləʊ",
                                   body: "verb\t打招呼\nnoun\t你好\nnoun\t喂\n例\thello there 你好呀", audioBre: nil, audioAme: nil)
            TranslatePanel.shared.show(entry: longer, audio: nil)
            let secondOrigin = TranslatePanel.shared.debugOrigin
            print("origin1=\(firstOrigin) origin2=\(secondOrigin)")
            let expected = "verb  打招呼\nnoun  你好\nnoun  喂\n例  hello there 你好呀"
            let report = TranslatePanel.shared.debugSelectAllBody()
            print("expected=\(expected.debugDescription)")
            print(report)
            let picked = TranslatePanel.shared.selectionText
            let stable = abs(firstOrigin.x - secondOrigin.x) < 0.5 && abs(firstOrigin.y - secondOrigin.y) < 0.5
            print("stable=\(stable ? 1 : 0)")
            exit((picked == expected && stable) ? 0 : 1)
        }
    }
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

if CommandLine.arguments.contains("--panel-selftest") {
    let delegate = PanelSelfTestDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
    exit(1)
}

if let index = CommandLine.arguments.firstIndex(of: "--audio-test"),
   index + 1 < CommandLine.arguments.count {
    let relative = CommandLine.arguments[index + 1]
    let file = (AudioPlayer.audioRoot as NSString).appendingPathComponent(relative)
    do {
        let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: file))
        print("ok duration=\(String(format: "%.2f", player.duration))s file=\(relative)")
        exit(0)
    } catch {
        print("FAILED: \(error.localizedDescription) file=\(relative)")
        exit(1)
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
    exit(entries.isEmpty ? 1 : 0)
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
    exit(0)
}

if CommandLine.arguments.contains("--tiling-selftest") {
    exit(runTilingSelfTest())
}

if CommandLine.arguments.contains("--probe-tiling") {
    print("ax_trusted=\(AX.isTrusted ? 1 : 0) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
    for line in WindowActions.describeTiling() {
        print(line)
    }
    exit(0)
}

if CommandLine.arguments.contains("--transform-selftest") {
    exit(runTransformSelfTest())
}

if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest())
}

if CommandLine.arguments.contains("--login-item-enable") {
    let ok = LoginItem.enable()
    print("login-item-enable \(ok ? "ok" : "fail")")
    exit(ok ? 0 : 1)
}

if CommandLine.arguments.contains("--login-item-disable") {
    let ok = LoginItem.disable()
    print("login-item-disable \(ok ? "ok" : "fail")")
    exit(ok ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// 单实例保护：两个进程各自建 event tap、各自切输入法，会表现为"长按切了输入法但不生效"
// （每次按键被处理两次，输入源被切换两轮，正好回到原点）
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !others.isEmpty {
        let pids = others.map { String($0.processIdentifier) }.joined(separator: ",")
        Log.warn("instance duplicate exit existing=\(pids)")
        exit(0)
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
