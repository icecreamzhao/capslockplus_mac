import Foundation
import AppKit
import AVFoundation

// 所有 --flag 子命令都在 DebugCLI 里处理并返回退出码；返回 nil 才继续启动 App。
if let code = DebugCLI.run() {
    exit(code)
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
