import Foundation

/// 系统监控的调度层：定时采样、把结果推给菜单栏标题与菜单，并负责"菜单里那一节"的文案。
///
/// 采样放后台队列：SMC 要开 IOKit 连接、getifaddrs 要遍历接口，
/// 万一某个调用卡住，也不能让事件 tap 跟着停（键盘会粘住）。
final class SystemMonitor {
    static let shared = SystemMonitor()

    private(set) var snapshot = SystemSnapshot()
    private(set) var isRunning = false
    private let sampler = SystemSampler()
    private let processSampler = ProcessSampler()
    /// 最近一次进程列表（按 CPU 降序）
    private(set) var processes: [ProcessSample] = []
    /// 读不到指标的进程数（root 拥有的）
    var unreadableProcessCount: Int { processSampler.unreadableCount }

    /// root 代理是否在正常输出
    var rootActive: Bool { RootProbe.isActive }

    /// 把 root 数据合并进本地采样：同 pid 以 root 为准，本地没有的补进来
    private static func merge(local: [ProcessSample], root: [RootProcessRow]) -> [ProcessSample] {
        var byPID: [pid_t: RootProcessRow] = [:]
        for row in root { byPID[row.pid] = row }

        var merged: [ProcessSample] = []
        merged.reserveCapacity(max(local.count, root.count))
        var seen = Set<pid_t>()

        for sample in local {
            seen.insert(sample.pid)
            if let row = byPID[sample.pid] {
                merged.append(ProcessSample(pid: sample.pid, name: row.name, cpu: row.cpu,
                                            memory: row.memory, ports: row.ports, measurable: true))
            } else {
                merged.append(sample)
            }
        }
        for row in root where !seen.contains(row.pid) {
            merged.append(ProcessSample(pid: row.pid, name: row.name, cpu: row.cpu,
                                        memory: row.memory, ports: row.ports, measurable: true))
        }
        return merged.sorted { $0.cpu > $1.cpu }
    }
    private let queue = DispatchQueue(label: "capslock.sysmon", qos: .utility)
    private var timer: Timer?

    /// 每次采样完成（主线程）发通知，窗口和菜单栏各自订阅
    static let didUpdate = Notification.Name("SystemMonitorDidUpdate")

    func start(sampleMs: Int) {
        guard !isRunning else { return }
        isRunning = true
        let interval = max(0.5, Double(sampleMs) / 1000)
        sampleNow()                                  // 立即给一次，菜单栏不用等一个周期
        let ticker = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sampleNow()
        }
        // .common：菜单展开时 run loop 切到事件跟踪模式，用 .default 加进去采样会停
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        Log.info("systemMonitor start interval=\(interval)s")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        Log.info("systemMonitor stop")
    }

    func sampleNow() {
        queue.async { [weak self] in
            guard let self else { return }
            let fresh = self.sampler.sample()
            var list = self.processSampler.sample()
            // root 代理在跑就用它的数据覆盖（它能看到全部进程的 CPU/内存）
            if let rootRows = RootProbe.currentRows(), !rootRows.isEmpty {
                list = Self.merge(local: list, root: rootRows)
            }
            DispatchQueue.main.async {
                self.snapshot = fresh
                self.processes = list
                NotificationCenter.default.post(name: Self.didUpdate, object: fresh)
            }
        }
    }

    // MARK: - 菜单栏紧凑读数

    /// 菜单栏两行读数用的四组数：CPU%、内存%、下行、上行。关闭或还没采到数据时返回 nil
    var readoutParts: (cpu: String, mem: String, down: String, up: String)? {
        guard isRunning, !snapshot.sampledAt.timeIntervalSince1970.isZero else { return nil }
        return (SystemFormat.percent(snapshot.cpu),
                SystemFormat.percent(snapshot.memPercent),
                SystemFormat.compactRate(snapshot.netDown),
                SystemFormat.compactRate(snapshot.netUp))
    }

    /// 悬停提示：比标题多给一点上下文
    var readoutToolTip: String {
        guard isRunning else { return "Capslock+" }
        return "CPU \(SystemFormat.percent(snapshot.cpu))"
            + " · 内存 \(SystemFormat.percent(snapshot.memPercent))"
            + " · 下行 \(SystemFormat.rate(snapshot.netDown))"
            + " · 上行 \(SystemFormat.rate(snapshot.netUp))"
            + " · 负载 \(String(format: "%.2f", snapshot.load1))"
    }

}
