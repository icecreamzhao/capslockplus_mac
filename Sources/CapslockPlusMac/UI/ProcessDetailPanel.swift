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
    /// 标签 -> 数值控件，用于就地刷新（重建整页会闪，还会打断选中复制）
    private var valueFields: [String: NSTextField] = [:]
    private var updateTimer: Timer?
    private var tick = 0

    /// 外部补字段：网络累计收发来自 nettop 的进程计数，不在 ProcessInspector 里
    /// （root 代理也拿不到这个数，所以不能写进 inspect）
    var extraFieldsProvider: ((pid_t) -> [ProcessDetail.Field])?

    /// 非空时用它代替 ProcessInspector 刷新（远端设备）。
    /// 不加这个 hook，远端详情的 2 秒刷新会去读本机同 pid 的进程，显示成完全不相干的程序。
    var refreshProvider: (() -> ProcessDetail?)?

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

        var buttonX = padding
        for (title, action, width) in [("在 Finder 中显示", #selector(revealInFinder), 126.0),
                                       ("复制全部", #selector(copyAll), 84.0),
                                       ("关闭", #selector(closePanel), 70.0)] {
            addButton(title, action, x: buttonX, width: CGFloat(width))
            buttonX += CGFloat(width) + 8          // 8pt 间距，避免叠在一起
        }
    }

    private func addButton(_ title: String, _ action: Selector, x: CGFloat, width: CGFloat) {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.frame = NSRect(x: x, y: 12, width: width, height: 22)
        button.autoresizingMask = [.maxXMargin, .maxYMargin]
        panel.contentView?.addSubview(button)
    }

    // MARK: - 展示

    func show(_ detail: ProcessDetail) {
        // 远端详情自带累计流量字段，不能再套本机 nettop 的累计值
        let detail = refreshProvider == nil ? augment(detail) : detail
        self.detail = detail
        panel.title = "进程详情 · \(detail.fields.first?.value ?? "pid \(detail.pid)")"
        render()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startUpdating()
    }

    // MARK: - 自动刷新

    /// 面板开着就一直跟着采样更新：累计 CPU、内存、线程数、已运行时长都会变。
    /// 每 2 秒就地改数值（不重建视图，避免闪烁和选中丢失）；
    /// root 代理在跑时每 3 轮（约 6 秒）再向它要一份完整数据（补 root 进程的字段）。
    private func startUpdating() {
        updateTimer?.invalidate()
        tick = 0
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    private func stopUpdating() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func refreshTick() {
        guard let pid = detail?.pid, panel.isVisible else { return }
        tick += 1

        // 远端详情：用外部 provider 刷新，绝不回落到本机 ProcessInspector / RootProbe
        if let provider = refreshProvider {
            if let fresh = provider() {
                apply(fresh, allowRebuild: false)
            }
            return
        }

        apply(augment(ProcessInspector.inspect(pid: pid)), allowRebuild: false)

        guard tick % 3 == 0, SystemMonitor.shared.rootActive else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let detail = RootProbe.detailFromAgent(pid: pid) else { return }
            DispatchQueue.main.async {
                guard let self, self.refreshProvider == nil else { return }
                self.apply(self.augment(detail), allowRebuild: true)
            }
        }
    }

    /// 把网络累计收发插到「监听端口」前面（也就是「累计 CPU」后面）
    private func augment(_ detail: ProcessDetail) -> ProcessDetail {
        guard let provider = extraFieldsProvider else { return detail }
        let extra = provider(detail.pid)
        guard !extra.isEmpty else { return detail }
        var fields = detail.fields.filter { field in !extra.contains { $0.label == field.label } }
        // 固定跟在「累计 CPU」后面，不管这个进程有没有监听端口，顺序都一致
        let insertAt = fields.firstIndex { $0.label == "累计 CPU" }.map { $0 + 1 } ?? fields.count
        fields.insert(contentsOf: extra, at: insertAt)
        var result = detail
        result.fields = fields
        return result
    }

    /// 字段集合相同就只改数值；集合变了（root 补全）才重建
    private func apply(_ new: ProcessDetail, allowRebuild: Bool) {
        guard let current = detail, current.pid == new.pid else { return }
        detail = new
        panel.title = "进程详情 · \(new.fields.first?.value ?? "pid \(new.pid)")"

        let sameShape = current.fields.map(\.label) == new.fields.map(\.label)
        guard sameShape else {
            if allowRebuild { render() }
            return
        }
        for field in new.fields {
            // 值没变就不动，免得把正在选中复制的内容刷掉
            if let label = valueFields[field.label], label.stringValue != field.value {
                label.stringValue = field.value
            }
        }
    }

    /// root 数据晚到时就地更新（先显示本地权限能读的部分，不让人干等）
    func update(_ detail: ProcessDetail) {
        apply(detail, allowRebuild: true)
    }

    private func render() {
        guard let detail else { return }
        documentView.subviews.forEach { $0.removeFromSuperview() }
        valueFields.removeAll()

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
            valueFields[field.label] = value

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
        hide()
    }

    /// 自检用
    var debugInfo: String {
        let buttons = (panel.contentView?.subviews.compactMap { $0 as? NSButton } ?? [])
            .map { "\($0.title)[\(Int($0.frame.minX))-\(Int($0.frame.maxX))]" }
            .joined(separator: " ")
        return "visible=\(panel.isVisible ? 1 : 0) fields=\(detail?.fields.count ?? 0)"
            + " size=\(Int(panel.frame.width))x\(Int(panel.frame.height)) buttons=\(buttons)"
    }

    /// 自检用：当前字段标签顺序
    var debugLabels: String {
        detail?.fields.map(\.label).joined(separator: " / ") ?? "-"
    }

    /// 自检用：读某个字段当前显示的文本
    func valueFor(_ label: String) -> String {
        valueFields[label]?.stringValue ?? "-"
    }

    func hide() {
        stopUpdating()
        refreshProvider = nil
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        hide()
    }
}

/// 滚动视图的文档视图要翻转，否则内容从下往上涨
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
