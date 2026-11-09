import Foundation

/// 日志：O_APPEND 打开，单次 write 由内核保证原子追加。
/// 原来用 FileHandle 各进程各持偏移量，App 和 CLI 子命令同时写会把两行搅在一起
/// （实测出现过 "inputsource changed -> com.apple.2026-11-09T16:07:39Z [I] imeRestart …"）。
final class Log {
    static let shared = Log()

    let fileURL: URL
    private let lock = NSLock()
    private var fd: Int32 = -1
    private let formatter: ISO8601DateFormatter

    private init() {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        fileURL = logsDir.appendingPathComponent("CapslockPlusMac.log")
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        formatter = f
        openFile()
    }

    private func openFile() {
        if fd >= 0 { return }
        fd = Darwin.open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    func ensureFile() {
        lock.lock()
        defer { lock.unlock() }
        openFile()
    }

    func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        openFile()
        guard fd >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let n = Darwin.write(fd, base.advanced(by: written), buffer.count - written)
                if n <= 0 { return }
                written += n
            }
        }
    }
}

extension Log {
    static func info(_ message: String) { shared.write("I", message) }
    static func warn(_ message: String) { shared.write("W", message) }
    static func error(_ message: String) { shared.write("E", message) }
}
