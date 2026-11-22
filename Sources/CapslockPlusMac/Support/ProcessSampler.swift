import Foundation
import Darwin

/// 一个进程的瞬时状态
struct ProcessSample {
    let pid: pid_t
    let name: String
    var cpu: Double          // 百分比，100 = 一个核心跑满（和活动监视器一致，可超过 100）
    var memory: UInt64       // 字节，优先用 phys_footprint（活动监视器同口径）
    /// 该进程正在监听的 TCP 端口（已去重、升序）；空表示没有监听
    var ports: [UInt16] = []
    /// CPU/内存是否有权限读取。root 进程读不到，但名字和端口照样能拿到
    var measurable: Bool = true
}

/// 采集进程列表。
///
/// 三个实测出来的坑：
///   1. `ri_user_time` / `ri_system_time` 不是纳秒，是 mach absolute time 的 tick
///      （这台机器 timebase 125/3，直接用 1e9 除会小 41.67 倍，WebKit 会显示成 0.2%）。
///   2. root 进程读 `proc_pid_rusage` 会失败（实测 205 个进程里 54 个被拒），
///      但 `proc_pidinfo(PROC_PIDTASKINFO)` 对它们有效 —— 所以要做降级，
///      否则 WindowServer、kernel_task 这些真正吃 CPU 的会凭空消失。
///   3. `pti_total_user` 与 rusage 同单位（都是 tick），不是有些人以为的纳秒。
final class ProcessSampler {
    /// 上一次采样里"读不到指标"的进程数（root 拥有的那些）。
    /// 公开出来是因为界面上要如实说明"共 N 个进程，其中 M 个无权限读取"，
    /// 而不是假装系统里只有 N-M 个进程。
    private(set) var unreadableCount = 0

    /// 端口不需要 2 秒扫一次（几乎不变），按 `portScanEvery` 降频，其余采样用缓存
    private static let portScanEvery = 4
    private var portCache: [pid_t: [UInt16]] = [:]
    private var portScanTick = 0

    /// 进程名缓存：名字几乎不变，pid 复用极少，每轮重新 proc_pidpath + 建 String 是纯浪费
    /// （实测把常驻内存从 74MB 压到 45MB 左右）
    private var nameCache: [pid_t: String] = [:]

    private var previous: [pid_t: UInt64] = [:]     // pid -> 累计 CPU tick
    private var previousAt: UInt64 = 0
    private var timebase = mach_timebase_info_data_t()

    init() {
        mach_timebase_info(&timebase)
    }

    private func toNanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// 返回按 CPU 降序的进程列表；第一次调用时所有 CPU 都是 0（没有上一次样本可比）
    func sample() -> [ProcessSample] {
        // 坑：`proc_listallpids` 的返回值是 **pid 个数**，不是字节数；
        // 按字节除会只拿到 1/4 的进程（实测 838 个进程只显示 209 个，
        // 端口扫描也因此一个都扫不到）。这里改用语义明确的 `proc_listpids`。
        let capacity = 8192
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                  Int32(capacity * MemoryLayout<pid_t>.size))
        let count = max(Int(bytes) / MemoryLayout<pid_t>.size, 0)
        guard count > 0 else { return [] }

        let now = mach_absolute_time()
        let elapsedNs = previousAt == 0 ? 0 : Double(toNanoseconds(now &- previousAt))
        var nextTicks: [pid_t: UInt64] = [:]
        var results: [ProcessSample] = []
        var unreadable = 0

        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }

            // 名字和端口能读、CPU/内存可能读不到（root 进程），三者分别降级，
            // 绝不能因为读不到 CPU 就把整行丢掉 —— 那样 nginx:8080 会凭空消失
            let stats = stats(for: pid)
            if let stats {
                nextTicks[pid] = stats.cpuTicks
            } else {
                unreadable += 1
            }

            var cpu = 0.0
            if let stats, elapsedNs > 0, let last = previous[pid], stats.cpuTicks >= last {
                let deltaNs = Double(toNanoseconds(stats.cpuTicks - last))
                cpu = deltaNs / elapsedNs * 100
            }
            results.append(ProcessSample(pid: pid, name: stats?.name ?? cachedName(pid), cpu: cpu,
                                         memory: stats?.memory ?? 0,
                                         ports: ports(for: pid),
                                         measurable: stats != nil))
        }

        previous = nextTicks
        previousAt = now
        unreadableCount = unreadable
        if nameCache.count > nextTicks.count {
            nameCache = nameCache.filter { nextTicks[$0.key] != nil }
        }
        if portScanTick % Self.portScanEvery == 0 { refreshPortCache(results) }
        portScanTick &+= 1
        return results.sorted { $0.cpu > $1.cpu }
    }

    private struct Stats {
        let name: String
        let cpuTicks: UInt64
        let memory: UInt64
    }

    private func stats(for pid: pid_t) -> Stats? {

        // 首选 rusage：能拿到 phys_footprint（这是活动监视器"内存"那一列的口径）
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, 4, rebound)   // RUSAGE_INFO_V4
            }
        }
        if usageResult == 0 {
            return Stats(name: cachedName(pid),
                         cpuTicks: usage.ri_user_time &+ usage.ri_system_time,
                         memory: usage.ri_phys_footprint)
        }

        // 降级：root 进程走 PROC_PIDTASKINFO（只有常驻内存，颗粒度差一点但比没有好）
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Stats(name: cachedName(pid),
                     cpuTicks: info.pti_total_user &+ info.pti_total_system,
                     memory: info.pti_resident_size)
    }

    /// 枚举该进程的 socket fd，挑出状态为 LISTEN 的 TCP 端口。
    ///
    /// 实测要点（macOS 27 / Apple Silicon）：
    ///   - `PROC_PIDLISTFDS` / `PROC_PIDFDSOCKETINFO` 同样对 root 进程 EPERM，所以只覆盖自己的用户
    ///   - 端口在 `insi_lport` 里是网络序、按小端读出来是"字节反的"（8080 → 36895），必须 byteSwapped
    ///   - 同一个进程常有 IPv4/IPv6 两组 fd 监听同一端口，要按端口去重
    /// 全量扫一遍约 5ms（200 多个进程），2 秒一次可以接受，不需要单独降频。
    private func ports(for pid: pid_t) -> [UInt16] {
        if portScanTick % Self.portScanEvery == 0 {
            return listeningPorts(of: pid)
        }
        return portCache[pid] ?? []
    }

    private func refreshPortCache(_ list: [ProcessSample]) {
        portCache = Dictionary(uniqueKeysWithValues: list.map { ($0.pid, $0.ports) })
    }

    private func listeningPorts(of pid: pid_t) -> [UInt16] {
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                                Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.size
        guard count > 0 else { return [] }

        var ports = Set<UInt16>()
        let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)

        for index in 0..<count {
            let fd = fds[index]
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize else { continue }
            guard info.psi.soi_kind == SOCKINFO_TCP else { continue }
            guard info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let raw = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)
            let port = UInt16(bigEndian: raw)
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    private func cachedName(_ pid: pid_t) -> String {
        if let cached = nameCache[pid] { return cached }
        let name = processName(pid)
        nameCache[pid] = name
        return name
    }

    /// 全路径的 basename 比 proc_name 可读（proc_name 会截断到十几个字符）
    fileprivate func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
        }
        var short = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &short, UInt32(short.count)) > 0 {
            return String(cString: short)
        }
        return "pid \(pid)"
    }
}
