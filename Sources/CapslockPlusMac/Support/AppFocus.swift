import AppKit

/// 前台 App 的焦点操作。
///
/// 为什么需要它：`TISSelectInputSource` 只改全局输入源，不保证前台 App 的 `NSTextInputContext`
/// 跟着换。实测（Terminal.app）：TIS 已经是「简体拼音」、iPhone Mirroring 里也有候选框，
/// 唯独 Terminal 窗口仍然按 ABC 收字符，没有任何候选窗；切到别的 App 打几个字再切回来才恢复。
/// 这类 App 需要一个"重新激活窗口"的动作，让 AppKit 重建输入上下文。
enum AppFocus {
    static func frontBundleID() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    }

    /// 焦点往返：先激活 Finder 再切回目标 App，等价于用户手工"切走再切回来"。
    /// 目标 App 有全屏窗口时跳过——激活别的 App 会把整个 Space 切走，代价太大。
    static func bounce(bundleID: String, gapMs: Int = 180, completion: ((String) -> Void)? = nil) {
        guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            completion?("skip=not-running")
            return
        }
        if hasFullscreenWindow(pid: target.processIdentifier) {
            completion?("skip=fullscreen")
            return
        }
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            completion?("skip=no-finder")
            return
        }

        let activatedOut = finder.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(gapMs)) {
            let back = target.activate(options: [])
            completion?("bounce out=\(activatedOut ? 1 : 0) back=\(back ? 1 : 0) gapMs=\(gapMs)")
        }
    }

    private static func hasFullscreenWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = AX.elementArrayAttribute(app, kAXWindowsAttribute as CFString) else { return false }
        for window in windows {
            if let raw = AX.copyAttribute(window, "AXFullScreen" as CFString).value,
               CFGetTypeID(raw) == CFBooleanGetTypeID(),
               (raw as! CFBoolean) == kCFBooleanTrue {
                return true
            }
        }
        return false
    }
}
