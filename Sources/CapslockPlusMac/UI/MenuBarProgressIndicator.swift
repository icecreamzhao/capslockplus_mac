import AppKit

/// 菜单栏进度条的"宿主"：把 `ProgressGlyph` 画出来的图放到 NSStatusItem 上，并管理生命周期。
///
/// 设计成可复用组件而不是"转换专用"：
///   - `begin(label:)` 返回一个句柄，调用方只管 `update` / `end`，不用记 id
///   - 支持并发：多个任务同时跑时，最后开始的占住图标，它结束后自动回到上一个还在跑的任务
///   - 句柄走 ARC，忘调 `end()` 也不会把图标永久霸住（deinit 兜底）
///   - 只依赖 NSStatusItem，任何有状态栏的 macOS 工具都能直接用
///
/// 用法：
/// ```
/// MenuBarProgressIndicator.shared.attach(statusItem)      // App 启动时一次
/// let task = MenuBarProgressIndicator.shared.begin(label: "转换中")
/// task.update(0.42)      // 已知进度
/// task.update(nil)       // 切回不定态滑动动画
/// task.end()             // 结束，图标自动还原（或交还给下一个任务）
/// ```
final class MenuBarProgressIndicator {
    static let shared = MenuBarProgressIndicator()

    /// 一个正在进行的任务。end() 可重复调用（幂等）。
    final class Task {
        fileprivate let id = UUID()
        fileprivate let label: String
        fileprivate weak var owner: MenuBarProgressIndicator?
        private var ended = false

        fileprivate init(label: String, owner: MenuBarProgressIndicator) {
            self.label = label
            self.owner = owner
        }

        /// 0...1 表示确定进度；传 nil 切回滑动动画。
        /// 可以从任意线程调用：UI 操作会切回主线程。
        func update(_ fraction: Double?) {
            guard !ended else { return }
            let identifier = id
            let target = owner            // 强持有：句柄可能在这一行之后就没人引用了
            onMain { target?.update(id: identifier, fraction: fraction) }
        }

        func end() {
            guard !ended else { return }
            ended = true
            let identifier = id
            let target = owner
            onMain { target?.finish(id: identifier) }
        }

        /// 主线程上直接干，后台队列上异步切回主线程（不阻塞转码）。
        /// 注意闭包捕获的是 owner 的强引用，不是 self —— 释放句柄不能把收尾动作一起丢掉。
        private func onMain(_ work: @escaping () -> Void) {
            if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
        }

        deinit {
            // 忘了 end 的情况：至少别把状态栏永久占住。
            // deinit 可能发生在任意线程，UI 收尾必须走主线程，且不能靠弱引用的 self。
            guard !ended else { return }
            ended = true
            let identifier = id
            let target = owner
            if Thread.isMainThread {
                target?.finish(id: identifier)
            } else {
                DispatchQueue.main.async { target?.finish(id: identifier) }
            }
        }
    }

    private struct Entry {
        let id: UUID
        let label: String
        var fraction: Double?
    }

    private weak var item: NSStatusItem?
    private var originalImage: NSImage?
    private var originalToolTip: String?
    private var entries: [Entry] = []
    private var timer: Timer?
    private var phase: Double = 0

    var isActive: Bool { !entries.isEmpty }

    // MARK: - 宿主

    func attach(_ statusItem: NSStatusItem) {
        item = statusItem
        originalImage = statusItem.button?.image
        originalToolTip = statusItem.button?.toolTip
    }

    /// 开始一个任务；同一 label 可以并存多个（各拿各的句柄）。
    @discardableResult
    func begin(label: String) -> Task {
        let task = Task(label: label, owner: self)
        entries.append(Entry(id: task.id, label: label, fraction: nil))
        startTickerIfNeeded()
        render()
        return task
    }

    fileprivate func update(id: UUID, fraction: Double?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].fraction = fraction.map { min(max($0, 0), 1) }
        // 只有最上层的任务在显示；下层只更新数据，轮到它时自然是新值
        guard entries.last?.id == id else { return }
        if entries[index].fraction != nil {
            timer?.invalidate()
            timer = nil
        } else {
            startTickerIfNeeded()
        }
        render()
    }

    fileprivate func finish(id: UUID) {
        entries.removeAll { $0.id == id }
        Log.info("progressBar finish remaining=\(entries.count)")
        if entries.isEmpty {
            stopTicker()
            restore()
        } else {
            // 上层任务结束：露出来的那个继续，按它的形态决定要不要重新起动画
            if entries.last?.fraction == nil { startTickerIfNeeded() } else { stopTicker() }
            render()
        }
    }

    // MARK: - 动画

    private func startTickerIfNeeded() {
        guard timer == nil, item?.button != nil else { return }
        let ticker = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.05
            self.render()
        }
        // .common：菜单展开时 run loop 切到事件跟踪模式，用 .default 加进去动画会停
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    private func stopTicker() {
        timer?.invalidate()
        timer = nil
    }

    private func render() {
        guard let button = item?.button, let top = entries.last else { return }
        button.image = ProgressGlyph.image(fraction: top.fraction, phase: phase)
        button.toolTip = top.fraction.map { "\(top.label) \(Int(($0 * 100).rounded()))%" } ?? top.label
    }

    private func restore() {
        guard let button = item?.button else {
            // CLI / 未 attach 的场景没有状态栏，静默即可
            if item != nil { Log.warn("progressBar restore skipped: no button") }
            return
        }
        Log.info("progressBar restore image=\(originalImage == nil ? "nil" : "ok")")
        button.image = originalImage
        button.toolTip = originalToolTip ?? "Capslock+"
    }
}
