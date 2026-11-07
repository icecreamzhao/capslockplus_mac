import Foundation
import AppKit
import CoreGraphics

enum TextActions {
    private static let left: CGKeyCode = 123
    private static let right: CGKeyCode = 124
    private static let down: CGKeyCode = 125
    private static let up: CGKeyCode = 126
    private static let backspace: CGKeyCode = 51
    private static let forwardDelete: CGKeyCode = 117
    private static let enter: CGKeyCode = 36

    static func run(_ action: Action) -> Bool {
        switch action {
        case .moveLeft:
            KeyPost.key(left)
        case .moveRight:
            KeyPost.key(right)
        case .moveUp:
            KeyPost.key(up)
        case .moveDown:
            KeyPost.key(down)
        case .moveWordLeft:
            KeyPost.key(left, flags: .maskAlternate)
        case .moveWordRight:
            KeyPost.key(right, flags: .maskAlternate)
        case .moveLineStart:
            KeyPost.key(left, flags: .maskCommand)
        case .moveLineEnd:
            KeyPost.key(right, flags: .maskCommand)
        case .moveUp10:
            repeatKey(up, count: 10)
        case .moveDown10:
            repeatKey(down, count: 10)
        case .selectLeft:
            KeyPost.key(left, flags: .maskShift)
        case .selectRight:
            KeyPost.key(right, flags: .maskShift)
        case .selectWordLeft:
            KeyPost.key(left, flags: [.maskAlternate, .maskShift])
        case .selectWordRight:
            KeyPost.key(right, flags: [.maskAlternate, .maskShift])
        case .selectUp:
            KeyPost.key(up, flags: .maskShift)
        case .selectDown:
            KeyPost.key(down, flags: .maskShift)
        case .selectLineStart:
            KeyPost.key(left, flags: [.maskCommand, .maskShift])
        case .selectLineEnd:
            KeyPost.key(right, flags: [.maskCommand, .maskShift])
        case .selectUp10:
            repeatKey(up, count: 10, flags: .maskShift)
        case .selectDown10:
            repeatKey(down, count: 10, flags: .maskShift)
        case .deleteBackward:
            KeyPost.key(backspace)
        case .deleteForward:
            KeyPost.key(forwardDelete)
        case .deleteWordBackward:
            KeyPost.key(backspace, flags: .maskAlternate)
        case .deleteToLineStart:
            KeyPost.key(left, flags: [.maskCommand, .maskShift])
            KeyPost.key(backspace)
        case .deleteToLineEnd:
            KeyPost.key(right, flags: [.maskCommand, .maskShift])
            KeyPost.key(backspace)
        case .deleteWordForward:
            KeyPost.key(forwardDelete, flags: .maskAlternate)
        case .deleteToPageStart:
            KeyPost.key(up, flags: [.maskCommand, .maskShift])
            KeyPost.key(backspace)
        case .deleteToPageEnd:
            KeyPost.key(down, flags: [.maskCommand, .maskShift])
            KeyPost.key(backspace)
        case .deleteAll:
            KeyPost.key(0, flags: .maskCommand)
            KeyPost.key(backspace)
        case .hardDeleteLine:
            KeyPost.key(left, flags: .maskCommand)
            KeyPost.key(right, flags: [.maskCommand, .maskShift])
            KeyPost.key(down, flags: .maskShift)
            KeyPost.key(backspace)
        case .deleteLine:
            KeyPost.key(left, flags: .maskCommand)
            KeyPost.key(right, flags: [.maskCommand, .maskShift])
            KeyPost.key(backspace)
            KeyPost.key(backspace)
        case .insertLineBelow:
            KeyPost.key(right, flags: .maskCommand)
            KeyPost.key(enter)
        case .pressReturn:
            KeyPost.key(enter)
        case .selectCurrentWord:
            KeyPost.key(left, flags: [.maskAlternate, .maskShift])
        case .wrapSelection(let kind):
            wrapSelection(kind)
        case .transform(let kind):
            transformSelection(kind)
        case .insertDate(let format):
            insertDate(format)
        case .sendKeys(let spec):
            if KeyPost.keys(spec) {
                Log.info("action=send spec=\(spec) ok=1")
            }
        case .typeText(let text):
            KeyPost.text(text)
            Log.info("action=type n=\(text.utf16.count)")
        case .minimizeWindow:
            if !AX.minimizeFocusedWindow() {
                Log.warn("minimize failed")
            }
        case .launchApp(let bundleID):
            launchApp(bundleID)
        case .repeated(let base, let count):
            for _ in 0..<max(0, min(count, 100)) {
                _ = run(base)
            }
        default:
            return false
        }
        return true
    }

    private static func insertDate(_ format: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        let text = formatter.string(from: Date())
        // 优先合成输入：AX 的 setSelectedText 在不少 App 里返回成功但实际不插入
        KeyPost.text(text)
        Log.info("insertdate \(format) -> \(text) via=typing")
    }

    private static func transformSelection(_ kind: String) {
        guard TextTransform.kinds.contains(kind.lowercased()) else {
            Log.warn("transform unknown kind=\(kind)")
            return
        }
        guard let selected = AX.selectedText(), !selected.isEmpty else {
            Log.warn("transform failed reason=no-selection kind=\(kind)")
            return
        }
        guard let output = TextTransform.apply(kind, to: selected) else {
            Log.warn("transform failed reason=apply kind=\(kind)")
            return
        }
        let range = AX.selectedRange()
        guard AX.setSelectedText(output) else {
            Log.warn("transform failed reason=write kind=\(kind)")
            return
        }
        if let range = range {
            _ = AX.setSelectedRange(CFRange(location: range.location, length: (output as NSString).length))
        }
        Log.info("transform \(kind) chars=\(selected.count)->\(output.count)")
    }

    private static func repeatKey(_ code: CGKeyCode, count: Int, flags: CGEventFlags = []) {
        for _ in 0..<count {
            KeyPost.key(code, flags: flags)
        }
    }

    private static func launchApp(_ bundleID: String) {
        Log.info("action=launchApp bundle=\(bundleID)")
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            _ = running.activate(options: [.activateAllWindows])
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Log.warn("launchApp failed bundle=\(bundleID) reason=no-url")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            if let error {
                Log.warn("launchApp failed bundle=\(bundleID) reason=\(error.localizedDescription)")
                return
            }
            _ = app?.activate(options: [.activateAllWindows])
        }
    }

    private static func wrapSelection(_ kind: String) {
        let pairs: [String: (String, String)] = [
            "paren": ("(", ")"),
            "parentheses": ("(", ")"),
            "bracket": ("[", "]"),
            "brackets": ("[", "]"),
            "brace": ("{", "}"),
            "braces": ("{", "}"),
            "angle": ("<", ">"),
            "quote": ("\"", "\""),
            "doublequote": ("\"", "\""),
            "singlequote": ("'", "'"),
            "backtick": ("`", "`"),
            "markdown": ("`", "`")
        ]
        guard let (prefix, suffix) = pairs[kind.lowercased()] else {
            Log.warn("wrapSelection failed unknown kind=\(kind)")
            return
        }

        if let text = AX.selectedText(), !text.isEmpty {
            let range = AX.selectedRange()
            if AX.setSelectedText(prefix + text + suffix) {
                if let original = range {
                    let caret = original.location
                        + (prefix as NSString).length
                        + (text as NSString).length
                    _ = AX.setSelectedRange(CFRange(location: caret, length: 0))
                }
                return
            }
        }

        if !AX.wrapSelectionViaClipboard(prefix: prefix, suffix: suffix) {
            Log.warn("wrapSelection failed")
        }
    }
}
