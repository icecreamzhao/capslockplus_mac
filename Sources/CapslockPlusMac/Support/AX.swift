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

    static func selectedText() -> String? {
        guard let element = focusedElement() else {
            Log.warn("axDenied")
            return nil
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard error == .success else {
            report(error)
            return nil
        }
        guard let raw = value else { return nil }
        return raw as? String
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
