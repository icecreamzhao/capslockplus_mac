import Foundation
import AppKit
import ApplicationServices
import Carbon

/// AX 窗口：frame 读写、最小化、按标题 raise。
extension AX {
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

    static func focusedWindowTitle() -> String? {
        guard let window = focusedWindow() else { return nil }
        guard let raw = copyAttribute(window, kAXTitleAttribute as CFString).value else { return nil }
        return raw as? String
    }

    @discardableResult
    static func raiseWindow(pid: pid_t, titleHint: String) -> Bool {
        guard !titleHint.isEmpty else { return false }
        let app = AXUIElementCreateApplication(pid)
        guard let raw = copyAttribute(app, kAXWindowsAttribute as CFString).value,
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
            guard let windowTitle = copyAttribute(window, kAXTitleAttribute as CFString).value as? String else {
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
}
