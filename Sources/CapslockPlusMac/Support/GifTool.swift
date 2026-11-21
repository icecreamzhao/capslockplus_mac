import AppKit
import UniformTypeIdentifiers

/// 菜单「小工具 → 录屏转 GIF」的实现。
///
/// 两个必须记住的坑：
/// 1. 由 LaunchAgent 拉起的 GUI 进程，PATH 只有 `/usr/bin:/bin:/usr/sbin:/sbin`，
///    Homebrew 的 ffmpeg/gifsicle 不在里面 —— 所以不能靠 `which`，要按目录硬找。
/// 2. 转码要几秒到几十秒，必须在后台队列跑；主线程一卡，事件 tap 就跟着停，
///    键盘会"粘住"（chord 状态机收不到 keyUp）。
final class GifTool {
    static let shared = GifTool()

    enum Env {
        static let ffmpeg = "ffmpeg"
        static let gifsicle = "gifsicle"
        static let installCommand = "brew install ffmpeg"
    static let optionalInstallCommand = "brew install gifsicle"
    }

    /// 结果：成功时返回输出体积（字节），失败携带一句人话
    struct Failure: Error { let message: String }
    typealias Outcome = Result<Int, Failure>

    private(set) var isRunning = false
    /// gifsicle 只是"能更小"，不值得每次转码都问一遍；一次会话里问过就不再问。
    private var askedOptionalTool = false
    private let queue = DispatchQueue(label: "capslock.gif.convert", qos: .userInitiated)

    // MARK: - 环境探测

    /// PATH 里没有就按常见目录找。GUI 进程的 PATH 是不可信的自证伪证据。
    static func locate(_ name: String) -> String? {
        var dirs: [String] = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in dirs where !dir.isEmpty {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// 只有 ffmpeg 是必需的（转码全靠它）。
    /// gifsicle 只负责再压 30~50%，没装也能用，只是 GIF 大一些 —— 不该因为它挡路。
    static func missingTools() -> [String] {
        [Env.ffmpeg].filter { locate($0) == nil }
    }

    static var gifsiclePath: String? { locate(Env.gifsicle) }

    static func environmentReport() -> String {
        var lines = ["PATH=\(ProcessInfo.processInfo.environment["PATH"] ?? "(空)")"]
        for (name, required) in [(Env.ffmpeg, "必需"), (Env.gifsicle, "可选")] {
            if let path = locate(name) {
                // ffmpeg 认 -version，gifsicle 只认 --version（-version 会被拆成 -v -e -r）
                let out = run(path, [name == Env.gifsicle ? "--version" : "-version"]).err
                    .split(separator: "\n").first.map(String.init) ?? ""
                lines.append("\(name)(\(required))=\(path)  \(out.prefix(70))")
            } else {
                lines.append("\(name)(\(required))=missing")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 菜单入口

    /// 点菜单后：先查环境 → 选文件 → 转。
    func pickAndConvert() {
        guard !isRunning else {
            StatusToast.shared.show("正在转换…", detail: "等这一批结束", ms: 1600)
            return
        }
        let missing = GifTool.missingTools()
        guard missing.isEmpty else {
            Log.warn("gifTool missing=\(missing.joined(separator: ","))")
            promptInstall(missing: missing)
            return
        }

        // 可选依赖：缺 gifsicle 不影响转换，只影响体积，所以只问、不拦
        if GifTool.gifsiclePath == nil && !askedOptionalTool {
            askedOptionalTool = true
            let shouldConvert = promptOptionalTool()
            Log.info("gifTool optionalTool prompt convert=\(shouldConvert ? 1 : 0)")
            guard shouldConvert else { return }
        }

        // LSUIElement 的 App 默认不在前台，不激活的话 NSOpenPanel 会开到别的窗口后面
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "选择录屏文件（.mov / .mp4）"
        panel.prompt = "转换"
        panel.message = "选中后在原文件夹生成同名 GIF"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.quickTimeMovie, .mpeg4Movie]
        if let last = UserDefaults.standard.string(forKey: "gifTool.lastDir") {
            panel.directoryURL = URL(fileURLWithPath: last)
        }

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        UserDefaults.standard.set(panel.urls[0].deletingLastPathComponent().path,
                                  forKey: "gifTool.lastDir")
        convert(urls: panel.urls)
    }

    private func promptInstall(missing: [String]) {
        let alert = NSAlert()
        alert.messageText = "缺少转换工具：\(missing.joined(separator: "、"))"
        alert.informativeText = "转 GIF 需要 ffmpeg。\n\n在终端执行：\n\(Env.installCommand)\n\n"
            + "gifsicle 是可选的（装上能再小 30~50%），没装也能转。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "复制安装命令")
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Env.installCommand, forType: .string)
            StatusToast.shared.show("已复制安装命令", ms: 1600)
        }
    }

    /// 返回 true 表示"不装，直接转换"；false 表示用户要先去装，退出不转。
    private func promptOptionalTool() -> Bool {
        let alert = NSAlert()
        alert.messageText = "没装 gifsicle，转出来的 GIF 会大一些"
        alert.informativeText = "装上只是体积更小，功能完全一样。"
            + "界面类录屏（大面积静止）通常能再小 20~40%，动作多的视频只有几个百分点。\n\n"
            + "安装命令：\(Env.optionalInstallCommand)\n\n"
            + "选「复制安装命令」会把它放进剪贴板，然后退出（装完再点一次菜单即可）。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "复制安装命令")
        alert.addButton(withTitle: "不装，直接转换")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return true }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Env.optionalInstallCommand, forType: .string)
        StatusToast.shared.show("已复制安装命令", detail: Env.optionalInstallCommand, ms: 2600)
        return false
    }

