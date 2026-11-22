import Foundation
import Darwin
import IOKit.ps

/// 一次采样得到的系统状态。所有字段都是"能算多少算多少"，取不到的留 nil，界面自己决定显不显示。
struct SystemSnapshot {
    var cpu: Double = 0                 // 0...1
    var memUsed: UInt64 = 0
    var memTotal: UInt64 = 0
    var load1: Double = 0
    var load5: Double = 0
    var load15: Double = 0
    var uptime: TimeInterval = 0
    var diskFree: UInt64 = 0
    var diskTotal: UInt64 = 0
    var netDown: Double = 0             // 字节/秒
    var netUp: Double = 0
    var batteryPercent: Int?
    var batteryCharging = false
    var batteryHealth: Int?             // %
    var batteryCycles: Int?
    var cpuTemp: Double?
    var fanRPM: Int?
    var fanCount = 0
    var sampledAt = Date()

    var memPercent: Double {
        memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0
    }
}

/// 采集系统指标。全部走系统框架（mach / sysctl / statfs / getifaddrs / IOKit），不引第三方库。
///
/// CPU 和网络的占用率本质是"两次采样的差"，所以第一次采样必然拿不到速率 ——
/// 这是物理限制，不是 bug：第一次返回 0，第二次起才是真实值。
final class SystemSampler {
    private var previousCPU: (user: UInt32, system: UInt32, nice: UInt32, idle: UInt32)?
    private var previousNet: (down: UInt64, up: UInt64, at: Double)?

