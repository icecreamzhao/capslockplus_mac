import Foundation

// MARK: - capsql-api 数据模型

/// `GET /v1/devices` 的一行
struct RemoteDevice: Decodable {
    let id: String
    let hostname: String
    let hardware: String
    let os: String
    let agentVersion: String
    let lastSeen: Date?
    let instanceCount: Int

    enum CodingKeys: String, CodingKey {
        case id, hostname, hardware, os
        case agentVersion = "agent_version"
        case lastSeen = "last_seen"
        case instanceCount = "instance_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = RemoteDecoding.string(container, .id) ?? ""
        hostname = RemoteDecoding.string(container, .hostname) ?? ""
        hardware = RemoteDecoding.string(container, .hardware) ?? ""
        os = RemoteDecoding.string(container, .os) ?? ""
        agentVersion = RemoteDecoding.string(container, .agentVersion) ?? ""
        lastSeen = RemoteDecoding.date(container, .lastSeen)
        instanceCount = RemoteDecoding.int(container, .instanceCount) ?? 0
    }
}

/// `GET /v1/devices/{hostname}/processes` 的一行
struct RemoteProcess: Decodable {
    let deviceID: String
    let hostname: String
    let instanceID: Int64
    let name: String
    let pid: Int32
    let userName: String?
    let startedAt: Date?
    let exePath: String?
    let ports: [UInt16]
    let lastSeen: Date?
    let cpu: Double
    let rss: UInt64
    let footprint: UInt64?
    let threads: Int
    let openFiles: Int
    let netRX: UInt64
    let netTX: UInt64
    let netRXRate: Double
    let netTXRate: Double

    enum CodingKeys: String, CodingKey {
        case name, pid, ports, cpu, rss, footprint, threads
        case deviceID = "device_id"
        case hostname
        case instanceID = "instance_id"
        case userName = "user_name"
        case startedAt = "started_at"
        case exePath = "exe_path"
        case lastSeen = "last_seen"
        case openFiles = "open_files"
        case netRX = "net_rx"
        case netTX = "net_tx"
        case netRXRate = "net_rx_rate"
        case netTXRate = "net_tx_rate"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = RemoteDecoding.string(container, .deviceID) ?? ""
        hostname = RemoteDecoding.string(container, .hostname) ?? ""
        instanceID = RemoteDecoding.int64(container, .instanceID) ?? 0
        name = RemoteDecoding.string(container, .name) ?? ""
        pid = RemoteDecoding.int32(container, .pid) ?? 0
        userName = RemoteDecoding.optionalString(container, .userName)
        startedAt = RemoteDecoding.date(container, .startedAt)
        exePath = RemoteDecoding.optionalString(container, .exePath)
        ports = RemoteDecoding.ports(container, .ports)
        lastSeen = RemoteDecoding.date(container, .lastSeen)
        cpu = RemoteDecoding.double(container, .cpu) ?? 0
        rss = RemoteDecoding.uint64(container, .rss) ?? 0
        footprint = RemoteDecoding.uint64(container, .footprint)
        threads = RemoteDecoding.int(container, .threads) ?? 0
        openFiles = RemoteDecoding.int(container, .openFiles) ?? 0
        netRX = RemoteDecoding.uint64(container, .netRX) ?? 0
        netTX = RemoteDecoding.uint64(container, .netTX) ?? 0
        netRXRate = RemoteDecoding.double(container, .netRXRate) ?? 0
        netTXRate = RemoteDecoding.double(container, .netTXRate) ?? 0
    }
}

/// `GET /v1/instances/{instance_id}`：进程行 + 父进程、结束时间、启动参数
struct RemoteInstanceDetail: Decodable {
    let process: RemoteProcess
    let ppid: Int32?
    let endedAt: Date?
    let argv: [String]

    enum CodingKeys: String, CodingKey {
        case ppid, argv
        case endedAt = "ended_at"
    }

