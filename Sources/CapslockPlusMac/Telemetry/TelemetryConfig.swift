import Foundation
import Darwin

enum TelemetryPaths {
    static let directory = "/Library/Application Support/CapslockPlusMac"
    static let config = directory + "/telemetry.json"
    static let database = directory + "/telemetry.db"
}

/// 与 capsql-api 约定的配置。字段名必须和服务端工单一致（server_url / token / enabled）。
struct TelemetryConfig {
    let serverURL: String
    let token: String
    let enabled: Bool

    static func load(path: String = TelemetryPaths.config) throws -> TelemetryConfig? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(TelemetryConfig.self, from: data)
    }
}

extension TelemetryConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case token
        case enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decode(String.self, forKey: .serverURL)
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverURL, forKey: .serverURL)
        try container.encode(token, forKey: .token)
        try container.encode(enabled, forKey: .enabled)
    }
}

enum TelemetryRuntime {
    static let version = "0.5.0"

    static var hostname: String {
        ProcessInfo.processInfo.hostName
    }

    static var hardware: String {
        var mib: [Int32] = [CTL_HW, HW_MODEL]
        var size = 0
        guard sysctl(&mib, 2, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 2, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    static var os: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion)"
    }
}
