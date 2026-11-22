import Foundation

/// 网卡名字翻译：`en2` 这种名字对用户没有意义，翻译成「雷雳2」「Wi-Fi」「以太网」。
///
/// 数据源是系统的 `networksetup -listallhardwareports`，输出形如：
///   Hardware Port: Thunderbolt 2
///   Device: en2
///   Ethernet Address: 36:16:d8:ff:14:c4
/// 只在第一次用到时跑一次（~20ms），之后缓存。查不到就返回 nil，界面退回显示原名。
enum InterfaceNames {
    private static var cache: [String: String]?

    /// device -> 简短的硬件名（"Wi-Fi" / "雷雳2" / "以太网"）
    static func description(for device: String) -> String? {
        ports()[device]
    }

    static func ports() -> [String: String] {
        if let cache { return cache }
        let parsed = parse(runNetworksetup())
        cache = parsed
        return parsed
    }

    private static func runNetworksetup() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.warn("networksetup spawn failed: \(error.localizedDescription)")
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var pending: String?
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") {
                pending = String(line.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:"), let port = pending {
                let device = String(line.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                result[device] = short(port)
                pending = nil
            }
        }
        return result
    }

    /// 系统给的名字太啰嗦（"Ethernet Adapter (en5)"），压成两三个字
    private static func short(_ port: String) -> String {
        if port.hasPrefix("Wi-Fi") { return "Wi-Fi" }
        if port.hasPrefix("Thunderbolt Bridge") { return "雷雳桥" }
        if port.hasPrefix("Thunderbolt") {
            let suffix = port.replacingOccurrences(of: "Thunderbolt", with: "")
                .trimmingCharacters(in: .whitespaces)
            return suffix.isEmpty ? "雷雳" : "雷雳\(suffix)"
        }
        if port.hasPrefix("Ethernet") || port.hasPrefix("USB") || port.hasPrefix("LAN") {
            return "以太网"
        }
        if port.hasPrefix("iPhone") { return "iPhone USB" }
        if port.hasPrefix("Display") { return "显示器网卡" }
        return port
    }
}
