import AppKit

/// 独立窗口展示系统基本信息。
///
/// 为什么不做成菜单里的一节：菜单一关就消失，而看 CPU/温度这类东西通常要盯几秒；
/// 独立窗口能一直开着、边干活边瞄。窗口不自己采样，只订阅 `SystemMonitor` 的结果，
/// 避免多一份开销。
final class SystemWindowController: NSObject, NSWindowDelegate {
    static let shared = SystemWindowController()

    private let panel: SystemPanel
    private var cpuBar = NSProgressIndicator()
    private var memBar = NSProgressIndicator()
    private var cpuLabel = NSTextField(labelWithString: "CPU")
    private var memLabel = NSTextField(labelWithString: "内存")
    private var valueLabels: [String: NSTextField] = [:]
    private var titleLabels: [String: NSTextField] = [:]
    private var footerLabel = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?

    /// 固定顺序：数值取不到的整行隐藏
    private static let rowOrder = ["负载", "运行时间", "磁盘", "网络", "电池", "温度", "风扇"]

    private override init() {
        panel = SystemPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 430),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        super.init()
        panel.title = "系统"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        buildContent()
    }

    // MARK: - 界面

    private func buildContent() {
        let content = panel.contentView!
        let padding: CGFloat = 18
        let width = content.bounds.width - padding * 2

        let heading = NSTextField(labelWithString: "实时状态")
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .tertiaryLabelColor
        heading.frame = NSRect(x: padding, y: content.bounds.height - 30, width: 200, height: 15)
        content.addSubview(heading)

        cpuLabel = metricLabel("CPU")
        cpuBar = progressBar()
        memLabel = metricLabel("内存")
        memBar = progressBar()

        let barX = padding + 70
        cpuLabel.frame = NSRect(x: padding, y: content.bounds.height - 58, width: 70, height: 17)
        cpuBar.frame = NSRect(x: barX, y: content.bounds.height - 55, width: width - 70, height: 10)
        memLabel.frame = NSRect(x: padding, y: content.bounds.height - 84, width: 70, height: 17)
        memBar.frame = NSRect(x: barX, y: content.bounds.height - 81, width: width - 70, height: 10)
        content.addSubview(cpuLabel)
        content.addSubview(cpuBar)
        content.addSubview(memLabel)
        content.addSubview(memBar)

        let separator = NSBox(frame: NSRect(x: padding, y: content.bounds.height - 100, width: width, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)

        var y = content.bounds.height - 124
        for title in Self.rowOrder {
            let name = NSTextField(labelWithString: title)
            name.font = .systemFont(ofSize: 12)
            name.textColor = .secondaryLabelColor
            name.frame = NSRect(x: padding, y: y, width: 64, height: 17)

            let value = NSTextField(labelWithString: "—")
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.alignment = .right
            value.lineBreakMode = .byTruncatingTail
            value.frame = NSRect(x: padding + 68, y: y, width: width - 68, height: 17)

            content.addSubview(name)
            content.addSubview(value)
            titleLabels[title] = name
            valueLabels[title] = value
            y -= 24
        }

        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.frame = NSRect(x: padding, y: 12, width: width, height: 14)
        content.addSubview(footerLabel)
    }

    private func metricLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func progressBar() -> NSProgressIndicator {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        return bar
    }

    // MARK: - 显示 / 隐藏

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        // 关掉菜单栏读数的人也可能想开窗口，所以这里按需拉起采样
        if !SystemMonitor.shared.isRunning {
            SystemMonitor.shared.start(sampleMs: Config.shared.systemSampleMs)
        }
        NSApp.activate(ignoringOtherApps: true)
        positionIfNeeded()
        refresh(with: SystemMonitor.shared.snapshot)
        panel.makeKeyAndOrderFront(nil)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: SystemMonitor.didUpdate, object: nil, queue: .main) { [weak self] note in
                guard let snapshot = note.object as? SystemSnapshot else { return }
                self?.refresh(with: snapshot)
            }
        }
    }

    func hide() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: "systemWindow.origin")
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        hide()
    }

    /// 自检用：窗口几何与可见性（不涉及像素比对）
    var debugFrame: String {
        let frame = panel.frame
        return "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
            + " visible=\(panel.isVisible ? 1 : 0) rows=\(valueLabels.values.filter { !$0.isHidden }.count)"
    }

    /// 第一次打开放屏幕右上角，之后用上次拖到的位置
    private func positionIfNeeded() {
        if let saved = UserDefaults.standard.string(forKey: "systemWindow.origin") {
            panel.setFrameOrigin(NSPointFromString(saved))
            return
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 24,
                                     y: visible.maxY - panel.frame.height - 24))
    }

    private func refresh(with snapshot: SystemSnapshot) {
        cpuBar.doubleValue = snapshot.cpu
        memBar.doubleValue = snapshot.memPercent
        cpuLabel.stringValue = "CPU \(SystemFormat.percent(snapshot.cpu))"
        memLabel.stringValue = "内存 \(SystemFormat.percent(snapshot.memPercent))"
        cpuLabel.toolTip = "\(ProcessInfo.processInfo.processorCount) 核"
        memLabel.toolTip = "\(SystemFormat.bytes(snapshot.memUsed)) / \(SystemFormat.bytes(snapshot.memTotal))"

        var values: [String: String] = [:]
        for line in SystemMonitor.shared.menuLines() { values[line.title] = line.value }

        for title in Self.rowOrder {
            let has = values[title] != nil
            titleLabels[title]?.isHidden = !has
            valueLabels[title]?.isHidden = !has
            valueLabels[title]?.stringValue = values[title] ?? "—"
        }

        let age = max(Int(Date().timeIntervalSince(snapshot.sampledAt).rounded()), 0)
        footerLabel.stringValue = "每 \(Config.shared.systemSampleMs / 1000) 秒刷新 · \(age) 秒前 · 数据来自系统框架"
    }
}

/// Esc 关闭。LSUIElement 应用要能成 key window 才能收到 Esc。
final class SystemPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