    // MARK: - 批量转换

    /// 同一文件夹里逐个转，输出与输入同名。重名不覆盖，依次退到 `-2`、`-3`。
    func convert(urls: [URL]) {
        isRunning = true
        Log.info("gifTool start n=\(urls.count)")
        queue.async { [weak self] in
            var ok = 0
            var produced = 0
            var failed: [String] = []
            var oversized: [String] = []

            DispatchQueue.main.async { MenuBarProgress.shared.start() }

            for (index, input) in urls.enumerated() {
                // 多文件时按"第几个 + 这个文件自己的进度"折算成总进度
                let base = Double(index) / Double(urls.count)
                let span = 1.0 / Double(urls.count)
                guard let output = Self.uniqueOutput(for: input) else {
                    failed.append("\(input.lastPathComponent)：无法确定输出路径")
                    continue
                }
                switch Self.convertFile(input: input, output: output, onProgress: { local in
                    DispatchQueue.main.async {
                        MenuBarProgress.shared.update(base + local * span)
                    }
                }) {
                case .success(let bytes):
                    ok += 1
                    produced += bytes
                    Log.info("gifTool ok in=\(input.lastPathComponent) out=\(output.lastPathComponent) bytes=\(bytes)")
                    if bytes > 10 * 1024 * 1024 { oversized.append(output.lastPathComponent) }
                case .failure(let failure):
                    failed.append("\(input.lastPathComponent)：\(failure.message)")
                    Log.warn("gifTool failed in=\(input.lastPathComponent) reason=\(failure.message)")
                }
            }

            self?.isRunning = false
            DispatchQueue.main.async {
                MenuBarProgress.shared.stop()
                if failed.isEmpty {
                    // 完成提示只留 1 秒：转完了就完了，不需要人点确认
                    let total = Self.humanSize(bytes: produced)
                    StatusToast.shared.show("已转换 \(ok) 个", detail: "\(total) · 同目录下", ms: 1000)
                } else {
                    self?.reportFailure(failed: failed, ok: ok)
                }
            }
        }
    }

