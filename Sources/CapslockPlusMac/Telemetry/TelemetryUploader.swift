import Foundation
import Dispatch

enum TelemetryUploadOutcome {
    case accepted(accepted: Int, inserted: Int, dropped: Int)
    case authFailure
    case rejected(status: Int, message: String)
    case transient(String)
}

enum TelemetryUploaderError: Error, CustomStringConvertible {
    case invalidServerURL(String)

    var description: String {
        switch self {
        case .invalidServerURL(let value): return "invalid server_url: \(value)"
        }
    }
}

/// 同步 POST 一批 JSON，并维护退避状态。
/// 分类：2xx 成功；401 由人处理（10 分钟冷却）；其他 4xx 永久拒绝；5xx/网络错误退避重试。
final class TelemetryUploader {
    private let endpoint: URL
    private let token: String
    private let session: URLSession

    private var consecutiveFailures = 0
    private var nextAttempt = Date.distantPast
    private var authLogged = false

    init(config: TelemetryConfig) throws {
        guard let endpoint = Self.endpoint(serverURL: config.serverURL) else {
            throw TelemetryUploaderError.invalidServerURL(config.serverURL)
        }
        self.endpoint = endpoint
        self.token = config.token

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        session = URLSession(configuration: configuration)
    }

    func canAttempt(now: Date) -> Bool {
        now >= nextAttempt
    }

    func recordSuccess() {
        consecutiveFailures = 0
        nextAttempt = .distantPast
        authLogged = false
    }

    /// 返回本次退避秒数。
    @discardableResult
    func recordFailure(now: Date) -> TimeInterval {
        consecutiveFailures += 1
        let delay = min(60 * pow(2, Double(consecutiveFailures - 1)), 15 * 60)
        nextAttempt = now.addingTimeInterval(delay)
        return delay
    }

    /// 返回 true 表示这是本轮 auth 失败里第一次该打 AUTH_FAILED。
    @discardableResult
    func recordAuthFailure(now: Date) -> Bool {
        let first = !authLogged
        authLogged = true
        nextAttempt = now.addingTimeInterval(10 * 60)
        return first
    }

    func upload(_ payload: Data) -> TelemetryUploadOutcome {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        let box = Box(.transient("no response"))
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)

        session.dataTask(with: request) { data, response, error in
            let outcome = Self.classify(data: data, response: response, error: error)
            lock.lock()
            box.value = outcome
            lock.unlock()
            semaphore.signal()
        }.resume()

        let completed = semaphore.wait(timeout: .now() + .seconds(75)) == .success
        lock.lock()
        let outcome = completed ? box.value : .transient("timeout")
        lock.unlock()
        return outcome
    }

    private static func classify(data: Data?, response: URLResponse?, error: Error?) -> TelemetryUploadOutcome {
        if let error {
            return .transient(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            return .transient("missing HTTP response")
        }
        let status = http.statusCode
        if (200..<300).contains(status) {
            let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            return .accepted(accepted: body?["accepted"] as? Int ?? 0,
                             inserted: body?["inserted"] as? Int ?? 0,
                             dropped: body?["dropped"] as? Int ?? 0)
        }
        if status == 401 {
            return .authFailure
        }
        if (400..<500).contains(status) {
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return .rejected(status: status,
                             message: String(text.prefix(200)))
        }
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return .transient("HTTP \(status) \(text.prefix(120))")
    }

    private static func endpoint(serverURL: String) -> URL? {
        guard var components = URLComponents(string: serverURL) else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/v1/samples"
        return components.url
    }

    private final class Box {
        var value: TelemetryUploadOutcome
        init(_ value: TelemetryUploadOutcome) { self.value = value }
    }
}
