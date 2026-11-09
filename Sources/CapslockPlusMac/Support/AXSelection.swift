import Foundation
import AppKit
import ApplicationServices
import Carbon

/// AX 选区：读（AXSelectedText → marker → range 三条路径 + 重试）与写（AX 写回、剪贴板兜底）。
extension AX {
    /// 读不到就深挖：遍历该 App 的窗口树，找第一个真的有选区的文本控件。
    /// 有些 App（实测 Terminal）在窗口不是 key 时会对外报空选区，但选区其实还在。
    static func selectedTextDeep() -> String? {
        if let text = selectedText() { return text }

        // AX 的「系统级焦点 App」会滞后（浮层关掉、快速切换时读到上一个 App）。
        // 用 NSWorkspace 的前台 App 兜一次，两者不同才重试。
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let frontApp = NSWorkspace.shared.frontmostApplication?.processIdentifier as pid_t? {
            var axPid: pid_t = 0
            if let app = focusedApplication() {
                AXUIElementGetPid(app, &axPid)
            }
            if axPid != frontApp {
                Log.warn("axSelection front-differs axpid=\(axPid) frontpid=\(frontApp) front=\(front.bundleIdentifier ?? "?") -> retry front")
                let element = AXUIElementCreateApplication(frontApp)
                if let raw = elementAttribute(element, kAXFocusedUIElementAttribute as CFString),
                   let text = readSelection(raw),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }

        guard let app = focusedApplication() else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return deepScan(inApp: app)
    }

    /// 遍历某个 App 的窗口树找选区（Safari 的 AXWebArea 常常只有 marker 范围里有文本）。
    static func deepScan(inApp app: AXUIElement) -> String? {
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)

        let front = NSWorkspace.shared.frontmostApplication
        Log.warn("axSelection deep start apppid=\(pid) appActive=\(NSApp.isActive ? 1 : 0) panelShown=\(TranslatePanel.shared.isShowing ? 1 : 0) front=\(front?.bundleIdentifier ?? "?") frontpid=\(front?.processIdentifier ?? 0)")
        var visited = 0
        var found: String?
        let deadline = Date().addingTimeInterval(0.40)   // 主线程上跑，必须有时间预算

        // 广度优先：Safari/Firefox 的 AXWebArea 都在窗口的直接子层，
        // 深度优先会一头扎进第一个子树（几千个节点）里出不来。
        var queue: [(AXUIElement, Int)] = []
        if let focused = elementAttribute(app, kAXFocusedUIElementAttribute as CFString) {
            queue.append((focused, 0))
        }
        if let window = elementAttribute(app, kAXFocusedWindowAttribute as CFString) {
            queue.append((window, 0))
        }
        for window in elementArrayAttribute(app, kAXWindowsAttribute as CFString) ?? [] {
            queue.append((window, 0))
        }

        var index = 0
        while index < queue.count, found == nil, visited < 1500, Date() < deadline {
            let (element, depth) = queue[index]
            index += 1
            visited += 1

            let selection = copyAttribute(element, kAXSelectedTextAttribute as CFString)
            if let raw = selection.value as? String, selection.status == .success {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    found = trimmed
                    break
                }
            }
            if let viaMarker = selectionViaMarker(element) {
                found = viaMarker
                break
            }
            guard depth < 8, let children = childrenAttribute(element) else { continue }
            for child in children {
                queue.append((child, depth + 1))
            }
        }

