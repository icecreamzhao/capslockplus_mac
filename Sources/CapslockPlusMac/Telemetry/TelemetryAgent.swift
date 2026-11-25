import Foundation
import Darwin

struct TelemetryNodeInfo: Codable {
    let version: String
    let hostname: String
    let hardware: String
    let os: String

    static func current() -> TelemetryNodeInfo {
        TelemetryNodeInfo(version: TelemetryRuntime.version,
                          hostname: TelemetryRuntime.hostname,
                          hardware: TelemetryRuntime.hardware,
                          os: TelemetryRuntime.os)
    }
}

struct TelemetrySamplePayload: Codable {
    let pid: Int32
    let ppid: Int32
    let name: String
    let user: String?
    let exe: String?
    let argv: [String]
    let startedAt: String
    let ended: Bool
    let ports: [Int]
    let ts: String
    let cpu: Double
    let rss: Int64
    let footprint: Int64
    let threads: Int
    let openFiles: Int
    let netRx: Int64
    let netTx: Int64
    let netRxRate: Int64
    let netTxRate: Int64

    private enum CodingKeys: String, CodingKey {
        case pid, ppid, name, user, exe, argv, ended, ports, ts, cpu, rss, footprint, threads
        case startedAt = "started_at"
        case openFiles = "open_files"
        case netRx = "net_rx"
        case netTx = "net_tx"
        case netRxRate = "net_rx_rate"
        case netTxRate = "net_tx_rate"
    }

    /// 手写 encode：user/exe 读不到时要显式写 null，而不是被 synthesize 成"键不存在"。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pid, forKey: .pid)
        try container.encode(ppid, forKey: .ppid)
        try container.encode(name, forKey: .name)
        try container.encode(user, forKey: .user)
        try container.encode(exe, forKey: .exe)
        try container.encode(argv, forKey: .argv)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(ended, forKey: .ended)
        try container.encode(ports, forKey: .ports)
        try container.encode(ts, forKey: .ts)
        try container.encode(cpu, forKey: .cpu)
        try container.encode(rss, forKey: .rss)
        try container.encode(footprint, forKey: .footprint)
        try container.encode(threads, forKey: .threads)
        try container.encode(openFiles, forKey: .openFiles)
        try container.encode(netRx, forKey: .netRx)
        try container.encode(netTx, forKey: .netTx)
        try container.encode(netRxRate, forKey: .netRxRate)
        try container.encode(netTxRate, forKey: .netTxRate)
    }

    /// 进程退出时补的那条：保留身份（pid/ppid/name/user/exe/argv/started_at/ports），
    /// 计量字段归零，ended = true，ts = 退出时刻。
    func endedCopy(ts: String) -> TelemetrySamplePayload {
        // 服务端要求 started_at <= ts；系统时钟回拨时不要把退出时间写早。
        var endedTS = ts
        if let ended = TelemetryPayload.parseTimestamp(ts),
           let started = TelemetryPayload.parseTimestamp(startedAt),
           ended < started {
            endedTS = startedAt
        }
        return TelemetrySamplePayload(pid: pid,
                                      ppid: ppid,
                                      name: name,
                                      user: user,
                                      exe: exe,
                                      argv: argv,
                                      startedAt: startedAt,
                                      ended: true,
                                      ports: ports,
                                      ts: endedTS,
                                      cpu: 0,
                                      rss: 0,
                                      footprint: 0,
                                      threads: 0,
                                      openFiles: 0,
                                      netRx: 0,
                                      netTx: 0,
                                      netRxRate: 0,
                                      netTxRate: 0)
    }
}

struct TelemetryEnvelope: Codable {
    let agent: TelemetryNodeInfo
    let samples: [TelemetrySamplePayload]
}

struct TelemetrySampleInput {
    var pid: Int32
    var ppid: Int32 = 0
    var name: String
    var user: String? = nil
    var exe: String? = nil
    var argv: [String] = []
    var startedAt: Date? = nil
    var ports: [UInt16] = []
    var ts: Date
    var cpu: Double
    var rss: UInt64 = 0
    var footprint: UInt64 = 0
    var threads: Int = 0
    var openFiles: Int = 0
    var netRx: UInt64 = 0
    var netTx: UInt64 = 0
    var netRxRate: Int64 = 0
    var netTxRate: Int64 = 0
}

