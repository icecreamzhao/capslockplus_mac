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
