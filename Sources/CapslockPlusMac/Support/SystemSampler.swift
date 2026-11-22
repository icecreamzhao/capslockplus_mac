import Foundation
import Darwin
import IOKit.ps
import SystemConfiguration

/// 网卡分类：菜单栏总量只统计 physical，隧道单独算，避免同一份字节被算两遍
enum InterfaceKind: String {
    case physical        // en*
    case tunnel          // utun* / ipsec*
    case virtual         // bridge* / vmnet* / anpi* / vmenet*
    case hotspot         // ap*
    case wirelessDirect  // awdl* / llw* / nan*

    var label: String {
        switch self {
        case .physical: return "物理"
        case .tunnel: return "隧道"
        case .virtual: return "虚拟"
        case .hotspot: return "热点"
        case .wirelessDirect: return "直连"
        }
    }
}

/// 单个网卡的实时速率（字节/秒）
struct InterfaceRate {
    let name: String
    let kind: InterfaceKind
    let down: Double
    let up: Double
    /// 是否配了 IP（en2/en3 这类雷雳口号平时没地址，不该占着明细那一行）
    let hasAddress: Bool

    /// 给界面用的说明文字：en2 → 雷雳2；查不到就用原名
    var displayName: String {
        InterfaceNames.description(for: name).map { "\(name) \($0)" } ?? name
    }
}

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
    var netDown: Double = 0             // 字节/秒，**只算物理网卡**
    var netUp: Double = 0
    var tunnelDown: Double = 0          // 隧道单独统计：开 VPN 时与物理口是同一份字节，混在一起会翻倍
    var tunnelUp: Double = 0
    var interfaces: [InterfaceRate] = []   // 各网卡明细（按速率降序）
    var hotspotActive = false           // 是否正走热点（ap* 有流量，或默认路由就在热点上）
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
    private var previousInterfaces: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var previousInterfacesAt: Date?

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
        snapshot.interfaces = network.interfaces
        snapshot.netDown = network.physicalDown
        snapshot.netUp = network.physicalUp
        snapshot.tunnelDown = network.tunnelDown
        snapshot.tunnelUp = network.tunnelUp
        snapshot.hotspotActive = network.hotspotActive
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

    /// 逐网卡算速率，并把"物理口"和"隧道"分开汇总。
    ///
    /// 为什么必须分：开 VPN 时同一份字节会同时记在 utun3 和 en0 上，
    /// 全加起来就是双倍；awdl0/llw0（AirDrop、接力）、bridge0（虚拟机）同理。
    /// 菜单栏的总量只取物理口，隧道单独给一个数。
    private func networkRates() -> (interfaces: [InterfaceRate], physicalDown: Double, physicalUp: Double,
                                    tunnelDown: Double, tunnelUp: Double, hotspotActive: Bool) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return ([], 0, 0, 0, 0, false)
        }
        defer { freeifaddrs(addresses) }

        var counters: [String: (rx: UInt64, tx: UInt64, kind: InterfaceKind)] = [:]
        var addressed = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let interface = entry.pointee
            defer { cursor = interface.ifa_next }
            let name = String(cString: interface.ifa_name)
            guard let address = interface.ifa_addr else { continue }
            let family = address.pointee.sa_family
            if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                addressed.insert(name)                 // 有 IP 才算"在用"
                continue
            }
            guard family == UInt8(AF_LINK), let data = interface.ifa_data,
                  let kind = Self.classify(name) else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters[name] = (UInt64(stats.ifi_ibytes), UInt64(stats.ifi_obytes), kind)
        }

        let now = Date()
        defer {
            previousInterfaces = counters.mapValues { ($0.rx, $0.tx) }
            previousInterfacesAt = now
        }
        guard let previousAt = previousInterfacesAt else {
            return ([], 0, 0, 0, 0, false)      // 第一次没有基线
        }
        let elapsed = now.timeIntervalSince(previousAt)
        guard elapsed > 0.2 else { return ([], 0, 0, 0, 0, false) }

        var interfaces: [InterfaceRate] = []
        var physicalDown = 0.0, physicalUp = 0.0, tunnelDown = 0.0, tunnelUp = 0.0
        var hotspotDown = 0.0, hotspotUp = 0.0

        for (name, current) in counters {
            guard let last = previousInterfaces[name] else { continue }
            let down = current.rx >= last.rx ? Double(current.rx - last.rx) / elapsed : 0
            let up = current.tx >= last.tx ? Double(current.tx - last.tx) / elapsed : 0
            interfaces.append(InterfaceRate(name: name, kind: current.kind, down: down, up: up,
                                            hasAddress: addressed.contains(name)))
            switch current.kind {
            case .physical:
                physicalDown += down
                physicalUp += up
            case .tunnel:
                tunnelDown += down
                tunnelUp += up
            case .hotspot:
                hotspotDown += down
                hotspotUp += up
            case .virtual, .wirelessDirect:
                break
            }
        }

        // 热点判定：热点网卡有明显流量，或者默认路由本身就在热点上
        let hotspotActive = hotspotDown + hotspotUp > 4096 || Self.primaryInterface()?.kind == .hotspot

        return (interfaces.sorted { $0.down + $0.up > $1.down + $1.up },
                physicalDown, physicalUp, tunnelDown, tunnelUp, hotspotActive)
    }

    /// 网卡分类：只有 en* 算"物理"，其余各自归类（未知前缀不参与统计）
    private static func classify(_ name: String) -> InterfaceKind? {
        if name.hasPrefix("en") { return .physical }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") { return .tunnel }
        if name.hasPrefix("bridge") || name.hasPrefix("vmnet")
            || name.hasPrefix("vmenet") || name.hasPrefix("anpi") { return .virtual }
        if name.hasPrefix("ap") { return .hotspot }
        if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("nan") { return .wirelessDirect }
        return nil                              // lo0 / gif0 / stf0 等直接忽略
    }

    /// 默认路由所在的网卡（SystemConfiguration，不需要 fork 命令）
    static func primaryInterface() -> (name: String, kind: InterfaceKind)? {
        guard let store = SCDynamicStoreCreate(nil, "CapslockPlus" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any],
              let name = value["PrimaryInterface"] as? String,
              let kind = classify(name) else { return nil }
        return (name, kind)
    }
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