enum TelemetryPayload {
    static func make(_ input: TelemetrySampleInput) -> TelemetrySamplePayload {
        // 服务端 422 规则：started_at <= ts、cpu >= 0、threads <= 32767、端口 0..65535。
        let started = min(input.startedAt ?? input.ts, input.ts)
        let cpu = input.cpu.isFinite ? max(0, input.cpu) : 0
        let threads = min(max(input.threads, 0), 32767)
        let openFiles = max(0, input.openFiles)
        let name = input.name.isEmpty ? "pid \(input.pid)" : input.name
        let rxRate = min(max(input.netRxRate, 0), 2_147_483_647)
        let txRate = min(max(input.netTxRate, 0), 2_147_483_647)
        return TelemetrySamplePayload(pid: input.pid,
                                      ppid: input.ppid,
                                      name: name,
                                      user: input.user,
                                      exe: input.exe,
                                      argv: input.argv,
                                      startedAt: timestamp(started),
                                      ended: false,
                                      ports: input.ports.map { Int($0) },
                                      ts: timestamp(input.ts),
                                      cpu: cpu,
                                      rss: Int64(clamping: input.rss),
                                      footprint: Int64(clamping: input.footprint),
                                      threads: threads,
                                      openFiles: openFiles,
                                      netRx: Int64(clamping: input.netRx),
                                      netTx: Int64(clamping: input.netTx),
                                      netRxRate: rxRate,
                                      netTxRate: txRate)
    }

    static func timestamp(_ date: Date) -> String {
        let text = timestampFormatter.string(from: date)
        // 某些时区下 ZZZZZ 会退化成 "Z"；服务端要求明确的 ±hh:mm。
        if text.hasSuffix("Z") {
            return String(text.dropLast()) + "+00:00"
        }
        return text
    }

    static func parseTimestamp(_ text: String) -> Date? {
        timestampFormatter.date(from: text)
    }

    static func encode(node: TelemetryNodeInfo, samples: [TelemetrySamplePayload]) throws -> Data {
        try JSONEncoder().encode(TelemetryEnvelope(agent: node, samples: samples))
    }

    static func encodePretty<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    /// ISO8601 的 "Z" 对 UTC 合法，但服务端要求带偏移，所以用 DateFormatter 的 ZZZZZ 强制 ±hh:mm。
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter
    }()
}

/// 一次采样 + 元数据 + 网络增量。agent 和 --telemetry-once 共用。
final class TelemetryCollector {
    struct Entry {
        let sample: ProcessSample
        let netRx: UInt64
        let netTx: UInt64
        let rxRate: Int64
        let txRate: Int64
    }

    private let sampler = ProcessSampler()
    private let meta = ProcessMeta()
    private var previousNet: [pid_t: (down: UInt64, up: UInt64)] = [:]
    private var previousAt: Date?

    func collect(now: Date) -> [Entry] {
        let samples = sampler.sample()
        let seconds = previousAt.map { max(now.timeIntervalSince($0), 1) } ?? 0

        var current: [pid_t: (down: UInt64, up: UInt64)] = [:]
        var entries: [Entry] = []
        entries.reserveCapacity(samples.count)
        for sample in samples {
            let total = sampler.networkTotals(for: sample.pid) ?? (down: 0, up: 0)
            current[sample.pid] = total
            var rxRate: Int64 = 0
            var txRate: Int64 = 0
            if seconds > 0, let previous = previousNet[sample.pid] {
                if total.down > previous.down {
                    let rate = Double(total.down - previous.down) / seconds
                    rxRate = Int64(min(rate, Double(Int64.max)))
                }
                if total.up > previous.up {
                    let rate = Double(total.up - previous.up) / seconds
                    txRate = Int64(min(rate, Double(Int64.max)))
                }
            }
            entries.append(Entry(sample: sample,
                                 netRx: total.down,
                                 netTx: total.up,
                                 rxRate: rxRate,
                                 txRate: txRate))
        }
        previousNet = current
        previousAt = now
        return entries
    }