    private func reportFailure(failed: [String], ok: Int) {
        let alert = NSAlert()
        alert.messageText = ok > 0 ? "部分失败（成功 \(ok) 个）" : "转换失败"
        alert.informativeText = failed.prefix(6).joined(separator: "\n\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    /// `a.mov` → `a.gif`；已存在则 `a-2.gif`、`a-3.gif`，永不静默覆盖用户文件。
    static func uniqueOutput(for input: URL) -> URL? {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        for index in 1...99 {
            let name = index == 1 ? "\(base).gif" : "\(base)-\(index).gif"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - 单文件转换

    /// 跑两遍调色板：先统计，再抖动。直接转会用固定 256 色，界面大片纯色会起色带。
    /// 宽度只缩不放（素材本来就窄时保持原样），这一点和 scripts/make-gif.sh 一致。
    static func humanSize(bytes: Int) -> String {
        if bytes > 1024 * 1024 {
            return String(format: "%.1fMB", Double(bytes) / 1048576)
        }
        return "\(max(bytes / 1024, 1))KB"
    }

    /// 视频总时长（秒）。拿不到就返回 nil —— 那时进度条退化成滑动动画，不影响转换。
    static func duration(of input: URL) -> Double? {
        guard let ffprobe = locate("ffprobe") else { return nil }
        let out = run(ffprobe, ["-v", "error", "-show_entries", "format=duration",
                                "-of", "default=noprint_wrappers=1:nokey=1", input.path])
        return Double(out.err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @discardableResult
    static func convertFile(input: URL, output: URL,
                            onProgress: ((Double) -> Void)? = nil) -> Outcome {
        guard let ffmpeg = locate(Env.ffmpeg) else {
            return .failure(Failure(message: "缺少 ffmpeg"))
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("capslock-gif-\(UUID().uuidString).gif")

        let filter = "fps=12,scale='min(800,iw)':-1:flags=lanczos,"
            + "split[a][b];[a]palettegen=stats_mode=diff:max_colors=256[p];"
            + "[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle"

        // -progress pipe:1：让 ffmpeg 把编码进度按行吐到 stdout（-nostats 关掉人类可读的那份），
        // stderr 仍然只留错误信息，两者分开才能既报进度又报错。
        let total = duration(of: input)
        // -stats_period 0.2：默认每 0.5s 才吐一次，短片段等于只报个尾数，进度条会突然跳满
        let first = runStreaming(ffmpeg, ["-v", "error", "-nostats", "-stats_period", "0.2",
                                          "-progress", "pipe:1",
                                          "-y", "-i", input.path,
                                          "-vf", filter, "-loop", "0", temp.path]) { line in
            guard let total, total > 0, let onProgress else { return }
            guard let range = line.range(of: "out_time_us="),
                  let micros = Double(line[range.upperBound...]) else { return }
            let seconds = micros / 1_000_000
            onProgress(min(seconds / total, 0.99))
        }
        guard first.code == 0 else {
            try? FileManager.default.removeItem(at: temp)
            return .failure(Failure(message: friendly(first.err)))
        }

        guard let gifsicle = gifsiclePath else {
            // 没装 gifsicle：跳过二次压缩，体积大一些但结果可用
            do {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: temp, to: output)
                Log.info("gifTool note=gifsicle-missing skip=-O3")
            } catch {
                return .failure(Failure(message: "无法写入 \(output.lastPathComponent)"))
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int
            return .success(size ?? 0)
        }

        let second = run(gifsicle, ["-O3", "--lossy=80", "--colors", "256", temp.path, "-o", output.path])
        try? FileManager.default.removeItem(at: temp)
        guard second.code == 0 else { return .failure(Failure(message: friendly(second.err))) }

        let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
        return .success((attributes?[.size] as? Int) ?? 0)
    }

    /// ffmpeg 的报错很长，取最后两行有效信息；空的话给个兜底文案。
    private static func friendly(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return "转换失败（无输出）" }
        if last.contains("No such file") { return "文件读不到：\(last)" }
        if last.contains("Invalid data") { return "不是有效的视频文件：\(last)" }
        return last
    }

    /// 跑命令并把 stdout 逐行回调（进度用），stderr 攒起来当报错文案。
    @discardableResult
    static func runStreaming(_ path: String, _ args: [String],
                             onStdoutLine: @escaping (String) -> Void) -> (code: Int32, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let lock = NSLock()
        var errData = Data()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
                onStdoutLine(String(line))
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); errData.append(chunk); lock.unlock()
        }

        do {
            try process.run()
        } catch {
            return (-1, "无法启动 \(path)：\(error.localizedDescription)")
        }
        process.waitUntilExit()
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        let collected = errData
        lock.unlock()
        return (process.terminationStatus, String(decoding: collected, as: UTF8.self))
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (code: Int32, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return (-1, "无法启动 \(path)：\(error.localizedDescription)")
        }
        // 先读到 EOF 再 wait：反过来的话输出超过管道缓冲会死锁
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
