import Foundation
import AppKit

/// 翻译浮层：无边框、不抢焦点、贴鼠标位置。
/// 关闭方式：再按一次热键 / 点窗口外 / 12 秒后自动消失。
final class TranslatePanel: NSPanel {
    static let shared = TranslatePanel()

    private let effectView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private var dismissTimer: Timer?
    private var clickMonitor: Any?
    private var isShown = false

    private let width: CGFloat = 360
    private let padding: CGFloat = 14

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        ignoresMouseEvents = false

        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        bodyLabel.font = NSFont.systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.isSelectable = false

        effectView.addSubview(titleLabel)
        effectView.addSubview(bodyLabel)
        contentView = effectView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var isVisible: Bool { isShown }

    func showPending(query: String) {
        render(query: query, body: "查询中…")
    }

    func show(result: Translation) {
        render(query: result.query, body: result.displayText)
    }

    func show(error: String) {
        render(query: "翻译失败", body: error)
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        guard isShown else { return }
        orderOut(nil)
        isShown = false
        Log.info("translate panel hidden")
    }

    // MARK: - 布局

    private func render(query: String, body: String) {
        titleLabel.stringValue = query
        bodyLabel.stringValue = body

        let textWidth = width - padding * 2
        let bodyHeight = measure(body, font: bodyLabel.font!, width: textWidth)
        let titleHeight: CGFloat = 20

        let height = max(60, padding * 2 + titleHeight + 6 + bodyHeight)
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        setFrame(frame, display: true)

        titleLabel.frame = NSRect(x: padding, y: height - padding - titleHeight, width: textWidth, height: titleHeight)
        bodyLabel.frame = NSRect(x: padding, y: padding, width: textWidth, height: bodyHeight)

        positionNearCursor()
        if !isShown {
            orderFrontRegardless()
            isShown = true
            installClickMonitor()
        }

        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        Log.info("translate panel shown query=\(query) h=\(Int(height))")
    }

    private func measure(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    private func positionNearCursor() {
        let mouse = NSEvent.mouseLocation
        let size = frame.size
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            setFrameOrigin(mouse)
            return
        }
        let visible = screen.visibleFrame
        var x = mouse.x + 12
        var y = mouse.y - size.height - 12
        if x + size.width > visible.maxX { x = visible.maxX - size.width - 8 }
        if x < visible.minX { x = visible.minX + 8 }
        if y < visible.minY { y = mouse.y + 16 }
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.dismiss()
        }
    }
}