    func payload(for entry: Entry, now: Date) -> TelemetrySamplePayload {
        let info = meta.info(for: entry.sample.pid, now: now)
        return TelemetryPayload.make(TelemetrySampleInput(pid: entry.sample.pid,
                                                          ppid: max(0, info.ppid),
                                                          name: entry.sample.name,
                                                          user: info.user,
                                                          exe: info.exe,
                                                          argv: info.argv,
                                                          startedAt: info.startedAt,
                                                          ports: entry.sample.ports,
                                                          ts: now,
                                                          cpu: entry.sample.cpu,
                                                          rss: info.residentBytes,
                                                          footprint: entry.sample.memory,
                                                          threads: info.threads,
                                                          openFiles: info.openFiles,
                                                          netRx: entry.netRx,
                                                          netTx: entry.netTx,
                                                          netRxRate: entry.rxRate,
                                                          netTxRate: entry.txRate))
    }

    /// 与 payload(for:now:) 生成 started_at 的方式保持一致，用来判断 pid 是否被复用。
    func startedAt(for sample: ProcessSample, now: Date) -> String {
        let started = min(meta.info(for: sample.pid, now: now).startedAt ?? now, now)
        return TelemetryPayload.timestamp(started)
    }

    /// 进程消失后丢弃缓存的 pid 身份，避免 pid 复用时读到旧进程的 started_at。
    func forget(pid: pid_t) {
        meta.forget(pid: pid)
    }
}

final class TelemetryAgent {
    private static let tickInterval: TimeInterval = 2
    private static let batchLimit = 5000
    private static let queueByteLimit = 200 * 1024 * 1024
    private static let queueAgeLimit: TimeInterval = 7 * 24 * 60 * 60

    private let node = TelemetryNodeInfo.current()
    private let collector = TelemetryCollector()
    private var mutablePolicy = TelemetryPolicy()
    private let buffer: TelemetryBuffer
    private let uploader: TelemetryUploader
    /// pid -> 最后一次真正发给服务端的 payload，用来在进程消失时补一条 ended 样本。
    /// 复用原 payload 保证 started_at 一字不差（服务端按 (pid, started_at) 认实例）。
    private var lastSent: [pid_t: TelemetrySamplePayload] = [:]

    init(config: TelemetryConfig) throws {
        buffer = try TelemetryBuffer(path: TelemetryPaths.database)
        uploader = try TelemetryUploader(config: config)
    }

    func run() -> Never {
        while true {
            let started = Date()
            autoreleasepool {
                tick(now: started)
            }
            let elapsed = Date().timeIntervalSince(started)
            Thread.sleep(forTimeInterval: max(1, Self.tickInterval - elapsed))
        }
    }

