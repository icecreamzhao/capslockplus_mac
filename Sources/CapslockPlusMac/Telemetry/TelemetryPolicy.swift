import Foundation
import Darwin

/// 分层上报的纯决策逻辑：给定这一刻的进程指标和过去的发送记录，决定这轮发谁。
/// 不做 IO，不依赖 ProcessSampler，自检可以直接构造输入。
struct TelemetryPolicy {
    static let hotCount = 30
    static let cpuDelta = 0.5
    static let rssDelta: Double = 8 * 1024 * 1024
    static let activeInterval: TimeInterval = 5 * 60
    static let idleInterval: TimeInterval = 30 * 60

    struct Input {
        let pid: pid_t
        let cpu: Double
        let rss: UInt64
        let netRx: UInt64
        let netTx: UInt64
    }

    private struct State {
        var cpu: Double
        var rss: UInt64
        var netRx: UInt64
        var netTx: UInt64
        var lastSentAt: TimeInterval?
        /// 上次发送之后有没有变化过；避免"第 2 分钟变了一下，第 5 分钟又稳定了"被漏掉。
        var dirty: Bool
    }

    private var states: [pid_t: State] = [:]
    private var hasBaseline = false

    static func changeDetected(previous: Input, current: Input) -> Bool {
        if abs(current.cpu - previous.cpu) > cpuDelta { return true }
        let rssDifference = current.rss >= previous.rss
            ? Double(current.rss - previous.rss)
            : Double(previous.rss - current.rss)
        if rssDifference > rssDelta { return true }
        return current.netRx > previous.netRx || current.netTx > previous.netTx
    }

    /// now 是 Unix 秒。返回本轮应该上报的 pid。
    mutating func duePIDs(now: TimeInterval, samples: [Input]) -> [pid_t] {
        let sorted = samples.sorted {
            $0.cpu == $1.cpu ? $0.pid < $1.pid : $0.cpu > $1.cpu
        }
        let hot = Set(sorted.prefix(Self.hotCount).map { $0.pid })

        var due: [pid_t] = []
        if !hasBaseline {
            due = samples.map { $0.pid }
        } else {
            for sample in sorted {
                if hot.contains(sample.pid) {
                    due.append(sample.pid)
                    continue
                }
                guard let previous = states[sample.pid] else {
                    // 新进程：先发一条建立基线
                    due.append(sample.pid)
                    continue
                }
                let elapsed = previous.lastSentAt.map { now - $0 }
                let changed = previous.dirty || Self.changeDetected(
                    previous: Input(pid: sample.pid,
                                    cpu: previous.cpu,
                                    rss: previous.rss,
                                    netRx: previous.netRx,
                                    netTx: previous.netTx),
                    current: sample)
                if changed {
                    if elapsed == nil || (elapsed ?? 0) >= Self.activeInterval {
                        due.append(sample.pid)
                    }
                } else if elapsed == nil || (elapsed ?? 0) >= Self.idleInterval {
                    due.append(sample.pid)
                }
            }
        }

        let dueSet = Set(due)
        var next: [pid_t: State] = [:]
        next.reserveCapacity(samples.count)
        for sample in samples {
            var state = states[sample.pid] ?? State(cpu: sample.cpu,
                                                    rss: sample.rss,
                                                    netRx: sample.netRx,
                                                    netTx: sample.netTx,
                                                    lastSentAt: nil,
                                                    dirty: false)
            if let previous = states[sample.pid],
               Self.changeDetected(previous: Input(pid: sample.pid,
                                                   cpu: previous.cpu,
                                                   rss: previous.rss,
                                                   netRx: previous.netRx,
                                                   netTx: previous.netTx),
                                   current: sample) {
                state.dirty = true
            }
            state.cpu = sample.cpu
            state.rss = sample.rss
            state.netRx = sample.netRx
            state.netTx = sample.netTx
            if dueSet.contains(sample.pid) {
                state.lastSentAt = now
                state.dirty = false
            }
            next[sample.pid] = state
        }
        states = next
        hasBaseline = true
        return due
    }
}
