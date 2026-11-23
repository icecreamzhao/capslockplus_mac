import Foundation
import Darwin

/// 不依赖网络和真实配置；SQLite 只用在临时目录里。
enum TelemetrySelftest {
    static func run() -> Int32 {
        var checks = 0
        var failures: [String] = []

        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures.append(label) }
        }

        // 1) 分层节奏。840 个进程，1...30 是 hot，31...40 是持续变化的 active。
        func policyInputs(step: Int) -> [TelemetryPolicy.Input] {
            (1...840).map { index in
                let cpu: Double
                if index <= 30 {
                    cpu = 100
                } else if index <= 40 {
                    cpu = 10 + Double(step)
                } else {
                    cpu = 0
                }
                return TelemetryPolicy.Input(pid: pid_t(index),
                                             cpu: cpu,
                                             rss: 100 * 1024 * 1024,
                                             netRx: UInt64(index),
                                             netTx: 0)
            }
        }

        let hot = Set((1...30).map { pid_t($0) })
        let hotAndActive = Set((1...40).map { pid_t($0) })

        var policy = TelemetryPolicy()
        let firstTick = policy.duePIDs(now: 0, samples: policyInputs(step: 1))
        check(firstTick.count == 840, "first tick sends all 840 processes")

        // tick=2（60 秒）：active 还没到 5 分钟窗口，只有 hot。
        let secondTick = Set(policy.duePIDs(now: 60, samples: policyInputs(step: 2)))
        check(secondTick == hot, "second tick sends only hot processes")

        // tick=60（5 分钟）：hot + active。
        let fiveMinutes = Set(policy.duePIDs(now: 300, samples: policyInputs(step: 3)))
        check(fiveMinutes == hotAndActive, "5-minute tick sends hot + active")

        // tick=360（30 分钟）：idle 心跳，全部。
        let thirtyMinutes = policy.duePIDs(now: 1800, samples: policyInputs(step: 4))
        check(thirtyMinutes.count == 840, "30-minute tick sends all (idle heartbeat)")

        // 2) CPU 变化阈值 0.5。
        let base = TelemetryPolicy.Input(pid: 7, cpu: 10, rss: 1_000_000, netRx: 0, netTx: 0)
        check(!TelemetryPolicy.changeDetected(
            previous: base,
            current: TelemetryPolicy.Input(pid: 7, cpu: 10.4, rss: 1_000_000, netRx: 0, netTx: 0)),
              "cpu delta 0.4 is not a change")
        check(TelemetryPolicy.changeDetected(
            previous: base,
            current: TelemetryPolicy.Input(pid: 7, cpu: 10.6, rss: 1_000_000, netRx: 0, netTx: 0)),
              "cpu delta 0.6 is a change")

        // 3)/4) payload 裁剪。
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let futureStart = now.addingTimeInterval(3600)
        let sample = TelemetryPayload.make(TelemetrySampleInput(pid: 42,
                                                                ppid: 1,
                                                                name: "test",
                                                                startedAt: futureStart,
                                                                ts: now,
                                                                cpu: -5,
                                                                threads: 100_000))
        let tsDate = TelemetryPayload.parseTimestamp(sample.ts)
        let startDate = TelemetryPayload.parseTimestamp(sample.startedAt)
        check(tsDate != nil && startDate != nil && startDate! <= tsDate!,
              "started_at is clamped to ts")
        check(sample.ts.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil,
              "timestamps carry a numeric timezone offset")
        check(sample.threads == 32767, "threads is clamped to 32767")
        check(sample.cpu == 0, "negative cpu is clamped to 0")

        // 5) argv 缓存按 pid 隔离。
        var argvCache = ArgvCache()
        let cacheStart = Date(timeIntervalSince1970: 1000)
        let argvA = argvCache.argv(for: 10, now: cacheStart) { ["same"] }
        let argvB = argvCache.argv(for: 20, now: cacheStart) { ["same"] }
        _ = argvCache.argv(for: 10, now: cacheStart.addingTimeInterval(1), maxAge: 0.5) { ["changed"] }
        let refreshedA = argvCache.argv(for: 10, now: cacheStart.addingTimeInterval(1)) { ["poison"] }
        let cachedB = argvCache.argv(for: 20, now: cacheStart.addingTimeInterval(1)) { ["poison"] }
        check(argvA == ["same"] && argvB == ["same"], "argv cache seeds both pids")
        check(refreshedA == ["changed"], "argv refresh applies to its own pid")
        check(cachedB == ["same"], "argv refresh for one pid does not poison another")

        // 6) SQLite 队列 FIFO + 容量淘汰。
        let directory = NSTemporaryDirectory() + "capslockplus-telemetry-selftest-\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        do {
            let fifo = try TelemetryBuffer(path: directory + "/fifo.db")
            try fifo.enqueue(Data("aaa".utf8), createdAt: Date(timeIntervalSince1970: 100))
            try fifo.enqueue(Data("bbb".utf8), createdAt: Date(timeIntervalSince1970: 101))
            try fifo.enqueue(Data("ccc".utf8), createdAt: Date(timeIntervalSince1970: 102))
            let rows = try fifo.dequeue(limit: 10)
            let texts = rows.map { String(data: $0.payload, encoding: .utf8) ?? "" }
            check(texts == ["aaa", "bbb", "ccc"], "buffer returns batches in FIFO order")
            let fifoCount = try fifo.count()
            check(fifoCount == 3, "buffer count is 3 before delete")
            if let oldest = rows.first {
                try fifo.delete(ids: [oldest.id])
            }
            let fifoCountAfterDelete = try fifo.count()
            check(fifoCountAfterDelete == 2, "buffer delete removes exactly one batch")

            let capped = try TelemetryBuffer(path: directory + "/capped.db")
            try capped.enqueue(Data(repeating: 1, count: 10), createdAt: Date(timeIntervalSince1970: 100))
            try capped.enqueue(Data(repeating: 2, count: 10), createdAt: Date(timeIntervalSince1970: 101))
            try capped.enqueue(Data(repeating: 3, count: 10), createdAt: Date(timeIntervalSince1970: 102))
            let removed = try capped.prune(maxBytes: 25,
                                           maxAge: 30 * 24 * 60 * 60,
                                           now: Date(timeIntervalSince1970: 200))
            check(removed == 1, "capacity prune removes the oldest batch")
            let remaining = try capped.dequeue(limit: 10)
            check(remaining.count == 2 && remaining.first?.payload.first == 2,
                  "capacity prune keeps the newer batches")
        } catch {
            checks += 1
            failures.append("buffer selftest threw: \(error)")
        }

        if failures.isEmpty {
            print("telemetry selftest OK (\(checks) assertions)")
            return 0
        }
        for failure in failures {
            print("telemetry selftest FAIL: \(failure)")
        }
        print("telemetry selftest FAILED (\(failures.count)/\(checks))")
        return 1
    }
}
