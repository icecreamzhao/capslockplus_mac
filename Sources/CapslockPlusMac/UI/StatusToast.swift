import AppKit

/// 输入法切换的短促 HUD：屏幕底部中间浮一个小胶囊，显示"切换之后的当前输入法"，随后淡出。
///
/// 三条硬要求（都是踩过的坑）：
/// - 不抢焦点：`.nonactivatingPanel` + `canBecomeKey = false`，否则切完输入法焦点跑到 HUD 上，
///   用户下一下按键就打在空气里；
/// - 不吃鼠标：`ignoresMouseEvents = true`，浮在最上层但不挡点击；
/// - 不自己算"切成功了没有"：只在 `InputSource.switchNext` 的 verify 通过后调用，
///   显示的名字就是切换后 `currentName()` 的真实值，不是"打算切到谁"。
/// NSPanel 的 canBecomeKey/ canBecomeMain 是只读属性，只能靠子类关掉。
/// 关不掉的话 HUD 一出现就抢走键盘焦点，用户下一串组合键全打在 HUD 上。
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class StatusToast {
    static let shared = StatusToast()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    private let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
    private let height: CGFloat = 40
    private let paddingX: CGFloat = 22
    /// 胶囊内部文字左右各留的空隙（比外层 padding 小，保证有富余不出省略号）
    private let textInset: CGFloat = 8

    private init() {}

    /// - Parameters:
    ///   - text: 主行，切完之后的输入法名字
    ///   - detail: 副行（可选），例如 "CAPS 开"
    ///   - ms: 停留时长，0 表示不显示（配置里关掉这条路）
    func show(_ text: String, detail: String? = nil, ms: Int = 700) {
        guard ms > 0, !text.isEmpty else { return }

        // 连按长按时复用同一块 HUD，只换文字、重置计时，不闪两个窗口
        hideWork?.cancel()

        let body = detail.map { "\(text)　·　\($0)" } ?? text
        let size = (body as NSString).size(withAttributes: [.font: font])
        let screen = screenUnderMouse()
        let frame = StatusToast.frame(textSize: size, visible: screen.visibleFrame,
                                      paddingX: paddingX, height: height)

        let panel = ensurePanel(width: frame.width)
        label?.stringValue = body
        panel.setFrame(frame, display: true)
        layout(panel: panel, width: frame.width)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            panel.animator().alphaValue = 1
        }

        Log.info("toast show text=\(body) frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) ms=\(ms)")

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    func dismiss() {
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    // MARK: - 布局（纯函数，自检里断言不会跑到屏幕外）

    /// 位置：屏幕正中间（横竖都居中），再夹回 visibleFrame。
    /// 宽度留 6pt 余量：NSString.size 的量测会略偏小，正好贴边就会被截成 "A…"。
    static func frame(textSize: CGSize, visible: CGRect,
                      paddingX: CGFloat, height: CGFloat) -> CGRect {
        let maxWidth = max(visible.width - 40, 120)
        let width = min(ceil(textSize.width) + paddingX * 2 + 6, maxWidth)
        var x = visible.midX - width / 2
        var y = visible.midY - height / 2
        x = min(max(x, visible.minX + 12), max(visible.maxX - width - 12, visible.minX + 12))
        y = min(max(y, visible.minY + 12), max(visible.maxY - height - 12, visible.minY + 12))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func ensurePanel(width: CGFloat) -> NSPanel {
        if let panel = panel { return panel }

        let panel = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]

        let card = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.9).cgColor
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: textInset, y: (height - 18) / 2, width: width - textInset * 2, height: 18)
        label.autoresizingMask = [.width]
        card.addSubview(label)

        panel.contentView = card
        self.panel = panel
        self.label = label
        return panel
    }

    /// 复用同一个 panel 时宽度会变，这里按新宽度重排一次，
    /// 不指望 autoresizing：它只会按增量拉伸，窄→宽的来回切换很容易算错。
    private func layout(panel: NSPanel, width: CGFloat) {
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        label?.frame = NSRect(x: textInset, y: (height - 18) / 2,
                              width: width - textInset * 2, height: 18)
    }
}
