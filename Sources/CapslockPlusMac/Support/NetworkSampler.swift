import Foundation

/// 每个进程的网络吞吐（字节/秒）。
///
/// 为什么不用 `proc_pid_rusage`：`rusage_info_v6` 里只有磁盘 IO
/// （`ri_diskio_bytesread/written`），**没有任何网络字节计数字段**，
/// 内核不按进程统计网络流量。
///
/// 可行且不需要特权的办法是调系统的 `nettop`：
///   nettop -P -L 1 -J bytes_in,bytes_out -x -n
/// 输出形如 `mDNSResponder.473,4217037,3505084,` —— 进程名.pid,累计收,累计发。
/// 它给的是累计值，所以速率要自己做两次采样求差（和 CPU 一样的做法）。
/// 实测单次 ~14ms，2 秒一次可以接受。
final class NetworkSampler {
    /// 每个进程的累计收发（nettop 的 bytes_in / bytes_out，进程启动至今）
    private(set) var cumulative: [pid_t: (rx: UInt64, tx: UInt64)] = [:]
    /// 是否至少成功采过一次（用来区分"还没采到"和"这个进程没有 socket"）
    private(set) var hasSampled = false

    private var previous: [pid_t: (rx: UInt64, tx: UInt64)] = [:]
    private var previousAt: Date?

    /// 返回 pid -> (down, up) 字节/秒；第一次调用时全是 0（没有基线）
    func sample() -> [pid_t: (down: Double, up: Double)] {
        let counters = readCounters()
        guard !counters.isEmpty else { return [:] }

        let now = Date()
        var rates: [pid_t: (down: Double, up: Double)] = [:]
        if let previousAt {
            let elapsed = now.timeIntervalSince(previousAt)
            if elapsed > 0.2 {
                for (pid, current) in counters {
                    guard let last = previous[pid] else { continue }
                    let rx = current.rx >= last.rx ? Double(current.rx - last.rx) / elapsed : 0
                    let tx = current.tx >= last.tx ? Double(current.tx - last.tx) / elapsed : 0
                    if rx > 0 || tx > 0 {
                        rates[pid] = (rx, tx)
                    }
                }
            }
        }
        cumulative = counters
        hasSampled = true
        previous = counters
        previousAt = now
        return rates
    }

    /// 跑一次 nettop 并解析出累计计数
    private func readCounters() -> [pid_t: (rx: UInt64, tx: UInt64)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-J", "bytes_in,bytes_out", "-x", "-n"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.warn("nettop spawn failed: \(error.localizedDescription)")
            return [:]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Log.warn("nettop exit=\(process.terminationStatus)")
            return [:]
        }

        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var counters: [pid_t: (rx: UInt64, tx: UInt64)] = [:]
        for line in text.split(separator: "\n") {
            // 头部行是 ",bytes_in,bytes_out,"，跳过
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let identity = String(parts[0])
            guard let dot = identity.lastIndex(of: "."),
                  let pid = pid_t(identity[identity.index(after: dot)...]) else { continue }
            let rx = UInt64(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            let tx = UInt64(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0
            counters[pid] = (rx, tx)
        }
        return counters
    }
}
