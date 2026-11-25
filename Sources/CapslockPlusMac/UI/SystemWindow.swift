import AppKit

/// 活动监视器窗口：上半部分是系统总览，下半部分是进程列表（点表头排序）。
///
/// 对齐 Stats 的 CPU 弹窗 / 系统活动监视器的用法：先看总量，再定位"谁在吃 CPU / 内存"。
/// 窗口不自己采样，只订阅 `SystemMonitor` 的结果，避免多一份开销。
final class SystemWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                    NSMenuDelegate {
    static let shared = SystemWindowController()

    private static let localDeviceID = "__local__"
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private static let dataTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    /// 数据时间距今的文案：<1 分钟"刚刚"，然后分钟/小时/天。
    static func ageText(from date: Date, now: Date = Date()) -> String {
        let seconds = max(now.timeIntervalSince(date), 0)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86_400)) 天前"
    }

    private let panel: SystemPanel
    private var cpuBar = NSProgressIndicator()
    private var memBar = NSProgressIndicator()
    private var cpuLabel = NSTextField(labelWithString: "CPU")
    private var memLabel = NSTextField(labelWithString: "内存")
    private var summaryLabel = NSTextField(labelWithString: "")
    private var networkLabel = NSTextField(labelWithString: "")
    private var footerLabel = NSTextField(labelWithString: "")
    private var devicePopUp = NSPopUpButton()
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

    // MARK: 远端设备状态

    /// nil = 本机；非 nil = 远端 hostname
    private var remoteHostname: String?
    private var cachedDevices: [RemoteDevice] = []
    private var remoteRows: [ProcessSample] = []
    /// pid -> instance_id，远端 ⓘ 用
    private var instanceByPid: [pid_t: Int64] = [:]
    private var remoteLastUpdate: Date?
    /// 回退到"最后已知状态"时，这批数据里最新的 last_seen；nil 表示实时数据
    private var remoteDataThrough: Date?
    private var remoteErrorText: String?
    private var remoteTimer: Timer?
    private var remoteGeneration = 0
    private var remoteRequestInFlight = false
    private var deviceRequestInFlight = false
    private var deviceMenuOpen = false
    private var deviceMenuNeedsRebuild = false
    private var suppressDeviceAction = false

    private var remoteDetailInstanceID: Int64 = 0
    private var remoteDetailPid: pid_t = 0
    private var remoteDetailCache: RemoteInstanceDetail?
    private var remoteDetailFallback: ProcessDetail?
    private var remoteDetailLastFetch = Date.distantPast
    private var remoteDetailLoading = false
    private var remoteDetailSerial = 0

    override init() {
        panel = SystemPanel(contentRect: NSRect(x: 0, y: 0, width: 690, height: 560),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        super.init()
        panel.title = "活动监视器"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // 8 列定宽列最小加起来就 458pt，窗口再窄会出现横向溢出
        panel.minSize = NSSize(width: 620, height: 340)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
        if let saved = UserDefaults.standard.string(forKey: "systemWindow.device"),
           !saved.isEmpty, saved != Self.localDeviceID {
            remoteHostname = saved
        }
        buildContent()
        // 网络累计收发来自 nettop 的进程计数，注入到详情面板
        ProcessDetailPanel.shared.extraFieldsProvider = { pid in
            guard let totals = SystemMonitor.shared.processNetworkTotals(for: pid) else { return [] }
            return [.init(label: "累计下载", value: SystemFormat.bytes(totals.down)),
                    .init(label: "累计上传", value: SystemFormat.bytes(totals.up))]
        }
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

        networkLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        networkLabel.textColor = .secondaryLabelColor
        networkLabel.lineBreakMode = .byTruncatingTail
        networkLabel.frame = NSRect(x: padding, y: height - 104, width: width, height: 14)
        networkLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(networkLabel)

        // 设备下拉框单独占一行，放在网络行下方、分隔线上方，
        // 不压 CPU/内存 条，也不压网络行。
        devicePopUp = NSPopUpButton(frame: NSRect(x: padding, y: height - 142, width: 150, height: 22),
                                    pullsDown: false)
        devicePopUp.controlSize = .small
        devicePopUp.font = .systemFont(ofSize: 11)
        devicePopUp.target = self
        devicePopUp.action = #selector(devicePopUpChanged(_:))
        devicePopUp.autoresizingMask = [.minYMargin]
        devicePopUp.menu?.delegate = self
        devicePopUp.menu?.autoenablesItems = false
        content.addSubview(devicePopUp)

        let separator = NSBox(frame: NSRect(x: padding, y: height - 152, width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]
        content.addSubview(separator)

        table = NSTableView()
        table.style = .inset
        table.rowHeight = 20
        // .inset 风格默认 intercellSpacing 是 17pt，6 列白吃掉 85pt，进程名被挤得很窄
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
        // 列宽自己算：内置的几种 autoresizing 风格在"缩到最小时"会留下右侧空白
        // （各列都被压到 minWidth 后多出来的宽度没人接），所以干脆关掉，
        // 由 windowDidResize 把剩余宽度全给"进程"列。
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.sortDescriptors = [NSSortDescriptor(key: "cpu", ascending: false)]

        // ⓘ 放在最左（进程名左边），点开详情；不可排序、不参与宽度伸缩
        let infoColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("info"))
        infoColumn.width = 24
        infoColumn.minWidth = 24
        infoColumn.maxWidth = 24
        infoColumn.title = ""
        infoColumn.resizingMask = []
        table.addTableColumn(infoColumn)

        let nameColumn = addColumn("进程", key: "name", width: 186, alignment: .left, flex: true)
        nameColumn.resizingMask = .autoresizingMask        // 窗口拉宽时只有它能变
        addColumn("CPU", key: "cpu", width: 62, alignment: .right)
        addColumn("内存", key: "memory", width: 82, alignment: .right)
        addColumn("端口", key: "ports", width: 74, alignment: .right)
        addColumn("下载", key: "down", width: 58, alignment: .right)
        addColumn("上传", key: "up", width: 58, alignment: .right)
        addColumn("PID", key: "pid", width: 54, alignment: .right)

        scrollView = NSScrollView(frame: NSRect(x: padding, y: 58, width: width, height: height - 220))
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

        // root 采样按钮：之前把 ⓘ 挪到最左时，按列替换的代码把这段一起吞掉了
        rootButton = NSButton(title: "显示系统进程…", target: self, action: #selector(toggleRootProbe))
        rootButton.bezelStyle = .rounded
        rootButton.controlSize = .small
        rootButton.font = .systemFont(ofSize: 11)
        rootButton.frame = NSRect(x: padding, y: 30, width: 132, height: 22)
        rootButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        content.addSubview(rootButton)

        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.frame = NSRect(x: padding, y: 12, width: width, height: 14)
        footerLabel.autoresizingMask = [.width, .maxYMargin]   // 底部锚定
        content.addSubview(footerLabel)

        rebuildDeviceMenu(cachedDevices)
    }

    /// 把表格剩余宽度都给"进程"列（ⓘ 与其余列定宽）
    private func layoutNameColumn() {
        guard let nameColumn = table.tableColumns.first(where: { $0.identifier.rawValue == "name" }) else { return }
        let fixed = table.tableColumns
            .filter { $0.identifier.rawValue != "name" }
            .reduce(CGFloat(0)) { $0 + max($1.width, $1.minWidth) }
        let spacing = CGFloat(max(table.numberOfColumns - 1, 0)) * table.intercellSpacing.width
        nameColumn.width = max(scrollView.contentSize.width - fixed - spacing, nameColumn.minWidth)
    }

    func windowDidResize(_ notification: Notification) {
        layoutNameColumn()
    }

    @discardableResult
    private func addColumn(_ title: String, key: String, width: CGFloat, alignment: NSTextAlignment,
                           flex: Bool = false) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
        column.title = title
        column.width = width
        column.minWidth = key == "name" ? 120 : 50   // 名字列别被压到看不清
        if !flex { column.maxWidth = width }         // 定宽列不给伸缩空间
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
        debugLog("show remote=\(remoteHostname ?? "local") saved=\(UserDefaults.standard.string(forKey: "systemWindow.device") ?? "nil")")
        NSApp.activate(ignoringOtherApps: true)
        positionIfNeeded()

        if remoteHostname == nil {
            // 关掉菜单栏读数的人也可能会开这个窗口，所以按需拉起采样
            if !SystemMonitor.shared.isRunning {
                SystemMonitor.shared.start(sampleMs: Config.shared.systemSampleMs)
            }
            RootProbe.setViewing(true)
            installLocalObserver()
            refresh()
        } else {
            // 远端模式：不启动本地采样，也不拉起 root 代理
            removeLocalObserver()
            RootProbe.setViewing(false)
            rootButton.isEnabled = false
            updateRemoteChrome()
        }

        panel.makeKeyAndOrderFront(nil)
        layoutNameColumn()

        // 窗口一出现就拉一次设备列表：否则下拉框里只有"记住的那台 · 连接中"这个占位项，
        // 要等到用户展开菜单才会变成真实的 last_seen。deviceRequestInFlight 已防重复。
        loadDevices()

        if remoteHostname != nil {
            startRemoteTimer()
            fetchRemote()
        }
    }

    func hide() {
        debugLog("hide remote=\(remoteHostname ?? "local")")
        removeLocalObserver()
        remoteTimer?.invalidate()
        remoteTimer = nil
        remoteGeneration &+= 1
        remoteRequestInFlight = false
        RootProbe.setViewing(false)
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

    private func installLocalObserver() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: SystemMonitor.didUpdate, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    private func removeLocalObserver() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    // MARK: - 设备下拉框

    /// 临时诊断（工单 06）：定位"远端模式被打回本机"。
    /// 只有 `defaults write <bundle-id> debugDeviceMenu -bool true` 时才写；
    /// 文件不存在就创建，写失败静默忽略，绝不影响界面。
    private func debugLog(_ message: String, stack: Bool = false) {
        guard UserDefaults.standard.bool(forKey: "debugDeviceMenu") else { return }
        var text = "[\(Date())] \(message)\n"
        if stack {
            for symbol in Thread.callStackSymbols.prefix(8) {
                text += "    \(symbol)\n"
            }
        }
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/CapslockPlusDevice.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            if let data = text.data(using: .utf8) {
                try? data.write(to: url)
            }
        }
    }

    /// 唯一写 `systemWindow.device` 的入口：先记一条带调用栈的日志再落盘。
    private func storeDevice(_ value: String) {
        debugLog("write device=\(value)", stack: true)
        UserDefaults.standard.set(value, forKey: "systemWindow.device")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === devicePopUp.menu else { return }
        // 每次展开都按当前时间重算「上次上报距今」。
        // 这里**不能**整表重建：菜单正在展开时把 item 全删了重建，AppKit 对 item 的身份/索引
        // 记录会错位，点击可能被解析成第 0 项（本机），表现为"选了 ubuntu 又跳回本机"。
        // 就地更新标题/颜色，item 身份保持稳定。
        updateDeviceMenuInPlace(cachedDevices)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === devicePopUp.menu else { return }
        debugLog("menuWillOpen")
        deviceMenuOpen = true
        deviceMenuNeedsRebuild = false
        // 每次展开都异步刷一次设备列表（不做常驻轮询）
        loadDevices()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === devicePopUp.menu else { return }
        debugLog("menuDidClose needsRebuild=\(deviceMenuNeedsRebuild)")
        deviceMenuOpen = false
        if deviceMenuNeedsRebuild {
            deviceMenuNeedsRebuild = false
            // 必须异步：AppKit 是先调 menuDidClose、**之后**才把用户点击的 action 派发过来，
            // 派发时读的是 popup 的"当前选中项"。如果在这里同步重建并调用
            // selectCurrentInDeviceMenu()，选中项会按还没更新的模式重置成本机，
            // 于是用户点的 ubuntu 被覆盖成本机（日志实证：changed target=__local__ 出现在 rebuild 之后）。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rebuildDeviceMenu(self.cachedDevices)
            }
        }
    }

    @objc private func devicePopUpChanged(_ sender: NSPopUpButton) {
        let changedTarget = (sender.selectedItem?.representedObject as? String) ?? "nil"
        debugLog("changed target=\(changedTarget) suppress=\(suppressDeviceAction) remote=\(remoteHostname ?? "local")", stack: true)
        guard !suppressDeviceAction else { return }
        guard let target = sender.selectedItem?.representedObject as? String else { return }
        if target == (remoteHostname ?? Self.localDeviceID) {
            // 已经是当前模式：只保证显示对齐，绝不再调 selectCurrentInDeviceMenu()——
            // 若 selectItem(at:) 本身也会发 action，这里再选一次就是无限递归。
            debugLog("changed noop target=\(target)")
            return
        }
        if target == Self.localDeviceID {
            switchToLocal()
        } else {
            switchToRemote(hostname: target)
        }
    }

    @objc private func editServer() {
        let alert = NSAlert()
        alert.messageText = "服务器地址"
        alert.informativeText = "capsql-api 的 base URL，例如 \(RemoteClient.defaultBase)"
        alert.alertStyle = .informational

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = RemoteClient.base
        field.placeholderString = RemoteClient.defaultBase
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        defer { selectCurrentInDeviceMenu() }
        guard response == .alertFirstButtonReturn else { return }

        let value = RemoteClient.normalizedBase(field.stringValue)
        let previous = RemoteClient.base
        UserDefaults.standard.set(value, forKey: "telemetry.serverURL")
        guard RemoteClient.base != previous else {
            loadDevices()
            return
        }

        cachedDevices = []
        rebuildDeviceMenu([])
        devicePopUp.toolTip = "服务器 \(RemoteClient.base)"
        loadDevices()

        if remoteHostname != nil {
            remoteGeneration &+= 1
            remoteRequestInFlight = false
            remoteErrorText = nil
            remoteLastUpdate = nil
            remoteDataThrough = nil
            resetRemoteDetail(hidePanel: true)
            displayRowsDirty = true
            _ = rows()
            table.reloadData()
            updateRemoteChrome()
            fetchRemote()
        }
    }

    private func loadDevices() {
        guard !deviceRequestInFlight else { return }
        deviceRequestInFlight = true
        RemoteClient.shared.fetchDevices { [weak self] result in
            guard let self else { return }
            self.deviceRequestInFlight = false
            switch result {
            case .success(let devices):
                self.debugLog("devices loaded n=\(devices.count) menuOpen=\(self.deviceMenuOpen)")
                self.cachedDevices = devices
                self.devicePopUp.toolTip = "服务器 \(RemoteClient.base)"
                if self.deviceMenuOpen {
                    // 菜单展开中不整表替换，避免把用户正在点的菜单掀掉；
                    // 只补新增项、更新已有项，关闭后再整理一遍。
                    self.updateDeviceMenuInPlace(devices)
                    self.deviceMenuNeedsRebuild = true
                } else {
                    self.rebuildDeviceMenu(devices)
                }
            case .failure(let error):
                self.debugLog("devices failed \(RemoteClient.summary(of: error))")
                self.devicePopUp.toolTip = "无法获取设备列表：\(RemoteClient.summary(of: error))"
            }
        }
    }

    private func rebuildDeviceMenu(_ devices: [RemoteDevice]) {
        debugLog("rebuild start devices=\(devices.count) remote=\(remoteHostname ?? "local")")
        let savedTarget = devicePopUp.target
        devicePopUp.target = nil
        suppressDeviceAction = true
        defer {
            devicePopUp.target = savedTarget
            suppressDeviceAction = false
            selectCurrentInDeviceMenu()
            debugLog("rebuild end remote=\(remoteHostname ?? "local") popup=\(devicePopUp.titleOfSelectedItem ?? "nil")")
        }
        guard let menu = devicePopUp.menu else { return }
        menu.removeAllItems()

        let local = NSMenuItem(title: "本机", action: nil, keyEquivalent: "")
        local.representedObject = Self.localDeviceID
        menu.addItem(local)

        var seen = Set<String>()
        for device in devices where !device.hostname.isEmpty && !seen.contains(device.hostname) {
            seen.insert(device.hostname)
            menu.addItem(makeDeviceItem(hostname: device.hostname, device: device))
        }

        // 记住的远端还没出现在列表里（服务器没连上/设备离线）时留一个占位项，
        // 否则下拉框会显示成本机，和实际模式不符。
        if let host = remoteHostname, !seen.contains(host) {
            menu.addItem(makeDeviceItem(hostname: host, device: nil))
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置服务器…", action: #selector(editServer), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
    }

    private func updateDeviceMenuInPlace(_ devices: [RemoteDevice]) {
        debugLog("updateInPlace devices=\(devices.count) remote=\(remoteHostname ?? "local")")
        let savedTarget = devicePopUp.target
        devicePopUp.target = nil
        suppressDeviceAction = true
        defer {
            devicePopUp.target = savedTarget
            suppressDeviceAction = false
            selectCurrentInDeviceMenu()
        }
        guard let menu = devicePopUp.menu else { return }
        var byHost: [String: RemoteDevice] = [:]
        for device in devices where !device.hostname.isEmpty {
            byHost[device.hostname] = device
        }

        var existing = Set<String>()
        for item in menu.items {
            guard let host = item.representedObject as? String, host != Self.localDeviceID else { continue }
            existing.insert(host)
            styleDeviceItem(item, hostname: host, device: byHost[host])
        }

        var insertAt = menu.items.firstIndex(where: { $0.isSeparatorItem }) ?? menu.items.count
        for device in devices where !device.hostname.isEmpty && !existing.contains(device.hostname) {
            menu.insertItem(makeDeviceItem(hostname: device.hostname, device: device), at: insertAt)
            insertAt += 1
        }
        menu.update()   // 菜单还开着时让新条目立刻重排显示
    }

    private func makeDeviceItem(hostname: String, device: RemoteDevice?) -> NSMenuItem {
        let item = NSMenuItem(title: hostname, action: nil, keyEquivalent: "")
        styleDeviceItem(item, hostname: hostname, device: device)
        return item
    }

    private func styleDeviceItem(_ item: NSMenuItem, hostname: String, device: RemoteDevice?) {
        var text = hostname
        var color = NSColor.labelColor
        if let lastSeen = device?.lastSeen {
            let age = Date().timeIntervalSince(lastSeen)
            text += " · \(RemoteClient.compactAge(age))"
            if age > 600 { color = .disabledControlTextColor }
        } else if device == nil {
            text += " · 连接中"
            color = .secondaryLabelColor
        }
        item.title = text
        item.representedObject = hostname
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: color,
        ])
    }

    private func selectCurrentInDeviceMenu() {
        guard let menu = devicePopUp.menu else { return }
        let target = remoteHostname ?? Self.localDeviceID
        // 程序化选中本身也可能触发 action，而 AppKit 在 selectItem(at:) 派发时
        // sender.selectedItem 可能还是**旧**选中项——那会把刚切好的模式按旧值改回去
        // （表现为"选了 ubuntu，列表也变了，随后又跳回本机"）。
        // 因此选中期间一律摘掉 target + 抑制 action，谁也别想借机改模式。
        let savedTarget = devicePopUp.target
        devicePopUp.target = nil
        suppressDeviceAction = true
        defer {
            devicePopUp.target = savedTarget
            suppressDeviceAction = false
        }
        if let item = menu.items.first(where: { ($0.representedObject as? String) == target }) {
            if let index = menu.items.firstIndex(of: item) {
                devicePopUp.selectItem(at: index)
            }
        } else if !menu.items.isEmpty {
            devicePopUp.selectItem(at: 0)
        }
        debugLog("select target=\(target) got=\(devicePopUp.titleOfSelectedItem ?? "nil")")
    }

    // MARK: - 本机 / 远端切换

    private func switchToLocal() {
        debugLog("switchToLocal from=\(remoteHostname ?? "local")", stack: true)
        storeDevice(Self.localDeviceID)
        let wasRemote = remoteHostname != nil
        remoteHostname = nil
        remoteGeneration &+= 1
        remoteTimer?.invalidate()
        remoteTimer = nil
        remoteRequestInFlight = false
        remoteRows = []
        instanceByPid = [:]
        remoteLastUpdate = nil
        remoteDataThrough = nil
        remoteErrorText = nil
        resetRemoteDetail(hidePanel: true)
        displayRowsDirty = true
        _ = rows()
        table.reloadData()

        summaryLabel.textColor = .secondaryLabelColor
        rootButton.title = "显示系统进程…"
        rootButton.isEnabled = !rootBusy

        if panel.isVisible {
            RootProbe.setViewing(true)
            if !SystemMonitor.shared.isRunning {
                SystemMonitor.shared.start(sampleMs: Config.shared.systemSampleMs)
            }
            installLocalObserver()
            SystemMonitor.shared.sampleNow()
            refresh()
        } else if wasRemote {
            RootProbe.setViewing(false)
        }
        selectCurrentInDeviceMenu()
    }

    private func switchToRemote(hostname: String) {
        debugLog("switchToRemote to=\(hostname) from=\(remoteHostname ?? "local")", stack: true)
        let changed = remoteHostname != hostname
        if changed {
            resetRemoteDetail(hidePanel: true)
            remoteGeneration &+= 1
            remoteRequestInFlight = false
            remoteRows = []
            instanceByPid = [:]
            remoteLastUpdate = nil
            remoteDataThrough = nil
            remoteErrorText = nil
            displayRowsDirty = true
            _ = rows()
            table.reloadData()
        }

        remoteHostname = hostname
        storeDevice(hostname)
        removeLocalObserver()
        RootProbe.setViewing(false)
        rootButton.title = "显示系统进程…"
        rootButton.isEnabled = false
        updateRemoteChrome()

        if panel.isVisible {
            startRemoteTimer()
            fetchRemote()
        }
        selectCurrentInDeviceMenu()
    }

    // MARK: - 远端刷新

    private func startRemoteTimer() {
        remoteTimer?.invalidate()
        guard remoteHostname != nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fetchRemote()
        }
        RunLoop.main.add(timer, forMode: .common)
        remoteTimer = timer
    }

    private func fetchRemote() {
        guard let host = remoteHostname, !remoteRequestInFlight else { return }
        remoteRequestInFlight = true
        let generation = remoteGeneration
        let base = RemoteClient.base
        RemoteClient.shared.fetchProcesses(hostname: host, limit: 500) { [weak self] result in
            guard let self else { return }
            // 先复位在途标记再判 generation：否则切了设备/关了面板后
            // inFlight 永远为 true，定时器再也不刷新（原实现就是这个顺序）
            self.remoteRequestInFlight = false
            guard generation == self.remoteGeneration, self.remoteHostname == host else { return }

            switch result {
            case .success(let processes) where !processes.isEmpty:
                self.applyRemoteProcesses(processes, dataThrough: nil)
            case .success:
                // 实时窗口里没有样本（设备还在补传积压）：再查一次"最后已知状态"。
                // 第二段结束前 remoteRequestInFlight 保持 true，避免定时器插进来。
                self.debugLog("fetchRemote empty, fallback to last known")
                self.remoteRequestInFlight = true
                RemoteClient.shared.fetchProcesses(hostname: host, limit: 500, maxAgeMinutes: 0) { [weak self] result in
                    guard let self else { return }
                    self.remoteRequestInFlight = false
                    guard generation == self.remoteGeneration, self.remoteHostname == host else { return }
                    switch result {
                    case .success(let processes):
                        self.applyRemoteProcesses(processes, dataThrough: processes.compactMap(\.lastSeen).max())
                    case .failure(let error):
                        // 第一段已经成功，回退查询失败也不该把界面改成"连不上服务器"
                        self.debugLog("fetchRemote fallback failed \(RemoteClient.summary(of: error))")
                        self.applyRemoteProcesses([], dataThrough: nil)
                    }
                }
            case .failure(let error):
                self.debugLog("fetchRemote failed \(RemoteClient.summary(of: error))")
                self.remoteErrorText = "无法连接 \(base)（\(RemoteClient.summary(of: error))）"
                self.updateRemoteChrome()
            }
        }
    }

    private func applyRemoteProcesses(_ processes: [RemoteProcess], dataThrough: Date?) {
        let selectedPID = selectedSample()?.pid
        remoteRows = processes.map { process in
            ProcessSample(pid: process.pid, name: process.name, cpu: process.cpu,
                          memory: process.rss, ports: process.ports, measurable: true,
                          down: process.netRXRate, up: process.netTXRate)
        }
        var mapping: [pid_t: Int64] = [:]
        for process in processes where process.instanceID != 0 {
            mapping[process.pid] = process.instanceID
        }
        instanceByPid = mapping
        remoteLastUpdate = Date()
        remoteDataThrough = dataThrough
        remoteErrorText = nil

        displayRowsDirty = true
        _ = rows()
        table.reloadData()
        if let pid = selectedPID, let row = displayRows.firstIndex(where: { $0.pid == pid }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateRemoteChrome()
    }

    private func updateRemoteChrome() {
        guard let host = remoteHostname else { return }
        if let error = remoteErrorText {
            summaryLabel.stringValue = error
            summaryLabel.textColor = .systemRed
        } else if let updated = remoteLastUpdate {
            if let through = remoteDataThrough {
                summaryLabel.stringValue = "远程 \(host) · 数据来自 \(Self.dataTimeFormatter.string(from: through))"
                    + "（\(Self.ageText(from: through))）· \(remoteRows.count) 个进程"
                summaryLabel.textColor = .systemOrange
            } else {
                summaryLabel.stringValue = "远程 \(host) · 刷新于 \(Self.clockFormatter.string(from: updated))"
                    + " · \(remoteRows.count) 个进程"
                summaryLabel.textColor = .secondaryLabelColor
            }
        } else {
            summaryLabel.stringValue = "远程 \(host) · 正在连接…"
            summaryLabel.textColor = .secondaryLabelColor
        }

        cpuBar.doubleValue = 0
        memBar.doubleValue = 0
        cpuLabel.stringValue = "CPU —"
        memLabel.stringValue = "内存 —"
        cpuLabel.toolTip = nil
        memLabel.toolTip = nil

        let down = remoteRows.reduce(0.0) { $0 + $1.down }
        let up = remoteRows.reduce(0.0) { $0 + $1.up }
        networkLabel.stringValue = "网络  Σ ↓\(SystemFormat.compactRate(down)) ↑\(SystemFormat.compactRate(up))"
        networkLabel.toolTip = "\(host) 上全部进程的实时收发合计（远端设备暂不采集网卡明细）"

        rootButton.title = "显示系统进程…"
        rootButton.isEnabled = false
        footerLabel.stringValue = "共 \(remoteRows.count) 个进程 · 远端每 2 秒刷新"
    }

    // MARK: - 刷新

    private func refresh() {
        guard remoteHostname == nil else { return }
        summaryLabel.textColor = .secondaryLabelColor
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

        // 网卡明细：只列"在用"的（有 IP 或有流量），名字翻译成硬件名
        // en2/en3 这类雷雳口号平时没地址也没流量，不该占着这一行
        var networkParts: [String] = []
        let primary = SystemSampler.primaryInterface()?.name
        for item in snapshot.interfaces {
            let active = item.down + item.up > 0
            let isPrimary = item.name == primary
            // 物理口按"有没有 IP"判断在用；隧道/虚拟/热点只在真有流量时才提
            // （utun* 一般都带 IPv6 link-local 地址，按地址判会一次性刷出七八条）
            let relevant: Bool
            switch item.kind {
            case .physical: relevant = item.hasAddress || isPrimary || active
            case .tunnel, .hotspot: relevant = active || isPrimary
            case .virtual, .wirelessDirect: relevant = active
            }
            guard relevant else { continue }
            guard networkParts.count < 3 else { break }
            let marker = isPrimary ? "★" : ""
            networkParts.append("\(item.displayName)\(marker) ↓\(SystemFormat.compactRate(item.down)) ↑\(SystemFormat.compactRate(item.up))")
        }
        networkLabel.stringValue = networkParts.isEmpty ? "网络  —" : "网络  " + networkParts.joined(separator: "   ")

        // 悬停看全部网卡：未启用的也列出来，并标出类型
        var tooltip: [String] = ["网卡（★ = 默认路由）"]
        for item in snapshot.interfaces {
            switch item.kind {
            case .physical, .tunnel, .hotspot: break
            case .virtual, .wirelessDirect:
                guard item.down + item.up > 0 else { continue }   // 虚拟口没流量就不列
            }
            let status = item.hasAddress ? "" : "·未启用"
            let primaryMark = item.name == primary ? "★ " : ""
            tooltip.append("\(primaryMark)\(item.displayName)  \(item.kind.label)\(status)"
                           + "  ↓\(SystemFormat.rate(item.down)) ↑\(SystemFormat.rate(item.up))")
        }
        networkLabel.toolTip = tooltip.joined(separator: "\n")

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
        let list = currentProcesses()
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
        case "down":
            displayRows = list.sorted { sortAscending ? $0.down < $1.down : $0.down > $1.down }
        case "up":
            displayRows = list.sorted { sortAscending ? $0.up < $1.up : $0.up > $1.up }
        case "info":
            break                                   // ⓘ 列不可排序
        default:
            displayRows = list.sorted { sortAscending ? $0.cpu < $1.cpu : $0.cpu > $1.cpu }
        }
        displayRowsDirty = false
    }

    private func currentProcesses() -> [ProcessSample] {
        remoteHostname == nil ? SystemMonitor.shared.processes : remoteRows
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

    /// 自检用：网卡明细那一行的实际文本
    var debugNetworkLine: String { networkLabel.stringValue }

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
            + " rootBtn=\(rootButton.superview != nil ? "1" : "0")@\(Int(rootButton.frame.minY))"
            + " tableW=\(Int(scrollView.frame.width))"
            + " cols=[" + table.tableColumns.map { "\($0.identifier.rawValue):\(Int($0.width))" }.joined(separator: " ") + "]"
            + " tableFrameW=\(Int(table.frame.width)) contentW=\(Int(scrollView.contentSize.width))"
            + " spacing=\(table.intercellSpacing.width) sumW=\(Int(table.tableColumns.reduce(0) { $0 + $1.width }))"
            + " sort=\(sortKey)\(sortAscending ? "asc" : "desc")"
    }

    /// 自检用：重建设备菜单并返回当前模式、选中标题和行数。
    @discardableResult
    func debugRebuildMenuForTest() -> (mode: String, popup: String, rows: Int) {
        rebuildDeviceMenu(cachedDevices)
        return (remoteHostname ?? "local", devicePopUp.titleOfSelectedItem ?? "nil", displayRows.count)
    }

    // MARK: - 进程详情

    /// 先用本地权限读一份立刻显示（毫秒级）；root 代理在跑时再异步补全
    /// （root 才能读到别人的启动时间/启动参数/工作目录）
    @objc private func showProcessDetail(_ sender: InfoButton) {
        let pid = sender.pid
        if sender.instanceID != 0 {
            showRemoteDetail(instanceID: sender.instanceID, pid: pid)
            return
        }
        // 远端行缺 instance_id 时宁可报错，也不能回落到本机同 pid 的进程
        if remoteHostname != nil {
            showRemoteDetailMissing(pid: pid)
            return
        }
        guard pid > 0 else { return }
        resetRemoteDetail(hidePanel: false)
        ProcessDetailPanel.shared.show(ProcessInspector.inspect(pid: pid))
        guard SystemMonitor.shared.rootActive else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let detail = RootProbe.detailFromAgent(pid: pid) else { return }
            DispatchQueue.main.async { [weak self] in
                // 等 root 回答期间可能已经切到远端设备，别把本机详情灌进远端面板
                guard let self, self.remoteHostname == nil else { return }
                ProcessDetailPanel.shared.update(detail)
            }
        }
    }

    // MARK: - 远端详情

    private func showRemoteDetail(instanceID: Int64, pid: pid_t) {
        guard remoteHostname != nil else { return }
        let name = remoteRows.first(where: { $0.pid == pid })?.name ?? "pid \(pid)"
        let placeholder = ProcessDetail(pid: pid, fields: [
            .init(label: "名称", value: name),
            .init(label: "PID", value: "\(pid)"),
            .init(label: "读取", value: "正在读取远端详情…"),
        ])

        remoteDetailInstanceID = instanceID
        remoteDetailPid = pid
        remoteDetailCache = nil
        remoteDetailFallback = placeholder
        remoteDetailLastFetch = .distantPast
        remoteDetailLoading = false
        remoteDetailSerial &+= 1

        ProcessDetailPanel.shared.refreshProvider = { [weak self] in
            guard let self else { return nil }
            return self.remoteDetailProvider(instanceID: instanceID)
        }
        ProcessDetailPanel.shared.show(placeholder)
        loadRemoteDetail(instanceID: instanceID, pid: pid, force: true)
    }

    private func showRemoteDetailMissing(pid: pid_t) {
        let name = remoteRows.first(where: { $0.pid == pid })?.name ?? "pid \(pid)"
        let detail = ProcessDetail(pid: pid, fields: [
            .init(label: "名称", value: name),
            .init(label: "PID", value: "\(pid)"),
            .init(label: "读取失败", value: "这条远端记录缺少 instance_id，无法打开详情"),
        ])
        remoteDetailInstanceID = 0
        remoteDetailPid = pid
        remoteDetailCache = nil
        remoteDetailFallback = detail
        // 常驻 provider：即使没有 instance_id，也不能让面板回落去读本机 pid
        ProcessDetailPanel.shared.refreshProvider = { detail }
        ProcessDetailPanel.shared.show(detail)
    }

    /// 详情面板每 2 秒调用一次：只从远端缓存拼字段，永远不碰本机 ProcessInspector。
    /// 缓存超过 2 秒就顺手再拉一次，保证 CPU/流量在面板开着时继续变。
    private func remoteDetailProvider(instanceID: Int64) -> ProcessDetail? {
        guard remoteDetailInstanceID == instanceID, remoteHostname != nil else { return nil }
        loadRemoteDetail(instanceID: instanceID, pid: remoteDetailPid, force: false)
        return remoteDetailCache?.makeProcessDetail() ?? remoteDetailFallback
    }

    private func loadRemoteDetail(instanceID: Int64, pid: pid_t, force: Bool) {
        guard !remoteDetailLoading else { return }
        if !force, Date().timeIntervalSince(remoteDetailLastFetch) < 2 { return }
        remoteDetailLoading = true
        remoteDetailLastFetch = Date()
        remoteDetailSerial &+= 1
        let serial = remoteDetailSerial

        RemoteClient.shared.fetchInstance(id: instanceID) { [weak self] result in
            guard let self else { return }
            guard self.remoteDetailSerial == serial else { return }
            self.remoteDetailLoading = false
            guard self.remoteDetailInstanceID == instanceID, self.remoteHostname != nil else { return }
            guard ProcessDetailPanel.shared.refreshProvider != nil else { return }

            switch result {
            case .success(let detail):
                self.remoteDetailCache = detail
                ProcessDetailPanel.shared.update(detail.makeProcessDetail())
            case .failure(let error):
                let name = self.remoteRows.first(where: { $0.pid == pid })?.name ?? "pid \(pid)"
                let fallback = ProcessDetail(pid: pid, fields: [
                    .init(label: "名称", value: name),
                    .init(label: "PID", value: "\(pid)"),
                    .init(label: "读取失败", value: RemoteClient.summary(of: error)),
                ])
                self.remoteDetailFallback = fallback
                ProcessDetailPanel.shared.update(fallback)
            }
        }
    }

    private func resetRemoteDetail(hidePanel: Bool) {
        if hidePanel { ProcessDetailPanel.shared.hide() }
        ProcessDetailPanel.shared.refreshProvider = nil
        remoteDetailInstanceID = 0
        remoteDetailPid = 0
        remoteDetailCache = nil
        remoteDetailFallback = nil
        remoteDetailLastFetch = .distantPast
        remoteDetailLoading = false
        remoteDetailSerial &+= 1
    }

    // MARK: - root 采样按钮

    /// 授权流程进行中（系统密码框弹着），期间禁掉按钮避免连点
    private var rootBusy = false

    @objc private func toggleRootProbe() {
        guard remoteHostname == nil else { return }
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

        if identifier == "info" {
            let list = rows()
            guard row < list.count else { return nil }
            let cellID = NSUserInterfaceItemIdentifier("cell-info")
            let button: InfoButton
            if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? InfoButton {
                button = reused
            } else {
                button = InfoButton()
                button.identifier = cellID
                button.isBordered = false
                button.bezelStyle = .inline
                button.imagePosition = .imageOnly
                button.target = self
                button.action = #selector(showProcessDetail(_:))
                if let symbol = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "进程详情") {
                    button.image = symbol
                } else {
                    button.title = "ⓘ"
                }
                button.contentTintColor = .secondaryLabelColor
            }
            button.pid = list[row].pid
            button.instanceID = instanceByPid[list[row].pid] ?? 0
            button.toolTip = "查看 \(list[row].name) 的详情"
            return button
        }
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
        case "down":
            cell.stringValue = sample.down > 0 ? SystemFormat.compactRate(sample.down) : ""
            cell.textColor = sample.down > 0 ? .systemTeal : .secondaryLabelColor
        case "up":
            cell.stringValue = sample.up > 0 ? SystemFormat.compactRate(sample.up) : ""
            cell.textColor = sample.up > 0 ? .systemPurple : .secondaryLabelColor
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

/// 表格里的 ⓘ 按钮：记住自己那一行是哪个 pid（cell 复用，每次都要重置）
final class InfoButton: NSButton {
    var pid: pid_t = 0
    /// 远端设备进程的 instance_id；0 表示本机
    var instanceID: Int64 = 0
}

/// Esc 关闭。LSUIElement 应用要能成 key window 才能收到 Esc。
final class SystemPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