    @discardableResult
    func tick(now: Date = Date()) -> (due: Int, sent: Int) {
        let entries = collector.collect(now: now)
        let inputs = entries.map {
            TelemetryPolicy.Input(pid: $0.sample.pid,
                                  cpu: $0.sample.cpu,
                                  rss: $0.sample.memory,
                                  netRx: $0.netRx,
                                  netTx: $0.netTx)
        }
        let due = mutablePolicy.duePIDs(now: now.timeIntervalSince1970, samples: inputs)
        let dueSet = Set(due)

        var payloads: [TelemetrySamplePayload] = []
        payloads.reserveCapacity(due.count)
        for entry in entries where dueSet.contains(entry.sample.pid) {
            payloads.append(collector.payload(for: entry, now: now))
        }

        let alive = Dictionary(entries.map { ($0.sample.pid, $0.sample) },
                               uniquingKeysWith: { first, _ in first })
        let endedTS = TelemetryPayload.timestamp(now)
        var endedPayloads: [TelemetrySamplePayload] = []
        for (pid, old) in Array(lastSent) {
            if let sample = alive[pid],
               collector.startedAt(for: sample, now: now) == old.startedAt {
                continue
            }
            endedPayloads.append(old.endedCopy(ts: endedTS))
            lastSent.removeValue(forKey: pid)
            // pid 已经消失：丢掉缓存的身份，下次这个 pid 出现时按新进程处理。
            // 否则 pid 复用后 started_at 还是旧值，会一直判成"还活着"。
            collector.forget(pid: pid)
        }

        let outgoing = payloads + endedPayloads
        for start in stride(from: 0, to: outgoing.count, by: Self.batchLimit) {
            let end = min(start + Self.batchLimit, outgoing.count)
            let slice = Array(outgoing[start..<end])
            do {
                let data = try TelemetryPayload.encode(node: node,
                                                       samples: slice)
                try buffer.enqueue(data, createdAt: now)
                for payload in slice where !payload.ended {
                    lastSent[payload.pid] = payload
                }
            } catch {
                Log.warn("telemetry enqueue failed: \(error)")
                break
            }
        }

        var pruned = 0
        do {
            pruned = try buffer.prune(maxBytes: Self.queueByteLimit,
                                      maxAge: Self.queueAgeLimit,
                                      now: now)
        } catch {
            Log.warn("telemetry prune failed: \(error)")
        }

        let before = (try? buffer.stats()) ?? (batches: 0, bytes: 0)
        let line = "telemetry tick samples=\(entries.count) due=\(payloads.count) "
            + "ended=\(endedPayloads.count) "
            + "queued=\(before.batches)/\(before.bytes)B pruned=\(pruned)"
        if pruned > 0 { Log.warn(line) } else { Log.info(line) }

        let result = flush()
        let after = (try? buffer.stats()) ?? (batches: 0, bytes: 0)
        var parts = ["telemetry upload sent=\(result.sent)",
                     "batches=\(result.batches)",
                     "pending=\(after.batches)/\(after.bytes)B"]
        if result.authFailed { parts.append("AUTH_FAILED") }
        if let error = result.error { parts.append("error=\(error)") }
        let uploadLine = parts.joined(separator: " ")
        if result.authFailed || result.error != nil {
            Log.warn(uploadLine)
        } else {
            Log.info(uploadLine)
        }
        return (due: payloads.count, sent: result.sent)
    }

    private struct FlushResult {
        var sent = 0
        var batches = 0
        var authFailed = false
        var error: String?
    }

    private struct MergedBatches {
        var node: TelemetryNodeInfo?
        var samples: [TelemetrySamplePayload] = []
        /// 合并进本次请求、成功后可以删掉的批次。
        var usedIDs: [Int64] = []
        /// 解不出来（或空批次）的批次，直接删掉，免得卡住队列。
        var droppedIDs: [Int64] = []
        var queueEmpty = false
    }

    /// 从 FIFO 里取小批次（每批一个 tick 的样本），解码合并成一次请求。
    /// 只合并整批，样本数达到 batchLimit 或下一批放不下就停；
    /// 没合并进去的批次留在队列里给下一轮，不删。
    private func mergeQueuedBatches(fetchLimit: Int = 100) -> MergedBatches {
        var merged = MergedBatches()
        let decoder = JSONDecoder()
        var stop = false
        while !stop, merged.samples.count < Self.batchLimit {
            let batches: [TelemetryBuffer.StoredBatch]
            do {
                batches = try buffer.dequeue(limit: fetchLimit)
            } catch {
                Log.warn("telemetry dequeue failed: \(error)")
                break
            }
            if batches.isEmpty {
                merged.queueEmpty = true
                break
            }
            for batch in batches {
                guard let envelope = try? decoder.decode(TelemetryEnvelope.self,
                                                         from: batch.payload) else {
                    Log.warn("telemetry drop undecodable batch id=\(batch.id) "
                        + "bytes=\(batch.payload.count)")
                    merged.droppedIDs.append(batch.id)
                    continue
                }
                guard !envelope.samples.isEmpty else {
                    Log.warn("telemetry drop empty batch id=\(batch.id)")
                    merged.droppedIDs.append(batch.id)
                    continue
                }
                if merged.node == nil { merged.node = envelope.agent }

                let room = Self.batchLimit - merged.samples.count
                if envelope.samples.count > room {
                    if merged.samples.isEmpty {
                        // 历史遗留的超大批次：只发 5000 条前缀，否则它会永远堵住队列。
                        Log.warn("telemetry truncate oversized batch id=\(batch.id) "
                            + "samples=\(envelope.samples.count)")
                        merged.samples.append(contentsOf: envelope.samples.prefix(room))
                        merged.usedIDs.append(batch.id)
                    }
                    stop = true
                    break
                }
                merged.samples.append(contentsOf: envelope.samples)
                merged.usedIDs.append(batch.id)
                if merged.samples.count >= Self.batchLimit {
                    stop = true
                    break
                }
            }
        }
        return merged
    }

