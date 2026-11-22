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
    private let queue = DispatchQueue(label: "capslock.sysmon", qos: .utility)
    private var timer: Timer?

    /// 每次采样完成回调（主线程）
    var onUpdate: ((SystemSnapshot) -> Void)?

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

    private func sampleNow() {
        queue.async { [weak self] in
            guard let self else { return }
            let fresh = self.sampler.sample()
            DispatchQueue.main.async {
                self.snapshot = fresh
                self.onUpdate?(fresh)
            }
        }
    }

    // MARK: - 菜单栏紧凑读数

    /// "12% · 68%"；关闭或还没采到数据时返回空串
    var readoutText: String {
        guard isRunning, !snapshot.sampledAt.timeIntervalSince1970.isZero else { return "" }
        return "\(SystemFormat.percent(snapshot.cpu)) · \(SystemFormat.percent(snapshot.memPercent))"
    }

    /// 悬停提示：比标题多给一点上下文
    var readoutToolTip: String {
        guard isRunning else { return "Capslock+" }
        return "CPU \(SystemFormat.percent(snapshot.cpu))"
            + " · 内存 \(SystemFormat.percent(snapshot.memPercent))"
            + " · 负载 \(String(format: "%.2f", snapshot.load1))"
    }

    // MARK: - 菜单里那一节

    /// 顺序固定，界面按这个顺序渲染；取不到值的条目直接不出现（不显示 "未知" 占位）
    func menuLines() -> [(title: String, value: String)] {
        let snap = snapshot
        let cores = ProcessInfo.processInfo.processorCount
        var lines: [(String, String)] = []

        lines.append(("CPU", "\(SystemFormat.percent(snap.cpu))（\(cores) 核）"))
        lines.append(("内存", "\(SystemFormat.bytes(snap.memUsed)) / \(SystemFormat.bytes(snap.memTotal))"
            + "（\(SystemFormat.percent(snap.memPercent))）"))
        lines.append(("负载", String(format: "%.2f · %.2f · %.2f", snap.load1, snap.load5, snap.load15)))
        lines.append(("运行时间", SystemFormat.duration(snap.uptime)))
        if snap.diskTotal > 0 {
            lines.append(("磁盘", "剩余 \(SystemFormat.bytes(snap.diskFree)) / \(SystemFormat.bytes(snap.diskTotal))"))
        }
        lines.append(("网络", "↓ \(SystemFormat.rate(snap.netDown)) · ↑ \(SystemFormat.rate(snap.netUp))"))
        if let percent = snap.batteryPercent {
            var text = "\(percent)%"
            if snap.batteryCharging { text += " · 充电中" }
            if let health = snap.batteryHealth { text += " · 健康 \(health)%" }
            if let cycles = snap.batteryCycles { text += " · 循环 \(cycles) 次" }
            lines.append(("电池", text))
        }
        if let temperature = snap.cpuTemp {
            lines.append(("温度", String(format: "%.0f °C", temperature)))
        }
        if snap.fanCount > 0, let rpm = snap.fanRPM {
            lines.append(("风扇", "\(rpm) rpm（\(snap.fanCount) 个）"))
        }
        return lines
    }
}
