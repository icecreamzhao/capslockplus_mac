import Foundation
import AppKit
import CoreGraphics

/// 剪贴板动作：只做系统级的 cut/copy/paste 和"粘成纯文本"。
/// 多剪贴板（额外 pasteboard）在 v0 就被砍掉了，相关代码不再保留。
enum ClipboardActions {
    static func cut() {
        KeyPost.key(7, flags: .maskCommand)
    }

    static func copy() {
        KeyPost.key(8, flags: .maskCommand)
    }

    static func paste() {
        KeyPost.key(9, flags: .maskCommand)
    }

    /// 粘贴为纯文本：把剪贴板里的富文本/样式清掉，只留字符串，再发 Cmd+V
    static func pastePlain() {
        let general = NSPasteboard.general
        guard let text = general.string(forType: .string) else {
            Log.warn("clipboard pastePlain empty")
            return
        }
        general.clearContents()
        general.setString(text, forType: .string)
        KeyPost.key(9, flags: .maskCommand)
    }
}
