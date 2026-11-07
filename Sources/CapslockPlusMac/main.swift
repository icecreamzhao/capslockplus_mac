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
        ("cjk2ascii", "Hello， world！", "Hello, world!")
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

    if TextTransform.kinds.contains(where: { TextTransform.apply($0, to: "x") == nil }) {
        print("FAIL: kinds 里有 apply 不认识的项")
        failures += 1
    }

    if failures == 0 {
        print("transform selftest OK (\(cases.count) cases, \(TextTransform.kinds.count) kinds)")
        return 0
    }
    print("transform selftest FAILED: \(failures)")
    return 1
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
