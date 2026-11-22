import Foundation
import Darwin

/// 一个进程的瞬时状态
struct ProcessSample {
    let pid: pid_t
    let name: String
    var cpu: Double          // 百分比，100 = 一个核心跑满（和活动监视器一致，可超过 100）
    var memory: UInt64       // 字节，优先用 phys_footprint（活动监视器同口径）
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
        let capacity = 4096
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
        let count = max(Int(bytes) / MemoryLayout<pid_t>.size, 0)
        guard count > 0 else { return [] }

        let now = mach_absolute_time()
        let elapsedNs = previousAt == 0 ? 0 : Double(toNanoseconds(now &- previousAt))
        var nextTicks: [pid_t: UInt64] = [:]
        var results: [ProcessSample] = []

        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }

            guard let stats = stats(for: pid) else { continue }
            nextTicks[pid] = stats.cpuTicks

            var cpu = 0.0
            if elapsedNs > 0, let last = previous[pid], stats.cpuTicks >= last {
                let deltaNs = Double(toNanoseconds(stats.cpuTicks - last))
                cpu = deltaNs / elapsedNs * 100
            }
            results.append(ProcessSample(pid: pid, name: stats.name, cpu: cpu, memory: stats.memory))
        }

        previous = nextTicks
        previousAt = now
        return results.sorted { $0.cpu > $1.cpu }
    }

    private struct Stats {
        let name: String
        let cpuTicks: UInt64
        let memory: UInt64
    }

    private func stats(for pid: pid_t) -> Stats? {
        let name = processName(pid)

        // 首选 rusage：能拿到 phys_footprint（这是活动监视器"内存"那一列的口径）
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, 4, rebound)   // RUSAGE_INFO_V4
            }
        }
        if usageResult == 0 {
            return Stats(name: name,
                         cpuTicks: usage.ri_user_time &+ usage.ri_system_time,
                         memory: usage.ri_phys_footprint)
        }

        // 降级：root 进程走 PROC_PIDTASKINFO（只有常驻内存，颗粒度差一点但比没有好）
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Stats(name: name,
                     cpuTicks: info.pti_total_user &+ info.pti_total_system,
                     memory: info.pti_resident_size)
    }

    /// 全路径的 basename 比 proc_name 可读（proc_name 会截断到十几个字符）
    private func processName(_ pid: pid_t) -> String {
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