    private func flush() -> FlushResult {
        var result = FlushResult()
        // 一轮别无限跑；积压很多时下一个 tick 继续追。
        // 这里 20 是合并后的请求数，不是队列批次数。
        for _ in 0..<20 {
            let now = Date()
            guard uploader.canAttempt(now: now) else { break }

            let merged = mergeQueuedBatches()
            if !merged.droppedIDs.isEmpty {
                try? buffer.delete(ids: merged.droppedIDs)
                result.batches += merged.droppedIDs.count
                result.error = "dropped \(merged.droppedIDs.count) undecodable batch(es)"
            }

            guard let node = merged.node, !merged.samples.isEmpty else {
                // 只是丢了坏批次且队列还有内容：继续下一轮；否则收工。
                if merged.queueEmpty || merged.droppedIDs.isEmpty { break }
                continue
            }

            let payload: Data
            do {
                payload = try TelemetryPayload.encode(node: node, samples: merged.samples)
            } catch {
                Log.warn("telemetry encode failed: \(error)")
                result.error = "encode failed: \(error)"
                return result
            }

            switch uploader.upload(payload) {
            case .accepted(let accepted, _, _):
                try? buffer.delete(ids: merged.usedIDs)
                uploader.recordSuccess()
                result.sent += accepted
                result.batches += 1
            case .authFailure:
                result.authFailed = uploader.recordAuthFailure(now: Date())
                return result
            case .rejected(let status, let message):
                // 4xx 不是网络问题，重试也不会变；丢掉并留下线索。
                try? buffer.delete(ids: merged.usedIDs)
                uploader.recordSuccess()
                result.batches += 1
                result.error = "dropped status=\(status) \(message)"
            case .transient(let message):
                // 批次还在队列里，下一个 tick 重新合并重试。
                let delay = uploader.recordFailure(now: Date())
                result.error = "\(message) retry_in=\(Int(delay))s"
                return result
            }
        }
        return result
    }
}

enum TelemetryOnce {
    static func run() -> Int32 {
        // 第一次采样只有基线（CPU/速率都是 0），隔一秒再采一次，样例才有意义。
        let collector = TelemetryCollector()
        _ = collector.collect(now: Date())
        Thread.sleep(forTimeInterval: 1)
        let now = Date()
        let entries = collector.collect(now: now)
        let payloads = entries.map { collector.payload(for: $0, now: now) }
        print("telemetry-once samples=\(payloads.count)")
        guard let sample = payloads.first else {
            print("telemetry-once no processes")
            return 0
        }
        do {
            let data = try TelemetryPayload.encodePretty(sample)
            print(String(data: data, encoding: .utf8) ?? "")
            return 0
        } catch {
            print("telemetry-once encode failed: \(error)")
            return 1
        }
    }
}

enum TelemetryCLI {
    static func run() -> Int32? {
        let arguments = CommandLine.arguments
        if arguments.contains("--telemetry-selftest") {
            return TelemetrySelftest.run()
        }
        if arguments.contains("--telemetry-once") {
            return TelemetryOnce.run()
        }
        if arguments.contains("--telemetry-agent") {
            return runAgent()
        }
        return nil
    }

    private static func runAgent() -> Int32 {
        do {
            guard let config = try TelemetryConfig.load() else { return 0 }
            guard config.enabled else { return 0 }
            guard !config.token.isEmpty else {
                Log.warn("telemetry agent disabled: empty token")
                return 0
            }
            let agent = try TelemetryAgent(config: config)
            agent.run()
        } catch {
            Log.warn("telemetry agent stopped: \(error)")
            return 0
        }
    }
}
