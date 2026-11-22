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
    private var rootButton = NSButton()
    private var observer: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    /// 最后一次滚动的时间；滚动中不重载表格，避免用户手指还在滑的时候被整表刷新打断
    private var lastScrollAt = Date.distantPast

    /// 当前排序；默认按 CPU 降序（和系统活动监视器一致）
    private var sortKey = "cpu"
    private var sortAscending = false

    /// 排序后的行缓存。每次采样/改排序只算一次：
    /// 原来 `rows()` 在 numberOfRows、每个可见 cell、选中行恢复里都会重新排 845 个进程，
    /// 快速滚动时每帧几十次全量排序，主线程直接被吃满。
    private var displayRows: [ProcessSample] = []
    private var displayRowsDirty = true

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
        // 顶部锚定：bottom margin 可变，窗口变高时贴着顶走
        cpuLabel.autoresizingMask = [.minYMargin]
        memLabel.autoresizingMask = [.minYMargin]
        cpuBar.autoresizingMask = [.width, .minYMargin]
        memBar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(cpuLabel)
        content.addSubview(cpuBar)
        content.addSubview(memLabel)
        content.addSubview(memBar)

        summaryLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.frame = NSRect(x: padding, y: height - 88, width: width, height: 15)
        summaryLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(summaryLabel)

        let separator = NSBox(frame: NSRect(x: padding, y: height - 100, width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        content.addSubview(separator)

        table = NSTableView()
        table.style = .inset
        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        // 窗口拉宽时由"进程"列吸收多余空间，其余列保持定宽
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.sortDescriptors = [NSSortDescriptor(key: "cpu", ascending: false)]

        let nameColumn = addColumn("进程", key: "name", width: 200, alignment: .left)
        nameColumn.resizingMask = .autoresizingMask
        addColumn("CPU", key: "cpu", width: 66, alignment: .right)
        addColumn("内存", key: "memory", width: 86, alignment: .right)
        addColumn("端口", key: "ports", width: 84, alignment: .right)
        addColumn("PID", key: "pid", width: 60, alignment: .right)

        rootButton = NSButton(title: "显示系统进程…", target: self, action: #selector(toggleRootProbe))
        rootButton.bezelStyle = .rounded
        rootButton.controlSize = .small
        rootButton.font = .systemFont(ofSize: 11)
        rootButton.frame = NSRect(x: padding, y: 30, width: 132, height: 22)
        content.addSubview(rootButton)

        scrollView = NSScrollView(frame: NSRect(x: padding, y: 58, width: width, height: height - 168))
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]      // 表格区吸收剩下的空间
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
            queue: .main) { [weak self] _ in
            self?.lastScrollAt = Date()
        }
        content.addSubview(scrollView)

        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.frame = NSRect(x: padding, y: 12, width: width, height: 14)
        footerLabel.autoresizingMask = [.width, .maxYMargin]   // 底部锚定
        content.addSubview(footerLabel)
    }

    @discardableResult
    private func addColumn(_ title: String, key: String, width: CGFloat, alignment: NSTextAlignment) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
        column.title = title
        column.width = width
        column.minWidth = key == "name" ? 120 : 50   // 名字列别被压到看不清
        column.headerCell.alignment = alignment
        column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: key == "name")
        table.addTableColumn(column)
        return column
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
        // 正在滚动就别刷新表格（数据仍在后台更新，滚动停下后下一次 tick 会补上）
        guard Date().timeIntervalSince(lastScrollAt) > 0.35 else { return }

        let selectedPID = selectedSample()?.pid
        displayRowsDirty = true
        _ = rows()                       // 先重建缓存，reloadData 期间才不会再排序
        table.reloadData()
        if let pid = selectedPID, let row = displayRows.firstIndex(where: { $0.pid == pid }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        let count = SystemMonitor.shared.processes.count
        let hidden = SystemMonitor.shared.unreadableProcessCount
        let age = max(Int(Date().timeIntervalSince(snapshot.sampledAt).rounded()), 0)
        let rootActive = SystemMonitor.shared.rootActive
        rootButton.title = rootActive ? "停止 root 采样" : "显示系统进程…"
        rootButton.isEnabled = !rootBusy

        var footer = "共 \(count) 个进程"
        if rootActive {
            footer += "（root 采样中：系统进程的 CPU/内存都已包含）"
        } else if hidden > 0 {
            footer += "（\(hidden) 个系统进程只能显示名字/端口，点左下按钮用 root 读取）"
        }
        footer += " · 点表头排序 · 每 \(Config.shared.systemSampleMs / 1000) 秒刷新 · \(age) 秒前"
        footerLabel.stringValue = footer
    }

    /// 按当前排序键排序，结果缓存起来；只有采样更新或改排序才重算
    private func rebuildRows() {
        let list = SystemMonitor.shared.processes
        switch sortKey {
        case "name":
            displayRows = list.sorted {
                let result = $0.name.localizedStandardCompare($1.name)
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
        case "memory":
            displayRows = list.sorted { sortAscending ? $0.memory < $1.memory : $0.memory > $1.memory }
        case "ports":
            // 按端口号排，没监听端口的沉底
            displayRows = list.sorted {
                let left = $0.ports.first.map(Int.init) ?? Int.max
                let right = $1.ports.first.map(Int.init) ?? Int.max
                return sortAscending ? left < right : left > right
            }
        case "pid":
            displayRows = list.sorted { sortAscending ? $0.pid < $1.pid : $0.pid > $1.pid }
        default:
            displayRows = list.sorted { sortAscending ? $0.cpu < $1.cpu : $0.cpu > $1.cpu }
        }
        displayRowsDirty = false
    }

    private func rows() -> [ProcessSample] {
        if displayRowsDirty { rebuildRows() }
        return displayRows
    }

    private func selectedSample() -> ProcessSample? {
        let index = table.selectedRow
        let list = rows()
        guard index >= 0, index < list.count else { return nil }
        return list[index]
    }

    /// 自检用：模拟滚动到底再滚回来，返回每帧耗时（毫秒）。
    /// 用来客观验证"卡不卡"，而不是靠手感描述。
    func debugScrollBench(frames: Int = 120) -> (frameMs: Double, reloadMs: Double) {
        let reloadStart = Date()
        table.reloadData()
        let reloadMs = Date().timeIntervalSince(reloadStart) * 1000

        guard let scroll = panel.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first else {
            return (0, reloadMs)
        }
        let rowCount = max(table.numberOfRows, 1)
        let step = max(table.rowHeight, 1)
        let totalHeight = CGFloat(rowCount) * step
        let maxOffset = max(totalHeight - scroll.contentView.bounds.height, 0)

        let start = Date()
        for index in 0..<frames {
            let fraction = Double(index % 60) / 60.0
            let y = maxOffset * CGFloat(fraction)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            table.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        let elapsed = Date().timeIntervalSince(start) * 1000
        return (elapsed / Double(frames), reloadMs)
    }

    /// 自检用：模拟拖拽改变窗口尺寸（跑一小段 runloop 让布局生效）
    func debugResize(to size: NSSize) {
        panel.setContentSize(size)
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// 自检用：窗口几何、行数、当前排序
    var debugFrame: String {
        let frame = panel.frame
        return "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
            + " visible=\(panel.isVisible ? 1 : 0) rows=\(table.numberOfRows)"
            + " tableW=\(Int(scrollView.frame.width))/colW=\(Int(table.tableColumns.first?.width ?? 0))"
            + " sort=\(sortKey)\(sortAscending ? "asc" : "desc")"
    }

    // MARK: - root 采样按钮

    /// 授权流程进行中（系统密码框弹着），期间禁掉按钮避免连点
    private var rootBusy = false

    @objc private func toggleRootProbe() {
        if SystemMonitor.shared.rootActive {
            RootProbe.stop()
            refresh()
            return
        }

        rootBusy = true
        rootButton.title = "等待授权…"
        rootButton.isEnabled = false
        RootProbe.start { [weak self] error in
            guard let self else { return }
            self.rootBusy = false
            self.rootButton.isEnabled = true
            if let error {
                self.rootButton.title = "显示系统进程…"
                let alert = NSAlert()
                alert.messageText = "没能拿到 root 权限"
                alert.informativeText = error
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好")
                alert.runModal()
            } else {
                self.rootButton.title = "停止 root 采样"
                SystemMonitor.shared.sampleNow()
                self.refresh()
            }
        }
    }

    // MARK: - 表格数据源

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows().count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue else { return nil }
        let list = rows()                // 缓存命中，O(1)
        guard row < list.count else { return nil }
        let sample = list[row]

        // 复用 cell：NSTableView 会把滚出屏幕的视图交回来，
        // 每次新建 NSTextField 在快速滚动时是主要的卡顿来源
        let cellID = NSUserInterfaceItemIdentifier("cell-\(identifier)")
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField {
            cell = reused
            cell.textColor = .labelColor
            cell.toolTip = nil
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = cellID
            cell.font = identifier == "name"
                ? .systemFont(ofSize: 11)
                : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.lineBreakMode = .byTruncatingMiddle
            cell.alignment = identifier == "name" ? .left : .right
        }

        switch identifier {
        case "name":
            cell.stringValue = sample.name
            cell.toolTip = "pid \(sample.pid)"
        case "cpu":
            guard sample.measurable else {
                cell.stringValue = "—"
                cell.textColor = .tertiaryLabelColor
                cell.toolTip = "root 拥有的进程，读 CPU 需要 system-task-ports 权限"
                return cell
            }
            cell.stringValue = String(format: "%.1f%%", sample.cpu)
            // 超过 10% 标橙、超过 50% 标红，扫一眼就知道谁在抢 CPU
            cell.textColor = sample.cpu >= 50 ? .systemRed : (sample.cpu >= 10 ? .systemOrange : .labelColor)
        case "memory":
            guard sample.measurable else {
                cell.stringValue = "—"
                cell.textColor = .tertiaryLabelColor
                return cell
            }
            cell.stringValue = SystemFormat.bytes(sample.memory)
        case "ports":
            // 只显示前两个，多了用 +N 概括，完整列表放 tooltip
            if sample.ports.isEmpty {
                cell.stringValue = ""
            } else {
                let head = sample.ports.prefix(2).map { "\($0)" }.joined(separator: " ")
                cell.stringValue = sample.ports.count > 2 ? "\(head) +\(sample.ports.count - 2)" : head
                cell.textColor = .systemBlue
                cell.toolTip = sample.ports.map { "\($0)" }.joined(separator: ", ")
            }
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
        displayRowsDirty = true
        _ = rows()
        table.reloadData()
        if let pid = selectedPID, let row = displayRows.firstIndex(where: { $0.pid == pid }) {
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