    func sample() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.cpu = cpuUsage()
        let memory = memoryUsage()
        snapshot.memUsed = memory.used
        snapshot.memTotal = memory.total
        (snapshot.load1, snapshot.load5, snapshot.load15) = loadAverage()
        snapshot.uptime = ProcessInfo.processInfo.systemUptime
        let disk = diskUsage()
        snapshot.diskFree = disk.free
        snapshot.diskTotal = disk.total
        let network = networkRates()
        snapshot.netDown = network.down
        snapshot.netUp = network.up
        let battery = batteryInfo()
        snapshot.batteryPercent = battery.percent
        snapshot.batteryCharging = battery.charging
        snapshot.batteryHealth = battery.health
        snapshot.batteryCycles = battery.cycles
        snapshot.cpuTemp = SMC.cpuTemperature()
        snapshot.fanCount = SMC.fanCount()
        snapshot.fanRPM = SMC.fanRPM()
        snapshot.sampledAt = Date()
        return snapshot
    }

    // MARK: - CPU

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride
                                           / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let ticks = info.cpu_ticks
        let current = (user: ticks.0, system: ticks.1, nice: ticks.3, idle: ticks.2)
        defer { previousCPU = current }
        guard let previous = previousCPU else { return 0 }

        let user = Double(current.user &- previous.user)
        let system = Double(current.system &- previous.system)
        let nice = Double(current.nice &- previous.nice)
        let idle = Double(current.idle &- previous.idle)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return 0 }
        return min(max(busy / total, 0), 1)
    }

    // MARK: - 内存

    private func memoryUsage() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride
                                           / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total) }

        // 与活动监视器的"已用内存"同口径：活跃 + 联动 + 压缩，扣掉可回收
        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let usedPages = (active + wired + compressed) > purgeable
            ? (active + wired + compressed - purgeable) : 0
        return (min(usedPages * pageSize, total), total)
    }

    // MARK: - 负载 / 磁盘

    private func loadAverage() -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return (0, 0, 0) }
        return (loads[0], loads[1], loads[2])
    }

    private func diskUsage() -> (free: UInt64, total: UInt64) {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return (0, 0) }
        let blockSize = UInt64(stats.f_bsize)
        return (UInt64(stats.f_bavail) * blockSize, UInt64(stats.f_blocks) * blockSize)
    }

    // MARK: - 网络

    private func networkRates() -> (down: Double, up: Double) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let interface = entry.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               let data = interface.ifa_data {
                let name = String(cString: interface.ifa_name)
                if !name.hasPrefix("lo") && !name.hasPrefix("gif") && !name.hasPrefix("stf") {
                    let stats = data.assumingMemoryBound(to: if_data.self).pointee
                    received &+= UInt64(stats.ifi_ibytes)
                    sent &+= UInt64(stats.ifi_obytes)
                }
            }
            cursor = interface.ifa_next
        }

        let now = Date().timeIntervalSince1970
        defer { previousNet = (received, sent, now) }
        guard let previous = previousNet, now > previous.at else { return (0, 0) }
        let elapsed = now - previous.at
        guard elapsed > 0 else { return (0, 0) }
        let downBytes = received >= previous.down ? received - previous.down : 0
        let upBytes = sent >= previous.up ? sent - previous.up : 0
        return (Double(downBytes) / elapsed, Double(upBytes) / elapsed)
    }

    // MARK: - 电池

    private func batteryInfo() -> (percent: Int?, charging: Bool, health: Int?, cycles: Int?) {
        var percent: Int?
        var charging = false

        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
                if let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                   let maximum = description[kIOPSMaxCapacityKey as String] as? Int, maximum > 0 {
                    percent = Int((Double(current) / Double(maximum) * 100).rounded())
                }
                charging = (description[kIOPSIsChargingKey as String] as? Bool) ?? false
                if percent != nil { break }
            }
        }

        // 健康度与循环次数只有 AppleSmartBattery 里有（IOPS 不给这两个）
        var health: Int?
        var cycles: Int?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let properties = unmanaged?.takeRetainedValue() as? [String: Any] {
                // Apple Silicon 把容量指标藏在嵌套的 BatteryData 里，顶层没有 DesignCapacity；
                // Intel 机型则在顶层。两条都试一遍，谁有数据用谁。
                let nested = properties["BatteryData"] as? [String: Any] ?? [:]
                let design = (nested["DesignCapacity"] as? Int) ?? (properties["DesignCapacity"] as? Int) ?? 0
                let raw = (nested["FullChargeCapacity"] as? Int)
                    ?? (nested["AppleRawMaxCapacity"] as? Int)
                    ?? (properties["AppleRawMaxCapacity"] as? Int) ?? 0
                if design > 0, raw > 0 {
                    health = Int((Double(raw) / Double(design) * 100).rounded())
                }
                cycles = (properties["CycleCount"] as? Int) ?? (nested["CycleCount"] as? Int)
                if percent == nil,
                   let current = properties["CurrentCapacity"] as? Int,
                   let maximum = properties["MaxCapacity"] as? Int, maximum > 0 {
                    percent = Int((Double(current) / Double(maximum) * 100).rounded())
                }
                if properties["IsCharging"] as? Bool == true { charging = true }
            }
        }
        return (percent, charging, health, cycles)
    }
}

/// 数值格式化。抽成静态函数是为了能被自检直接断言（不依赖采样）。
enum SystemFormat {
    static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        return index == 0 ? "\(Int(amount)) B" : String(format: "%.1f %@", amount, units[index])
    }

    /// 速率用 1024 进制，和 Finder 一致
    static func rate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "0 KB/s" }
        if bytesPerSecond < 1024 { return "\(Int(bytesPerSecond)) B/s" }
        let kb = bytesPerSecond / 1024
        if kb < 1024 { return String(format: "%.0f KB/s", kb) }
        let mb = kb / 1024
        return mb < 1024 ? String(format: "%.1f MB/s", mb) : String(format: "%.2f GB/s", mb / 1024)
    }

    /// 菜单栏用的紧凑速率：最多 4 个字符（0 / 46K / 4.0M / 999M / 1.2G）
    static func compactRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0" }
        let kb = bytesPerSecond / 1024
        if kb < 10 { return String(format: "%.1fK", kb) }
        if kb < 1024 { return String(format: "%.0fK", kb) }
        let mb = kb / 1024
        if mb < 10 { return String(format: "%.1fM", mb) }
        if mb < 1024 { return String(format: "%.0fM", mb) }
        return String(format: "%.1fG", mb / 1024)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 分钟" }
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分钟" }
        return "\(minutes) 分钟"
    }
}
