import Foundation
import AppKit
import ApplicationServices
import Carbon

/// 辅助功能（Accessibility）入口：权限、焦点、以及给探针用的统一读取原语。
///
/// 本文件只放核心与焦点；选区在 AXSelection.swift，窗口在 AXWindow.swift，
/// 属性读取原语在 AXAttribute.swift。三者都是 `extension AX`，对外仍是同一个命名空间。
enum AX {
    static func requestPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var isTrusted: Bool {
        return AXIsProcessTrusted()
    }

    static func focusedApplication() -> AXUIElement? {
        return elementAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString)
    }

    static func focusedWindow() -> AXUIElement? {
        guard let app = focusedApplication() else { return nil }
        return elementAttribute(app, kAXFocusedWindowAttribute as CFString)
    }

    static func focusedElement() -> AXUIElement? {
        guard let app = focusedApplication() else { return nil }
        return elementAttribute(app, kAXFocusedUIElementAttribute as CFString)
            ?? elementAttribute(app, kAXFocusedWindowAttribute as CFString)
    }

    /// Electron/Chromium（VS Code、Chrome、Slack…）默认不建辅助功能树，
    /// 要先把这个属性置真，之后焦点元素才会出现。每个 pid 只设一次。
    static var manualA11yEnabled: Set<pid_t> = []

    static func ensureManualAccessibility(_ app: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        guard pid > 0, !manualA11yEnabled.contains(pid) else { return }
        let status = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if status == .success {
            manualA11yEnabled.insert(pid)
            Log.info("ax manual-accessibility enabled pid=\(pid)")
        }
    }

    static func report(_ error: AXError) {
        if error == .apiDisabled {
            Log.warn("axDenied")
        } else {
            Log.warn("ax error=\(error.rawValue)")
        }
    }
}