        if let text = found {
            Log.info("axSelection deep hit apppid=\(pid) scanned=\(visited) len=\(text.count)")
        } else {
            Log.warn("axSelection deep miss apppid=\(pid) scanned=\(visited)")
        }
        return found
    }

    /// WebKit(Safari/Electron) 专用：AXSelectedText 返回 -25212 时，
    /// 用 AXSelectedTextMarkerRange + AXStringForTextMarkerRange 取选区（实测有效）。
    static func selectionViaMarker(_ element: AXUIElement) -> String? {
        let markerAttribute = copyAttribute(element, "AXSelectedTextMarkerRange" as CFString)
        guard markerAttribute.status == .success, let marker = markerAttribute.value else { return nil }
        var text: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            marker,
            &text
        )
        guard status == .success, let string = text as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        Log.info("axSelection via-marker len=\(trimmed.count)")
        return trimmed
    }

    /// 用「选区范围 + 按范围取文本」兜底，Safari/WebKit 走这条路能拿到选中的字。
    static func selectionViaRange(_ element: AXUIElement) -> String? {
        let rangeAttribute = copyAttribute(element, kAXSelectedTextRangeAttribute as CFString)
        guard rangeAttribute.status == .success,
              let value = rangeAttribute.value, CFGetTypeID(value) == AXValueGetTypeID() else {
            Log.warn("axSelection no-range-attribute")
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            Log.warn("axSelection range-decode-failed")
            return nil
        }
        guard range.length > 0 else {
            Log.warn("axSelection range-empty (真没有选区)")
            return nil
        }

        var rangeValue = range
        guard let axRange = AXValueCreate(.cfRange, &rangeValue) else { return nil }
        var text: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &text
        )
        guard status == .success, let string = text as? String else {
            Log.warn("axSelection range-only len=\(range.length) but stringForRange failed=\(status.rawValue)")
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        Log.info("axSelection via-range len=\(trimmed.count)")
        return trimmed
    }

    static func readSelection(_ element: AXUIElement) -> String? {
        guard let raw = copyAttribute(element, kAXSelectedTextAttribute as CFString).value as? String else {
            return nil
        }
        return raw
    }

    static func selectedText() -> String? {
        guard let app = focusedApplication() else {
            Log.warn("axDenied")
            return nil
        }
        return selectedText(inApp: app)
    }

    /// 指定 pid 的 App 读选区（探针用；也方便将来自定义"始终读取某个 App"）。
    static func selectedText(forPID pid: pid_t) -> String? {
        selectedText(inApp: AXUIElementCreateApplication(pid))
    }

    /// 同上的深挖版本。
    static func selectedTextDeep(forPID pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        if let text = selectedText(inApp: app) { return text }
        return deepScan(inApp: app)
    }

    static func selectedText(inApp app: AXUIElement) -> String? {
        ensureManualAccessibility(app)
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"

        // 浮层自己是 key 的时候，系统级「焦点 App」会变成我们；这时候读到的是浮层里的空选区
        if pid == ProcessInfo.processInfo.processIdentifier {
            Log.warn("axSelection self-app pid=\(pid) -> ignore")
            return nil
        }

        let focusedUI = elementAttribute(app, kAXFocusedUIElementAttribute as CFString)
        let element = focusedUI ?? elementAttribute(app, kAXFocusedWindowAttribute as CFString)
        guard let element = element else {
            Log.warn("axSelection no-element app=\(bundle) pid=\(pid)")
            return nil
        }
        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? "?"

        let selection = copyAttribute(element, kAXSelectedTextAttribute as CFString)
        guard selection.status == .success else {
            // Safari/WebKit 常常对 kAXSelectedText 返回 kAXErrorNoValue(-25212)，
            // 但选区范围还在：改用 kAXSelectedTextRange + kAXStringForRange 取原文。
            if let viaMarker = selectionViaMarker(element) {
                return viaMarker
            }
            if let viaRange = selectionViaRange(element) {
                return viaRange
            }
            Log.warn("axSelection error app=\(bundle) pid=\(pid) role=\(role) source=\(focusedUI == nil ? "window" : "uiElement") code=\(selection.status.rawValue)")
            report(selection.status)
            return nil
        }
        guard let raw = selection.value else {
            Log.warn("axSelection nil app=\(bundle) pid=\(pid) role=\(role)")
            return nil
        }
        let text = (raw as? String) ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Log.warn("axSelection empty app=\(bundle) pid=\(pid) role=\(role) source=\(focusedUI == nil ? "window" : "uiElement")")
            return nil
        }
        return text
    }

    static func setSelectedText(_ text: String) -> Bool {
        guard let element = focusedElement() else {
            Log.warn("axDenied")
            return false
        }
        let error = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        guard error == .success else {
            report(error)
            return false
        }
        return true
    }

    static func selectedRange() -> CFRange? {
        guard let element = focusedElement() else { return nil }
        guard let raw = copyAttribute(element, kAXSelectedTextRangeAttribute as CFString).value,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = raw as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    static func setSelectedRange(_ range: CFRange) -> Bool {
        guard let element = focusedElement() else { return false }
        var value = range
        guard let axValue = AXValueCreate(.cfRange, &value) else { return false }
        let error = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axValue
        )
        guard error == .success else {
            report(error)
            return false
        }
        return true
    }

    @discardableResult
    static func wrapSelectionViaClipboard(prefix: String, suffix: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        KeyPost.key(8, flags: .maskCommand)

        let deadline = Date().addingTimeInterval(0.3)
        while pasteboard.changeCount == before && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard pasteboard.changeCount != before,
              let text = pasteboard.string(forType: .string) else {
            return false
        }

        pasteboard.clearContents()
        pasteboard.setString(prefix + text + suffix, forType: .string)
        KeyPost.key(9, flags: .maskCommand)
        return true
    }
}
