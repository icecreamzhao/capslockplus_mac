import Foundation
import AppKit
import CoreGraphics

enum ClipboardActions {
    static let extraName = NSPasteboard.Name("com.littleboy.CapslockPlusMac.extra1")

    private static var extra: NSPasteboard {
        return NSPasteboard(name: extraName)
    }

    static func cut() {
        KeyPost.key(7, flags: .maskCommand)
    }

    static func copy() {
        KeyPost.key(8, flags: .maskCommand)
    }

    static func paste() {
        KeyPost.key(9, flags: .maskCommand)
    }

    static func extraCut() {
        captureToExtra(keyCode: 7, label: "cut")
    }

    static func extraCopy() {
        captureToExtra(keyCode: 8, label: "copy")
    }

    static func extraPaste() {
        let source = extra
        guard let items = source.pasteboardItems, !items.isEmpty else {
            Log.warn("clipboard extra empty")
            return
        }
        let general = NSPasteboard.general
        general.clearContents()
        guard general.writeObjects(clone(items)) else {
            Log.warn("clipboard extra paste failed")
            return
        }
        KeyPost.key(9, flags: .maskCommand)
    }

    static func pastePlain() {
        let text = extra.string(forType: .string) ?? NSPasteboard.general.string(forType: .string)
        guard let text = text else {
            Log.warn("clipboard pastePlain empty")
            return
        }
        let general = NSPasteboard.general
        general.clearContents()
        general.setString(text, forType: .string)
        KeyPost.key(9, flags: .maskCommand)
    }

    private static func captureToExtra(keyCode: CGKeyCode, label: String) {
        let general = NSPasteboard.general
        let before = general.changeCount
        KeyPost.key(keyCode, flags: .maskCommand)

        let deadline = Date().addingTimeInterval(0.3)
        while general.changeCount == before && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard general.changeCount != before else {
            Log.warn("clipboard capture timeout action=\(label)")
            return
        }
        guard let items = general.pasteboardItems, !items.isEmpty else {
            Log.warn("clipboard capture empty action=\(label)")
            return
        }

        let board = extra
        board.clearContents()
        guard board.writeObjects(clone(items)) else {
            Log.warn("clipboard extra write failed")
            return
        }
        Log.info("clipboard captured n=\(items.count) action=\(label)")
    }

    private static func clone(_ items: [NSPasteboardItem]) -> [NSPasteboardItem] {
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }
}