    init(from decoder: Decoder) throws {
        process = try RemoteProcess(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ppid = RemoteDecoding.int32(container, .ppid)
        endedAt = RemoteDecoding.date(container, .endedAt)
        argv = RemoteDecoding.strings(container, .argv)
    }

    /// 拼成详情面板的字段，顺序对齐本机 `ProcessInspector.inspect` 的观感
    func makeProcessDetail() -> ProcessDetail {
        var fields: [ProcessDetail.Field] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append(.init(label: label, value: value))
        }

        add("名称", process.name)
        add("PID", "\(process.pid)")
        add("父进程 PID", ppid.map { "\($0)" } ?? "—")
        add("用户", process.userName ?? "—")
        add("可执行文件", process.exePath ?? "—")
        if let started = process.startedAt {
            let uptime = Date().timeIntervalSince(started)
            add("启动时间", "\(Self.timestamp(started))（已运行 \(ProcessInspector.duration(uptime))）")
        } else {
            add("启动时间", "—")
        }
        if !argv.isEmpty { add("启动参数", argv.joined(separator: " ")) }
        add("CPU", String(format: "%.1f%%", process.cpu))
        add("内存(RSS)", SystemFormat.bytes(process.rss))
        add("物理内存", process.footprint.flatMap { $0 > 0 ? SystemFormat.bytes($0) : nil } ?? "—")
        add("线程", "\(process.threads)")
        add("打开文件", "\(process.openFiles)")
        add("监听端口", process.ports.isEmpty ? "—" : process.ports.map { "\($0)" }.joined(separator: ", "))
        add("累计下载", SystemFormat.bytes(process.netRX))
        add("累计上传", SystemFormat.bytes(process.netTX))
        add("下载速率", SystemFormat.rate(process.netRXRate))
        add("上传速率", SystemFormat.rate(process.netTXRate))
        if let last = process.lastSeen { add("最后上报时间", Self.timestamp(last)) }
        return ProcessDetail(pid: process.pid, fields: fields, executablePath: nil)
    }

    private static func timestamp(_ date: Date) -> String {
        RemoteTime.displayFormatter.string(from: date)
    }
}

// MARK: - 客户端

final class RemoteClient {
    static let shared = RemoteClient()

    static let defaultBase = "http://192.168.8.101:8787"

    /// base URL：优先 `UserDefaults["telemetry.serverURL"]`，没有就用家里/公司都通的默认地址
    static var base: String {
        normalizedBase(UserDefaults.standard.string(forKey: "telemetry.serverURL") ?? defaultBase)
    }

