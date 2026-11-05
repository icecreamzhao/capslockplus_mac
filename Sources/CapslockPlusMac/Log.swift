import Foundation

final class Log {
    static let shared = Log()

    let fileURL: URL
    private let lock = NSLock()
    private var handle: FileHandle?
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
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    func ensureFile() {
        lock.lock()
        defer { lock.unlock() }
        if handle == nil {
            openFile()
        }
    }

    func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if handle == nil {
            openFile()
        }
        guard let data = line.data(using: .utf8) else { return }
        try? handle?.write(contentsOf: data)
    }
}

extension Log {
    static func info(_ message: String) { shared.write("I", message) }
    static func warn(_ message: String) { shared.write("W", message) }
    static func error(_ message: String) { shared.write("E", message) }
}
