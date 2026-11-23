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
    /// 每次 show/dismiss 都自增，用来让已经起跑的淡出回调失效
    private var generation = 0

    /// 尺寸集中在这里：自检也用同一份，改字体大小不会让断言悄悄失配
    enum Metrics {
        static let font = NSFont.systemFont(ofSize: 19, weight: .semibold)
        static let height: CGFloat = 46
        static let paddingX: CGFloat = 26
        /// 胶囊内部文字左右各留的空隙（比外层 padding 小，保证有富余不出省略号）
        static let textInset: CGFloat = 10
        static let labelHeight: CGFloat = 24
    }

    private let font = Metrics.font
    private let height = Metrics.height
    private let paddingX = Metrics.paddingX
    private let textInset = Metrics.textInset

    private init() {}

    /// - Parameters:
    ///   - text: 主行，切完之后的输入法名字
    ///   - detail: 副行（可选），例如 "CAPS 开"
    ///   - ms: 停留时长，0 表示不显示（配置里关掉这条路）
    func show(_ text: String, detail: String? = nil, ms: Int = 700) {
        guard ms > 0, !text.isEmpty else { return }

        // 连按长按时复用同一块 HUD，只换文字、重置计时，不闪两个窗口
        generation &+= 1
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
        // 正在淡出时 panel 还是可见的：保持当前 alpha 直接淡入，否则会闪一下
        if !panel.isVisible {
            panel.alphaValue = 0
        }
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
        generation &+= 1
        let gen = generation
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // 淡出期间又来了新的 show：这次回调已经过期，不能再关 panel
            guard self?.generation == gen else { return }
            panel.orderOut(nil)
        }
    }

    // MARK: - 自检

    /// 供 CLI 自检判断 HUD 是否还留在屏幕上
    var debugIsVisible: Bool { panel?.isVisible ?? false }

    /// 供 CLI 自检重复跑：关掉 panel 并清掉计时/失效标记
    func debugReset() {
        hideWork?.cancel()
        hideWork = nil
        generation = 0
        panel?.orderOut(nil)
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

        // 毛玻璃而不是纯色块：能透出背后的内容，又不至于看不清字
        let card = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: textInset, y: (height - Metrics.labelHeight) / 2,
                             width: width - textInset * 2, height: Metrics.labelHeight)
        label.autoresizingMask = [.width]
        label.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            return shadow
        }()
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
        label?.frame = NSRect(x: textInset, y: (height - Metrics.labelHeight) / 2,
                              width: width - textInset * 2, height: Metrics.labelHeight)
    }
}
