import Foundation

/// root 采样代理写出来的单行数据
struct RootProcessRow: Codable {
    let pid: Int32
    let name: String
    let cpu: Double
    let memory: UInt64
    let ports: [UInt16]
}

/// 用 root 权限采集"系统进程"的 CPU / 内存。
///
/// 为什么需要它：`proc_pid_rusage` 对 root 拥有的进程返回 EPERM，
/// 所以普通权限下 WindowServer、launchd 这类进程只能显示名字和端口。
///
/// 做法：不装 launchd 特权 helper（那要 Developer ID + SMJobBless + 安装器），
/// 第一次点按钮时用 `osascript ... with administrator privileges` 弹系统授权框，
/// 把**自己的可执行文件**以 `--root-agent` 模式后台跑起来。
/// 代理每 2 秒把全量进程数据写进一个 JSON 文件，主进程读文件合并，
/// 这样只弹一次密码，之后不再打扰。
enum RootProbe {
    static let directoryName = "capslock-root-procs"

    static var directory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(directoryName)
    }
    static var dataFile: URL { directory.appendingPathComponent("procs.json") }
    static var stopFile: URL { directory.appendingPathComponent("stop") }
    static var ownerFile: URL { directory.appendingPathComponent("owner.pid") }
    /// 窗口开着才采样：关掉窗口后 root 代理只空转，不烧 CPU
    static var viewingFile: URL { directory.appendingPathComponent("viewing") }
    /// 进程详情请求/响应（走文件，主进程写请求、root 代理写答案）
    static var detailRequestFile: URL { directory.appendingPathComponent("detail.request") }
    static var detailResponseFile: URL { directory.appendingPathComponent("detail.response") }
    static var logFile: URL { directory.appendingPathComponent("agent.log") }

    /// 数据新鲜度阈值：代理 2 秒一轮，超过这个时间就认为它已经没了
    private static let freshSeconds: TimeInterval = 8

    // MARK: - 读取（主进程侧）

    private static var cache: (modified: Date, rows: [RootProcessRow])?
    private static let lock = NSLock()

    /// 代理是否在正常输出数据
    static var isActive: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: dataFile.path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < freshSeconds
    }

    /// 最近一份 root 数据；文件没更新时用缓存，避免每 2 秒重新解析
    static func currentRows() -> [RootProcessRow]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: dataFile.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < freshSeconds else { return nil }

        lock.lock()
        defer { lock.unlock() }
        if let cache, cache.modified == modified { return cache.rows }
        guard let data = try? Data(contentsOf: dataFile),
              let rows = try? JSONDecoder().decode([RootProcessRow].self, from: data) else { return cache?.rows }
        cache = (modified, rows)
        return rows
    }

    // MARK: - 启停（主进程侧）

    /// 拉起 root 代理；completion 在主线程回调，nil 表示成功
    static func start(completion: @escaping (String?) -> Void) {
        guard let executable = Bundle.main.executablePath else {
            completion("找不到可执行文件路径")
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: stopFile)
        // 记录自己的 pid：代理发现主进程没了就自己退出，不留孤儿 root 进程
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(to: ownerFile, atomically: true, encoding: .utf8)

        // 注意：整条命令用单引号包路径，避免 AppleScript 的双引号冲突
        // 既不用 nohup（没有控制终端，nohup 会 "can't detach from console" 后退出），
        // 也不用 &（`do shell script` 结束会带走子进程）。
        // 让代理**前台**跑在 root shell 里：osascript 一直等到代理退出为止，
        // 代理因此始终活着；停止时写 stop 文件 → 代理退出 → shell/osascript 退出。
        let command = "mkdir -p '\(directory.path)' && exec '\(executable)' --root-agent '\(directory.path)'"
        let script = "do shell script \"\(command)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]

            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion("无法启动 osascript: \(error.localizedDescription)") }
                return
            }

            // osascript 会一直挂着（代理在前台跑），所以不能 waitUntilExit，
            // 只能轮询"数据文件有没有出现"；用户取消授权时 osascript 会自己退出。
            var waited = 0.0
            while waited < 10.0 {
                if isActive {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.2)
                waited += 0.2
            }

            if process.isRunning {
                // 代理在跑却没数据：让它退出，免得留一个不干活的 root 进程
                process.terminate()
                DispatchQueue.main.async {
                    completion("代理已启动但没有产出数据。日志：\n\(Self.logTail())")
                }
                return
            }

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reason = message.contains("-128") || message.lowercased().contains("cancel")
                ? "已取消授权"
                : (message.isEmpty ? "授权失败（退出码 \(process.terminationStatus)）" : message)
            DispatchQueue.main.async { completion(reason) }
        }
    }

    /// 最近几行代理日志，报错时直接摆给用户看
    static func logTail(lines: Int = 4) -> String {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return "（无日志）" }
        let tail = text.split(separator: "\n").suffix(lines).joined(separator: "\n")
        return tail.isEmpty ? "（空日志）" : tail
    }

    /// 通过 root 代理取详情（能读 root 进程的启动时间/参数/工作目录）。
    /// 代理不在跑或超时则返回 nil，调用方退回本地权限的版本。
    static func detailFromAgent(pid: Int32, timeout: TimeInterval = 2.5) -> ProcessDetail? {
        guard isActive else { return nil }
        let seq = Date().timeIntervalSince1970
        let request = ProcessDetail(pid: pid, fields: [], executablePath: nil, seq: seq)
        guard let payload = try? JSONEncoder().encode(request) else { return nil }
        try? FileManager.default.removeItem(at: detailResponseFile)
        guard (try? payload.write(to: detailRequestFile, options: .atomic)) != nil else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: detailResponseFile),
               let detail = try? JSONDecoder().decode(ProcessDetail.self, from: data),
               detail.seq == seq, detail.pid == pid {
                try? FileManager.default.removeItem(at: detailResponseFile)
                return detail
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try? FileManager.default.removeItem(at: detailRequestFile)
        return nil
    }

    /// 窗口显示/隐藏时调用，告诉 root 代理要不要真干活
    static func setViewing(_ viewing: Bool) {
        if viewing {
            try? "1".write(to: viewingFile, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: viewingFile)
        }
    }

    /// 让代理自己退出（普通权限即可：代理在读 stop 文件）
    static func stop() {
        try? "stop".write(to: stopFile, atomically: true, encoding: .utf8)
        lock.lock()
        cache = nil
        lock.unlock()
    }

    // MARK: - 代理侧

    /// `--root-agent <dir>`：循环采样写 JSON，直到 stop 文件出现或主进程消失
    static func runAgent(directory path: String) -> Int32 {
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func log(_ message: String) {
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            let file = directory.appendingPathComponent("agent.log")
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                try? handle.close()
            } else {
                try? line.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        guard getuid() == 0 else {
            log("agent abort: not root")
            return 1
        }
        log("agent start uid=0 pid=\(ProcessInfo.processInfo.processIdentifier)")

        let stopFile = directory.appendingPathComponent("stop")
        let dataFile = directory.appendingPathComponent("procs.json")
        let ownerFile = directory.appendingPathComponent("owner.pid")

        var ownerPID: Int32 = 0
        if let text = try? String(contentsOf: ownerFile, encoding: .utf8) {
            ownerPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        let sampler = ProcessSampler()
        _ = sampler.sample()                       // 建立 CPU 基线
        var written = 0
        var failures = 0
        var nextSampleAt = Date()
        let viewingFile = directory.appendingPathComponent("viewing")
        let requestFile = directory.appendingPathComponent("detail.request")
        let responseFile = directory.appendingPathComponent("detail.response")

        // 250ms 一轮：详情请求要秒回，采样仍按 2 秒节奏
        while true {
            if FileManager.default.fileExists(atPath: stopFile.path) {
                log("agent exit: stop file")
                break
            }
            if ownerPID > 0, kill(ownerPID, 0) != 0 {
                log("agent exit: owner \(ownerPID) gone")
                break
            }

            if let data = try? Data(contentsOf: requestFile),
               let request = try? JSONDecoder().decode(ProcessDetail.self, from: data) {
                var detail = ProcessInspector.inspect(pid: pid_t(request.pid))
                detail.seq = request.seq
                if let payload = try? JSONEncoder().encode(detail) {
                    try? payload.write(to: responseFile, options: .atomic)
                    log("agent detail pid=\(request.pid) fields=\(detail.fields.count)")
                }
                try? FileManager.default.removeItem(at: requestFile)
                continue
            }

            let viewing = FileManager.default.fileExists(atPath: viewingFile.path)
            if !viewing || Date() < nextSampleAt {
                Thread.sleep(forTimeInterval: 0.25)
                continue
            }

            let list = sampler.sample()
            let rows = list.map {
                RootProcessRow(pid: $0.pid, name: $0.name, cpu: $0.cpu,
                               memory: $0.memory, ports: $0.ports)
            }
            do {
                let data = try JSONEncoder().encode(rows)
                try data.write(to: dataFile, options: .atomic)
                written += 1
                if written == 1 || written % 30 == 0 {
                    log("agent write n=\(rows.count) unreadable=\(sampler.unreadableCount) round=\(written)")
                }
            } catch {
                failures += 1
                if failures <= 3 { log("agent write failed: \(error.localizedDescription)") }
            }
            nextSampleAt = Date().addingTimeInterval(2.0)
            Thread.sleep(forTimeInterval: 0.25)
        }

        try? FileManager.default.removeItem(at: dataFile)
        try? FileManager.default.removeItem(at: stopFile)
        try? FileManager.default.removeItem(at: ownerFile)
        log("agent done written=\(written)")
        return 0
    }
}
