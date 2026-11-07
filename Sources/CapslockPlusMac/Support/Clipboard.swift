import AppKit
import CoreGraphics

/// 读选区的最后手段：模拟 Cmd+C，读剪贴板，然后把剪贴板原样写回去。
/// 只对 `clipboardFallbackApps` 白名单里的 App 启用，避免动不动就改用户的剪贴板。
enum Clipboard {
    /// 返回复制到的文本；失败返回 nil（超时或 App 不支持复制）。
    static func copySelection(timeout: Double = 0.6) -> String? {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        KeyPost.key(8, flags: .maskCommand)   // 8 = kVK_ANSI_C

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                let text = pasteboard.string(forType: .string)
                restore(pasteboard, saved)
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            // 在跑主 RunLoop 的同时等剪贴板变化，避免阻塞事件处理太久
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        restore(pasteboard, saved)
        Log.warn("clipboard copy timeout ms=\(Int(timeout * 1000))")
        return nil
    }

    // MARK: - 剪贴板快照 / 还原

    private typealias ItemSnapshot = [(NSPasteboard.PasteboardType, Data)]

    private static func snapshot(_ pasteboard: NSPasteboard) -> [ItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        }
    }

    private static func restore(_ pasteboard: NSPasteboard, _ saved: [ItemSnapshot]) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items: [NSPasteboardItem] = saved.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - 自检

    /// 验证「快照 → 改写 → 还原」不丢内容（不动用户当前剪贴板以外的东西）。
    static func selftest() -> Bool {
        let pasteboard = NSPasteboard.general
        let original = snapshot(pasteboard)
        let originalText = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString("capslock-plus-clipboard-selftest", forType: .string)
        guard pasteboard.string(forType: .string) == "capslock-plus-clipboard-selftest" else {
            Log.warn("clipboard selftest failed at write")
            return false
        }

        restore(pasteboard, original)

        if original.isEmpty {
            print("clipboard selftest OK (empty -> restored empty)")
            return true
        }
        let restoredText = pasteboard.string(forType: .string)
        guard restoredText == originalText else {
            Log.warn("clipboard selftest failed restore expected=\(originalText?.count ?? -1) got=\(restoredText?.count ?? -1)")
            return false
        }
        print("clipboard selftest OK (restored \(original.count) item(s))")
        return true
    }
}
