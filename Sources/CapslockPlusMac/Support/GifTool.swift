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
        static let installCommand = "brew install ffmpeg gifsicle"
    }

    /// 结果：成功时返回输出体积（字节），失败携带一句人话
    struct Failure: Error { let message: String }
    typealias Outcome = Result<Int, Failure>

    private(set) var isRunning = false
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

    static func missingTools() -> [String] {
        [Env.ffmpeg, Env.gifsicle].filter { locate($0) == nil }
    }

    static func environmentReport() -> String {
        var lines = ["PATH=\(ProcessInfo.processInfo.environment["PATH"] ?? "(空)")"]
        for name in [Env.ffmpeg, Env.gifsicle] {
            if let path = locate(name) {
                let out = run(path, ["-version"]).err
                    .split(separator: "\n").first.map(String.init) ?? ""
                lines.append("\(name)=\(path)  \(out.prefix(80))")
            } else {
                lines.append("\(name)=missing")
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
        alert.informativeText = "转 GIF 需要 ffmpeg 和 gifsicle。\n\n在终端执行：\n\(Env.installCommand)"
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

    // MARK: - 批量转换

    /// 同一文件夹里逐个转，输出与输入同名。重名不覆盖，依次退到 `-2`、`-3`。
    func convert(urls: [URL]) {
        isRunning = true
        Log.info("gifTool start n=\(urls.count)")
        queue.async { [weak self] in
            var ok = 0
            var failed: [String] = []
            var oversized: [String] = []

            for (index, input) in urls.enumerated() {
                DispatchQueue.main.async {
                    // ms=0 是"不显示"，要常驻得给一个够长的值，结束时再 dismiss
                    StatusToast.shared.show("转换中 \(index + 1)/\(urls.count)",
                                            detail: input.lastPathComponent, ms: 600_000)
                }
                guard let output = Self.uniqueOutput(for: input) else {
                    failed.append("\(input.lastPathComponent)：无法确定输出路径")
                    continue
                }
                switch Self.convertFile(input: input, output: output) {
                case .success(let bytes):
                    ok += 1
                    Log.info("gifTool ok in=\(input.lastPathComponent) out=\(output.lastPathComponent) bytes=\(bytes)")
                    if bytes > 10 * 1024 * 1024 { oversized.append(output.lastPathComponent) }
                case .failure(let failure):
                    failed.append("\(input.lastPathComponent)：\(failure.message)")
                    Log.warn("gifTool failed in=\(input.lastPathComponent) reason=\(failure.message)")
                }
            }

            self?.isRunning = false
            DispatchQueue.main.async {
                StatusToast.shared.dismiss()
                if failed.isEmpty {
                    let extra = oversized.isEmpty ? "" : "；\(oversized.count) 个超过 10MB"
                    StatusToast.shared.show("已转换 \(ok) 个", detail: "同目录下查看" + extra, ms: 2600)
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
    @discardableResult
    static func convertFile(input: URL, output: URL) -> Outcome {
        guard let ffmpeg = locate(Env.ffmpeg), let gifsicle = locate(Env.gifsicle) else {
            return .failure(Failure(message: "缺少 ffmpeg 或 gifsicle"))
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("capslock-gif-\(UUID().uuidString).gif")

        let filter = "fps=12,scale='min(800,iw)':-1:flags=lanczos,"
            + "split[a][b];[a]palettegen=stats_mode=diff:max_colors=256[p];"
            + "[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle"

        let first = run(ffmpeg, ["-v", "error", "-y", "-i", input.path,
                                 "-vf", filter, "-loop", "0", temp.path])
        guard first.code == 0 else {
            try? FileManager.default.removeItem(at: temp)
            return .failure(Failure(message: friendly(first.err)))
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
