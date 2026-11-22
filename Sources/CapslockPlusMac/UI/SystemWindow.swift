import AppKit

/// 活动监视器窗口：上半部分是系统总览，下半部分是进程列表（点表头排序）。
///
/// 对齐 Stats 的 CPU 弹窗 / 系统活动监视器的用法：先看总量，再定位"谁在吃 CPU / 内存"。
/// 窗口不自己采样，只订阅 `SystemMonitor` 的结果，避免多一份开销。
final class SystemWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SystemWindowController()

    private let panel: SystemPanel
    private var cpuBar = NSProgressIndicator()
    private var memBar = NSProgressIndicator()
    private var cpuLabel = NSTextField(labelWithString: "CPU")
    private var memLabel = NSTextField(labelWithString: "内存")
    private var summaryLabel = NSTextField(labelWithString: "")
    private var footerLabel = NSTextField(labelWithString: "")
    private var table = NSTableView()
    private var scrollView = NSScrollView()
    private var observer: NSObjectProtocol?

    /// 当前排序；默认按 CPU 降序（和系统活动监视器一致）
    private var sortKey = "cpu"
    private var sortAscending = false

    private override init() {
        panel = SystemPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 560),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        super.init()
        panel.title = "活动监视器"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 400, height: 320)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        buildContent()
    }

    // MARK: - 界面

    private func buildContent() {
        let content = panel.contentView!
        let padding: CGFloat = 16
        let width = content.bounds.width - padding * 2
        let height = content.bounds.height

        cpuLabel = metricLabel("CPU")
        memLabel = metricLabel("内存")
        cpuBar = progressBar()
        memBar = progressBar()
        let barX = padding + 66
        cpuLabel.frame = NSRect(x: padding, y: height - 42, width: 66, height: 16)
        cpuBar.frame = NSRect(x: barX, y: height - 39, width: width - 66, height: 10)
        memLabel.frame = NSRect(x: padding, y: height - 66, width: 66, height: 16)
        memBar.frame = NSRect(x: barX, y: height - 63, width: width - 66, height: 10)
        content.addSubview(cpuLabel)
        content.addSubview(cpuBar)
        content.addSubview(memLabel)
        content.addSubview(memBar)

        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.frame = NSRect(x: padding, y: height - 88, width: width, height: 15)
        content.addSubview(summaryLabel)

        let separator = NSBox(frame: NSRect(x: padding, y: height - 100, width: width, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)

        table = NSTableView()
        table.style = .inset
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.sortDescriptors = [NSSortDescriptor(key: "cpu", ascending: false)]

        addColumn("进程", key: "name", width: 200, alignment: .left)
        addColumn("CPU", key: "cpu", width: 66, alignment: .right)
        addColumn("内存", key: "memory", width: 86, alignment: .right)
        addColumn("PID", key: "pid", width: 60, alignment: .right)

        scrollView = NSScrollView(frame: NSRect(x: padding, y: 34, width: width, height: height - 144))
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        content.addSubview(scrollView)

        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.frame = NSRect(x: padding, y: 14, width: width, height: 14)
        content.addSubview(footerLabel)
    }

    private func addColumn(_ title: String, key: String, width: CGFloat, alignment: NSTextAlignment) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
        column.title = title
        column.width = width
        column.minWidth = 50
        column.headerCell.alignment = alignment
        column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: key == "name")
        table.addTableColumn(column)
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
        // 关掉菜单栏读数的人也可能会开这个窗口，所以按需拉起采样
        if !SystemMonitor.shared.isRunning {
            SystemMonitor.shared.start(sampleMs: Config.shared.systemSampleMs)
        }
        NSApp.activate(ignoringOtherApps: true)
        positionIfNeeded()
        refresh()
        panel.makeKeyAndOrderFront(nil)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: SystemMonitor.didUpdate, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
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

    // MARK: - 刷新

    private func refresh() {
        let snapshot = SystemMonitor.shared.snapshot
        cpuBar.doubleValue = snapshot.cpu
        memBar.doubleValue = snapshot.memPercent
        cpuLabel.stringValue = "CPU \(SystemFormat.percent(snapshot.cpu))"
        memLabel.stringValue = "内存 \(SystemFormat.percent(snapshot.memPercent))"
        cpuLabel.toolTip = "\(ProcessInfo.processInfo.processorCount) 核"
        memLabel.toolTip = "\(SystemFormat.bytes(snapshot.memUsed)) / \(SystemFormat.bytes(snapshot.memTotal))"

        var parts = [String(format: "负载 %.2f", snapshot.load1)]
        if let temperature = snapshot.cpuTemp { parts.append(String(format: "%.0f°C", temperature)) }
        if snapshot.fanCount > 0, let rpm = snapshot.fanRPM {
            parts.append(rpm == 0 ? "风扇停转" : "风扇 \(rpm) rpm")
        }
        if let percent = snapshot.batteryPercent {
            parts.append("电池 \(percent)%\(snapshot.batteryCharging ? " 充电中" : "")")
        }
        summaryLabel.stringValue = parts.joined(separator: "  ·  ")

        // 重载时保住选中行（按 pid 定位，进程顺序会随 CPU 变化而变）
        let selectedPID = selectedSample()?.pid
        table.reloadData()
        if let pid = selectedPID, let row = rows().firstIndex(where: { $0.pid == pid }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        let count = SystemMonitor.shared.processes.count
        let age = max(Int(Date().timeIntervalSince(snapshot.sampledAt).rounded()), 0)
        footerLabel.stringValue = "共 \(count) 个进程 · 点表头排序 · 每 \(Config.shared.systemSampleMs / 1000) 秒刷新 · \(age) 秒前"
    }

    /// 按当前排序键输出
    private func rows() -> [ProcessSample] {
        let list = SystemMonitor.shared.processes
        switch sortKey {
        case "name":
            return list.sorted {
                let result = $0.name.localizedStandardCompare($1.name)
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
        case "memory":
            return list.sorted { sortAscending ? $0.memory < $1.memory : $0.memory > $1.memory }
        case "pid":
            return list.sorted { sortAscending ? $0.pid < $1.pid : $0.pid > $1.pid }
        default:
            return list.sorted { sortAscending ? $0.cpu < $1.cpu : $0.cpu > $1.cpu }
        }
    }

    private func selectedSample() -> ProcessSample? {
        let index = table.selectedRow
        let list = rows()
        guard index >= 0, index < list.count else { return nil }
        return list[index]
    }

    /// 自检用：窗口几何、行数、当前排序
    var debugFrame: String {
        let frame = panel.frame
        return "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
            + " visible=\(panel.isVisible ? 1 : 0) rows=\(table.numberOfRows)"
            + " sort=\(sortKey)\(sortAscending ? "asc" : "desc")"
    }

    // MARK: - 表格数据源

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows().count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue else { return nil }
        let list = rows()
        guard row < list.count else { return nil }
        let sample = list[row]

        let cell = NSTextField(labelWithString: "")
        cell.font = identifier == "name"
            ? .systemFont(ofSize: 11)
            : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cell.lineBreakMode = .byTruncatingMiddle
        cell.alignment = identifier == "name" ? .left : .right

        switch identifier {
        case "name":
            cell.stringValue = sample.name
            cell.toolTip = "pid \(sample.pid)"
        case "cpu":
            cell.stringValue = String(format: "%.1f%%", sample.cpu)
            // 超过 10% 标橙、超过 50% 标红，扫一眼就知道谁在抢 CPU
            cell.textColor = sample.cpu >= 50 ? .systemRed : (sample.cpu >= 10 ? .systemOrange : .labelColor)
        case "memory":
            cell.stringValue = SystemFormat.bytes(sample.memory)
        case "pid":
            cell.stringValue = "\(sample.pid)"
            cell.textColor = .secondaryLabelColor
        default:
            cell.stringValue = ""
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        sortKey = key
        sortAscending = descriptor.ascending
        let selectedPID = selectedSample()?.pid
        table.reloadData()
        if let pid = selectedPID, let row = rows().firstIndex(where: { $0.pid == pid }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
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
