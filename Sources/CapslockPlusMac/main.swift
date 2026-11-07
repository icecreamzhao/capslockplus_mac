import Foundation
import AppKit

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