    static func normalizedBase(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = defaultBase }
        while value.hasSuffix("/") { value.removeLast() }
        if value.isEmpty { value = defaultBase }
        return value
    }

    /// 下拉框里的「上次上报距今」，例如 `8m`
    static func compactAge(_ seconds: TimeInterval) -> String {
        let value = max(Int(seconds), 0)
        if value < 60 { return "\(value)s" }
        if value < 3600 { return "\(value / 60)m" }
        if value < 86_400 { return "\(value / 3600)h" }
        return "\(value / 86_400)d"
    }

    static func summary(of error: Error) -> String {
        if let error = error as? RemoteClientError {
            return error.errorDescription ?? "请求失败"
        }
        if error is DecodingError { return "返回数据格式不符" }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return "请求超时"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return "无法连接主机"
            case .notConnectedToInternet: return "网络不可用"
            case .networkConnectionLost: return "连接中断"
            case .secureConnectionFailed, .serverCertificateUntrusted: return "TLS 校验失败"
            default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        // macOS 默认走系统代理；本机 HTTP_PROXY 指向 192.168.8.1:7890，
        // 内网请求会被代理接走变成 502/超时，所以显式清空代理设置。
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["Accept": "application/json"] as [AnyHashable: Any]
        session = URLSession(configuration: configuration)
    }

    func fetchDevices(completion: @escaping (Result<[RemoteDevice], Error>) -> Void) {
        get("/v1/devices", completion: completion)
    }

    func fetchProcesses(hostname: String, limit: Int = 500,
                        maxAgeMinutes: Int = 40,
                        completion: @escaping (Result<[RemoteProcess], Error>) -> Void) {
        let encoded = Self.encodePathComponent(hostname)
        get("/v1/devices/\(encoded)/processes?limit=\(limit)&max_age_minutes=\(maxAgeMinutes)",
            completion: completion)
    }

    func fetchInstance(id: Int64, completion: @escaping (Result<RemoteInstanceDetail, Error>) -> Void) {
        get("/v1/instances/\(id)", completion: completion)
    }

    // MARK: - 内部

    private func get<T: Decodable>(_ path: String,
                                   completion: @escaping (Result<T, Error>) -> Void) {
        guard let url = URL(string: Self.base + path) else {
            DispatchQueue.main.async { completion(.failure(RemoteClientError.invalidBase)) }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        session.dataTask(with: request) { data, response, error in
            let result: Result<T, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse,
                      !(200..<300).contains(http.statusCode) {
                result = .failure(RemoteClientError.http(http.statusCode))
            } else if let data {
                do {
                    result = .success(try JSONDecoder().decode(T.self, from: data))
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(RemoteClientError.emptyResponse)
            }
            // 所有回调统一回主线程，界面代码不用再切队列
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum RemoteClientError: LocalizedError {
    case invalidBase
    case emptyResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidBase: return "服务器地址无效"
        case .emptyResponse: return "响应为空"
        case .http(let code): return "HTTP \(code)"
        }
    }
}

// MARK: - 宽松解码

/// 服务端的数值有时是数字有时是字符串，时间有 ISO 也有 SQLite 格式；这里统一兜住，
/// 免得一个字段类型变化就让整台设备的进程列表变成空白。
private enum RemoteDecoding {
    static func string<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let value = try? container.decode(String.self, forKey: key) { return value }
        if let value = try? container.decode(Int64.self, forKey: key) { return "\(value)" }
        if let value = try? container.decode(Double.self, forKey: key) { return "\(value)" }
        return nil
    }

    static func optionalString<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
        guard let value = string(container, key), !value.isEmpty else { return nil }
        return value
    }

    static func double<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        int64(container, key).map { Int($0) }
    }

    static func int32<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int32? {
        int64(container, key).map { Int32(truncatingIfNeeded: $0) }
    }

    static func int64<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int64? {
        if let value = try? container.decode(Int64.self, forKey: key) { return value }
        if let value = try? container.decode(Double.self, forKey: key) { return Int64(value) }
        if let value = try? container.decode(String.self, forKey: key) { return Int64(value) }
        return nil
    }

    static func uint64<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> UInt64? {
        guard let value = int64(container, key), value >= 0 else { return nil }
        return UInt64(value)
    }

    static func date<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let text = try? container.decode(String.self, forKey: key) {
            return RemoteTime.parse(text)
        }
        if let number = try? container.decode(Double.self, forKey: key) {
            return RemoteTime.date(epoch: number)
        }
        return nil
    }

    static func ports<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> [UInt16] {
        var values: [UInt16] = []
        if let list = try? container.decode([Int].self, forKey: key) {
            values = list.compactMap { UInt16(exactly: $0) }
        } else if let list = try? container.decode([String].self, forKey: key) {
            values = list.compactMap { UInt16($0) }
        } else if let text = try? container.decode(String.self, forKey: key) {
            values = text.split { !$0.isNumber }.compactMap { UInt16(String($0)) }
        }
        return Array(Set(values)).sorted()
    }

    static func strings<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> [String] {
        if let list = try? container.decode([String].self, forKey: key) { return list }
        if let text = try? container.decode(String.self, forKey: key), !text.isEmpty { return [text] }
        return []
    }
}

private enum RemoteTime {
    static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let localFormats = [
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss.SSSSSS",
        "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
    ]

    static func parse(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let date = isoFractional.date(from: value) { return date }
        if let date = isoPlain.date(from: value) { return date }
        for format in localFormats {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        if let epoch = Double(value) { return date(epoch: epoch) }
        return nil
    }

    static func date(epoch: Double) -> Date {
        // 毫秒时间戳（13 位）和秒时间戳都接受
        let seconds = epoch > 100_000_000_000 ? epoch / 1000 : epoch
        return Date(timeIntervalSince1970: seconds)
    }
}
