import AppKit

/// 进程详情面板：一行一个 (标签, 值)，值可选中复制。
/// 单独做成面板而不是塞进表格，是因为启动参数、可执行文件路径这些很长，
/// 需要换行和复制。
final class ProcessDetailPanel: NSObject, NSWindowDelegate {
    static let shared = ProcessDetailPanel()

    private let panel = SystemPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                                    styleMask: [.titled, .closable, .resizable, .utilityWindow],
                                    backing: .buffered, defer: false)
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private var detail: ProcessDetail?

    private override init() {
        super.init()
        panel.title = "进程详情"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 420, height: 240)
        buildContent()
    }

    private func buildContent() {
        let content = panel.contentView!
        let padding: CGFloat = 16
        let width = content.bounds.width - padding * 2
        let height = content.bounds.height

        scrollView.frame = NSRect(x: padding, y: 46, width: width, height: height - 62)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        content.addSubview(scrollView)

        addButton("在 Finder 中显示", #selector(revealInFinder), x: padding)
        addButton("复制全部", #selector(copyAll), x: padding + 132)
        addButton("关闭", #selector(closePanel), x: padding + 232)
    }

    private func addButton(_ title: String, _ action: Selector, x: CGFloat) {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.frame = NSRect(x: x, y: 12, width: 120, height: 22)
        button.autoresizingMask = [.maxXMargin, .maxYMargin]
        panel.contentView?.addSubview(button)
    }

    // MARK: - 展示

    func show(_ detail: ProcessDetail) {
        self.detail = detail
        panel.title = "进程详情 · \(detail.fields.first?.value ?? "pid \(detail.pid)")"
        render()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// root 数据晚到时就地更新（先显示本地权限能读的部分，不让人干等）
    func update(_ detail: ProcessDetail) {
        guard self.detail?.pid == detail.pid else { return }
        self.detail = detail
        render()
    }

    private func render() {
        guard let detail else { return }
        documentView.subviews.forEach { $0.removeFromSuperview() }

        let padding: CGFloat = 14
        let labelWidth: CGFloat = 96
        let documentWidth = max(scrollView.contentSize.width, 200)
        let valueWidth = documentWidth - padding * 2 - labelWidth
        var y: CGFloat = padding

        for field in detail.fields {
            let label = NSTextField(labelWithString: field.label)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            label.frame = NSRect(x: padding, y: y + 1, width: labelWidth, height: 15)
            documentView.addSubview(label)

            let value = NSTextField(wrappingLabelWithString: field.value)
            value.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            value.isSelectable = true
            value.allowsEditingTextAttributes = false
            let valueHeight = Self.height(of: field.value, width: valueWidth)
            value.frame = NSRect(x: padding + labelWidth + 10, y: y, width: valueWidth, height: valueHeight)
            documentView.addSubview(value)

            y += max(valueHeight, 16) + 8
        }

        documentView.frame = NSRect(x: 0, y: 0, width: documentWidth, height: y + padding)
    }

    private static func height(of text: String, width: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)]
        let rect = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: attributes)
        return max(ceil(rect.height) + 2, 16)
    }

    // MARK: - 动作

    @objc private func revealInFinder() {
        guard let path = detail?.executablePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func copyAll() {
        guard let detail else { return }
        let text = detail.fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func closePanel() {
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        panel.orderOut(nil)
    }
}

/// 滚动视图的文档视图要翻转，否则内容从下往上涨
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
