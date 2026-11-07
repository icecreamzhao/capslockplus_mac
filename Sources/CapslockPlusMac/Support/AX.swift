import Foundation
import AppKit
import ApplicationServices

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

    /// 聚焦窗口的 frame，AX 坐标系（原点在主屏左上，y 向下）。
    static func focusedWindowFrame() -> CGRect? {
        guard let window = focusedWindow() else { return nil }
        guard let position = pointAttribute(window, kAXPositionAttribute as CFString),
              let size = sizeAttribute(window, kAXSizeAttribute as CFString) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// 设置聚焦窗口的位置和大小。先设 size 再设 position，最后再补一次 size：
    /// 多数 App 会把超出屏幕的窗口夹回可视区，只设一次经常只生效一半。
    @discardableResult
    static func setFocusedWindowFrame(_ rect: CGRect) -> Bool {
        guard let window = focusedWindow() else { return false }
        var size = rect.size
        var origin = rect.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size),
              let originValue = AXValueCreate(.cgPoint, &origin) else { return false }
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
        let error = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        if error != .success {
            report(error)
            return false
        }
        return true
    }

    @discardableResult
    static func minimizeFocusedWindow() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        guard let window = elementAttribute(systemWide, kAXFocusedWindowAttribute as CFString) else {
            return false
        }
        let error = AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        )
        return error == .success
    }

    static func focusedElement() -> AXUIElement? {
        guard let app = focusedApplication() else { return nil }
        return elementAttribute(app, kAXFocusedUIElementAttribute as CFString)
            ?? elementAttribute(app, kAXFocusedWindowAttribute as CFString)
    }

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

        let front = NSWorkspace.shared.frontmostApplication
        Log.warn("axSelection deep start apppid=\(pid) appActive=\(NSApp.isActive ? 1 : 0) panelShown=\(TranslatePanel.shared.isShowing ? 1 : 0) front=\(front?.bundleIdentifier ?? "?") frontpid=\(front?.processIdentifier ?? 0)")
        var visited = 0
        var found: String?
        func scan(_ element: AXUIElement, depth: Int) {
            guard found == nil, visited < 300, depth <= 5 else { return }
            visited += 1
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
               let raw = value as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    found = trimmed
                    return
                }
            }
            guard let children = childrenAttribute(element) else { return }
            for child in children {
                scan(child, depth: depth + 1)
                if found != nil { return }
            }
        }

        if let window = elementAttribute(app, kAXFocusedWindowAttribute as CFString) {
            scan(window, depth: 0)
        }
        if found == nil, let windows = elementArrayAttribute(app, kAXWindowsAttribute as CFString) {
            for window in windows {
                scan(window, depth: 0)
                if found != nil { break }
            }
        }
        if let text = found {
            Log.info("axSelection deep hit apppid=\(pid) scanned=\(visited) len=\(text.count)")
        } else {
            Log.warn("axSelection deep miss apppid=\(pid) scanned=\(visited)")
        }
        return found
    }

    /// 用「选区范围 + 按范围取文本」兜底，Safari/WebKit 走这条路能拿到选中的字。
    private static func selectionViaRange(_ element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.length > 0 else { return nil }

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

    private static func readSelection(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let raw = value as? String else { return nil }
        return raw
    }

    private static func childrenAttribute(_ element: AXUIElement) -> [AXUIElement]? {
        elementArrayAttribute(element, kAXChildrenAttribute as CFString)
    }

    private static func elementArrayAttribute(_ element: AXUIElement, _ name: CFString) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let raw = value, CFGetTypeID(raw) == CFArrayGetTypeID() else { return nil }
        return (raw as? [AXUIElement]) ?? []
    }

    static func selectedText() -> String? {
        guard let app = focusedApplication() else {
            Log.warn("axDenied")
            return nil
        }
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

        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard error == .success else {
            // Safari/WebKit 常常对 kAXSelectedText 返回 kAXErrorNoValue(-25212)，
            // 但选区范围还在：改用 kAXSelectedTextRange + kAXStringForRange 取原文。
            if let viaRange = selectionViaRange(element) {
                return viaRange
            }
            Log.warn("axSelection error app=\(bundle) pid=\(pid) role=\(role) source=\(focusedUI == nil ? "window" : "uiElement") code=\(error.rawValue)")
            report(error)
            return nil
        }
        guard let raw = value else {
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
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else {
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

    static func focusedWindowTitle() -> String? {
        guard let window = focusedWindow() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let raw = value else {
            return nil
        }
        return raw as? String
    }

    @discardableResult
    static func raiseWindow(pid: pid_t, titleHint: String) -> Bool {
        guard !titleHint.isEmpty else { return false }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let raw = value,
              CFGetTypeID(raw) == CFArrayGetTypeID() else {
            Log.warn("ax raiseWindow failed reason=no-windows")
            return false
        }
        let windows = raw as! CFArray
        var best: AXUIElement?
        var bestRank = 0
        for index in 0..<CFArrayGetCount(windows) {
            guard let pointer = CFArrayGetValueAtIndex(windows, index) else { continue }
            let window = Unmanaged<AXUIElement>.fromOpaque(pointer).takeUnretainedValue()
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let windowTitle = titleValue as? String else {
                continue
            }
            let rank: Int
            if windowTitle == titleHint {
                rank = 3
            } else if windowTitle.hasPrefix(titleHint) {
                rank = 2
            } else if windowTitle.contains(titleHint) {
                rank = 1
            } else {
                continue
            }
            if rank > bestRank {
                bestRank = rank
                best = window
                if rank == 3 { break }
            }
        }
        guard let window = best else { return false }
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
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

    private static func pointAttribute(_ element: AXUIElement, _ name: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ name: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let raw = value, CFGetTypeID(raw) == CFStringGetTypeID() else {
            return nil
        }
        return (raw as! String)
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return raw as! AXUIElement
    }

    private static func report(_ error: AXError) {
        if error == .apiDisabled {
            Log.warn("axDenied")
        } else {
            Log.warn("ax error=\(error.rawValue)")
        }
    }
}
