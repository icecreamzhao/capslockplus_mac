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

        for start in stride(from: 0, to: payloads.count, by: Self.batchLimit) {
            let end = min(start + Self.batchLimit, payloads.count)
            do {
                let data = try TelemetryPayload.encode(node: node,
                                                       samples: Array(payloads[start..<end]))
                try buffer.enqueue(data, createdAt: now)
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

    private func flush() -> FlushResult {
        var result = FlushResult()
        // 一轮别无限跑；积压很多时下一个 tick 继续追。
        for _ in 0..<20 {
            let now = Date()
            guard uploader.canAttempt(now: now) else { break }
            guard let batches = try? buffer.dequeue(limit: 1),
                  let batch = batches.first else { break }

            switch uploader.upload(batch.payload) {
            case .accepted(let accepted, _, _):
                try? buffer.delete(ids: [batch.id])
                uploader.recordSuccess()
                result.sent += accepted
                result.batches += 1
            case .authFailure:
                result.authFailed = uploader.recordAuthFailure(now: Date())
                return result
            case .rejected(let status, let message):
                // 4xx 不是网络问题，重试也不会变；丢掉并留下线索。
                try? buffer.delete(ids: [batch.id])
                uploader.recordSuccess()
                result.batches += 1
                result.error = "dropped status=\(status) \(message)"
            case .transient(let message):
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
