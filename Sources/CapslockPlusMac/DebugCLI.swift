import Foundation
import AppKit
import AVFoundation


/// 命令行入口：所有 --flag 子命令（自检、AX 探针、字典/音频/翻译测试、面板测试）。
/// `run()` 返回 nil 表示"不是子命令"，main.swift 继续启动 App。
enum DebugCLI {
    static func run() -> Int32? {
        // root 代理模式：由 root 权限拉起，只做采样写文件，不碰配置/界面
        if let index = CommandLine.arguments.firstIndex(of: "--root-agent"),
           index + 1 < CommandLine.arguments.count {
            return RootProbe.runAgent(directory: CommandLine.arguments[index + 1])
        }

        // 子命令也读真实配置：否则 Config.shared 只有代码里的默认值，
        // 看起来"配置改了不生效"（实际是这条进程根本没加载 keymap.json）。
        Config.shared.loadOrCreate()

        if let index = CommandLine.arguments.firstIndex(of: "--ax-selectall"),
           index + 1 < CommandLine.arguments.count {
            return runSelectAllProbe(bundleID: CommandLine.arguments[index + 1])
        }

        if CommandLine.arguments.contains("--input-source-list") {
            print("current=", InputSource.currentSnapshot(), "caps=", HIDCapsLock.shared.isLocked ? 1 : 0)
            for (index, source) in InputSource.selectableSources().enumerated() {
                print(String(format: "%2d  %@  %@", index, InputSource.debugID(source) ?? "?", InputSource.debugName(source) ?? "?"))
            }
            return 0
        }

        if CommandLine.arguments.contains("--clipboard-selftest") {
            return Clipboard.selftest() ? 0 : 1
        }

        if let index = CommandLine.arguments.firstIndex(of: "--clipboard-probe"),
           index + 1 < CommandLine.arguments.count {
            let bundleID = CommandLine.arguments[index + 1]
            var lines: [String] = []
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate(options: [])
                usleep(400_000)
                let text = Clipboard.copySelection()
                lines.append("app=\(bundleID) len=\(text?.count ?? -1) head=\((text ?? "nil").prefix(30))")
            } else {
                lines.append("app not running: \(bundleID)")
            }
            try? lines.joined(separator: "\n").write(toFile: "/tmp/clipprobe.txt", atomically: true, encoding: .utf8)
            return 0
        }

        if CommandLine.arguments.contains("--ax-matrix") || CommandLine.arguments.contains("--clipboard-probe") || CommandLine.arguments.contains("--clipboard-selftest") {
            return runAXMatrixProbe()
        }

        if let index = CommandLine.arguments.firstIndex(of: "--ax-light"),
           index + 1 < CommandLine.arguments.count {
            return runAXLightProbe(bundleID: CommandLine.arguments[index + 1])
        }

        if let index = CommandLine.arguments.firstIndex(of: "--ax-probe"),
           index + 1 < CommandLine.arguments.count {
            return runAXProbe(bundleID: CommandLine.arguments[index + 1])
        }


        if CommandLine.arguments.contains("--smc-report") {
            print(SMC.report())
            return 0
        }

        if CommandLine.arguments.contains("--ports-list") {
            let sampler = ProcessSampler()
            _ = sampler.sample()
            usleep(200_000)
            let list = sampler.sample()
            let withPorts = list.filter { !$0.ports.isEmpty }.sorted { ($0.ports.first ?? 0) < ($1.ports.first ?? 0) }
            print("total=\(list.count) withPorts=\(withPorts.count)")
            for item in withPorts {
                print(String(format: "  pid=%d %-26@ ports=%@", item.pid, item.name as NSString,
                             item.ports.map { "\($0)" }.joined(separator: ",") as NSString))
            }
            return 0
        }

        if CommandLine.arguments.contains("--status-readout-selftest") {
            let view = StatusReadoutView(frame: NSRect(x: 0, y: 0, width: 160, height: 22))
            view.glyph = NSImage(systemSymbolName: "capsule.portrait", accessibilityDescription: nil)

            func paintedPixels() -> Int {
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 22,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0) else { return -1 }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                view.frame = NSRect(x: 0, y: 0, width: 200, height: 22)
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
                guard let data = rep.bitmapData else { return -1 }
                var count = 0
                for index in stride(from: 3, to: 200 * 22 * 4, by: 4) where data[index] > 8 { count += 1 }
                return count
            }

            view.update(caps: false, cpu: "", mem: "")
            print(String(format: "icon-only  width=%.1f pixels=%d", view.requiredWidth(), paintedPixels()))
            view.update(caps: false, cpu: "16%", mem: "35%")
            print(String(format: "cpu+mem    width=%.1f pixels=%d", view.requiredWidth(), paintedPixels()))
            view.update(caps: true, cpu: "100%", mem: "35%")
            print(String(format: "caps+100%%  width=%.1f pixels=%d", view.requiredWidth(), paintedPixels()))

            // 宽度必须与数值位数无关，否则状态栏会随数字跳动
            view.update(caps: false, cpu: "16%", mem: "35%", down: "4.0M", up: "46K")
            print(String(format: "with net   width=%.1f pixels=%d", view.requiredWidth(), paintedPixels()))

            var widths: Set<Double> = []
            for sample in [("8%", "9%", "0", "0"), ("16%", "35%", "46K", "1.2K"),
                           ("100%", "100%", "999M", "9.9M"), ("0%", "7%", "1.0G", "0")] {
                view.update(caps: false, cpu: sample.0, mem: sample.1, down: sample.2, up: sample.3)
                widths.insert(Double(view.requiredWidth()))
            }
            print("width stability: \(widths.count == 1 ? "稳定 ✓" : "抖动 ✗") widths=\(widths.sorted())")

            view.update(caps: false, cpu: "16%", mem: "35%", down: "4.0M", up: "46K", hotspot: true)
            print(String(format: "hotspot on width=%.1f pixels=%d", view.requiredWidth(), paintedPixels()))
            return 0
        }

        if let index = CommandLine.arguments.firstIndex(of: "--proc-detail"),
           index + 1 < CommandLine.arguments.count,
           let pid = pid_t(CommandLine.arguments[index + 1]) {
            let detail = ProcessInspector.inspect(pid: pid)
            print("pid=\(pid) fields=\(detail.fields.count) path=\(detail.executablePath ?? "-")")
            for field in detail.fields {
                print(String(format: "  %-14@ %@", field.label as NSString, field.value as NSString))
            }
            return 0
        }

        if CommandLine.arguments.contains("--net-test") {
            let sampler = NetworkSampler()
            _ = sampler.sample()                    // 建立基线
            usleep(2_000_000)
            let rates = sampler.sample()
            print("pids with traffic=\(rates.count)")
            for (pid, rate) in rates.sorted(by: { $0.value.down + $0.value.up > $1.value.down + $1.value.up }).prefix(10) {
                let name = ProcessInspector.executablePath(pid).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
                print(String(format: "  %-26@ pid=%6d down=%8@ up=%8@", name as NSString, pid,
                             SystemFormat.compactRate(rate.down) as NSString,
                             SystemFormat.compactRate(rate.up) as NSString))
            }
            return 0
        }

        if CommandLine.arguments.contains("--proc-test") {
            let sampler = ProcessSampler()
            _ = sampler.sample()                    // 第一次只是建立基线
            usleep(1_200_000)
            let list = sampler.sample()
            func line(_ p: ProcessSample) -> String {
                String(format: "%-26@ pid=%6d cpu=%6.1f%% mem=%8.1fMB ports=%@",
                       p.name as NSString, p.pid, p.cpu, Double(p.memory) / 1048576,
                       (p.ports.isEmpty ? "-" : p.ports.map { "\($0)" }.joined(separator: ",")) as NSString)
            }
            let started = Date()
            _ = sampler.sample()
            let cost = Date().timeIntervalSince(started) * 1000
            print(String(format: "count=%d scan=%.1fms", list.count, cost))
            print("--- top CPU ---")
            for item in list.prefix(8) { print(line(item)) }
            print("--- top MEM ---")
            for item in list.sorted(by: { $0.memory > $1.memory }).prefix(8) { print(line(item)) }
            let sum = list.reduce(0.0) { $0 + $1.cpu }
            print(String(format: "sum(cpu)=%.1f%% （系统总占用见 --sys-test）", sum))
            return 0
        }

        if CommandLine.arguments.contains("--sys-window-selftest") {
            let controller = SystemWindowController.shared
            controller.show()
            let deadline = Date().addingTimeInterval(0.6)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            print("frame=\(controller.debugFrame)")
            // 模拟拖大/拖小，验证弹簧布局与列宽自适应
            controller.debugResize(to: NSSize(width: 700, height: 720))
            print("after grow=\(controller.debugFrame)")
            controller.debugResize(to: NSSize(width: 420, height: 360))
            print("after shrink=\(controller.debugFrame)")
            ProcessDetailPanel.shared.show(ProcessInspector.inspect(pid: getpid()))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            print("net line: \(controller.debugNetworkLine)")
            print("detail panel: \(ProcessDetailPanel.shared.debugInfo)")
            let before = ProcessDetailPanel.shared.valueFor("启动时间")
            RunLoop.current.run(until: Date().addingTimeInterval(3.2))
            let after = ProcessDetailPanel.shared.valueFor("启动时间")
            print("auto refresh: 启动时间 \"\(before)\" -> \"\(after)\"" + (before == after ? "  ✗ 没刷新" : "  ✓ 已刷新"))
            print("fields: \(ProcessDetailPanel.shared.debugLabels)")
            ProcessDetailPanel.shared.hide()

            let bench = controller.debugScrollBench()
            print(String(format: "scroll bench: %.2f ms/frame, reload=%.2f ms", bench.frameMs, bench.reloadMs))
            controller.hide()
            print("after hide=\(controller.debugFrame)")
            return 0
        }

        if CommandLine.arguments.contains("--sys-test") {
            // 采两次：CPU 与网络速率本质是差值，第一次必然是 0
            let sampler = SystemSampler()
            _ = sampler.sample()
            usleep(600_000)
            let snap = sampler.sample()
            print("cpu=\(SystemFormat.percent(snap.cpu)) cores=\(ProcessInfo.processInfo.processorCount)")
            print("mem=\(SystemFormat.bytes(snap.memUsed))/\(SystemFormat.bytes(snap.memTotal)) (\(SystemFormat.percent(snap.memPercent)))")
            print(String(format: "load=%.2f %.2f %.2f", snap.load1, snap.load5, snap.load15))
            print("uptime=\(SystemFormat.duration(snap.uptime))")
            print("disk=\(SystemFormat.bytes(snap.diskFree)) free / \(SystemFormat.bytes(snap.diskTotal))")
            print("net(physical)=\(SystemFormat.rate(snap.netDown)) down / \(SystemFormat.rate(snap.netUp)) up"
                  + "  tunnel=\(SystemFormat.rate(snap.tunnelDown))/\(SystemFormat.rate(snap.tunnelUp))"
                  + "  hotspot=\(snap.hotspotActive ? 1 : 0) primary=\(SystemSampler.primaryInterface()?.name ?? "-")")
            for item in snap.interfaces.prefix(8) {
                print(String(format: "  iface %-18@ %-6@ %-8@ ↓%-8@ ↑%-8@",
                             item.displayName as NSString, item.kind.label as NSString,
                             (item.hasAddress ? "有地址" : "未启用") as NSString,
                             SystemFormat.compactRate(item.down) as NSString,
                             SystemFormat.compactRate(item.up) as NSString))
            }
            print("battery=\(snap.batteryPercent.map(String.init) ?? "nil")% charging=\(snap.batteryCharging) health=\(snap.batteryHealth.map(String.init) ?? "nil")% cycles=\(snap.batteryCycles.map(String.init) ?? "nil")")
            print(String(format: "temp=%.1f°C fans=%d", snap.cpuTemp ?? -1, snap.fanCount))
            print("fanRPM=\(snap.fanRPM.map(String.init) ?? "nil")")
            // 格式化函数的边界（纯函数，不依赖采样）
            print("fmt: \(SystemFormat.rate(0)) | \(SystemFormat.rate(1536)) | \(SystemFormat.duration(90_061)) | \(SystemFormat.bytes(0)) | \(SystemFormat.percent(1.7))")
            return 0
        }

        if CommandLine.arguments.contains("--progress-selftest") {
            return runProgressSelfTest()
        }

        if CommandLine.arguments.contains("--tools-check") {
            print(GifTool.environmentReport())
            return 0
        }

        if let index = CommandLine.arguments.firstIndex(of: "--gif-convert"),
           index + 1 < CommandLine.arguments.count {
            let input = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let output: URL
            if index + 2 < CommandLine.arguments.count,
               !CommandLine.arguments[index + 2].hasPrefix("--") {
                output = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            } else if let auto = GifTool.uniqueOutput(for: input) {
                output = auto
            } else {
                print("gifConvert error=无法确定输出路径")
                return 2
            }
            var lastBucket = -1
            switch GifTool.convertFile(input: input, output: output, onProgress: { fraction in
                let bucket = Int(fraction * 10)
                if bucket != lastBucket {
                    lastBucket = bucket
                    print("progress=\(bucket * 10)%")
                }
            }) {
            case .success(let bytes):
                print("gifConvert ok out=\(output.path) bytes=\(bytes)")
                return 0
            case .failure(let failure):
                print("gifConvert error=\(failure.message)")
                return 1
            }
        }

        if let index = CommandLine.arguments.firstIndex(of: "--ax-tree"),
           index + 1 < CommandLine.arguments.count {
            let report = runAXTree(bundleID: CommandLine.arguments[index + 1])
            try? report.write(toFile: "/tmp/axtree.txt", atomically: true, encoding: .utf8)
            print(report)
            return 0
        }

        if let index = CommandLine.arguments.firstIndex(of: "--toast-test") {
            let text = index + 1 < CommandLine.arguments.count
                ? CommandLine.arguments[index + 1] : "简体拼音"
            NSApplication.shared.setActivationPolicy(.accessory)
            StatusToast.shared.show(text, detail: nil, ms: 2000)
            // CLI 里没有 run loop，自己泵一会儿，否则窗口还没画完就退出了
            let deadline = Date().addingTimeInterval(2.3)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            print("toast-test ok text=\(text)")
            return 0
        }

        if CommandLine.arguments.contains("--panel-clamp-selftest") {
            let delegate = PanelClampSelfTestDelegate()
            NSApplication.shared.delegate = delegate
            NSApplication.shared.run()
            return 1
        }

        if CommandLine.arguments.contains("--panel-html-selftest") {
            let delegate = PanelHTMLSelfTestDelegate()
            NSApplication.shared.delegate = delegate
            NSApplication.shared.run()
            return 1
        }

        if CommandLine.arguments.contains("--panel-selftest") {
            let delegate = PanelSelfTestDelegate()
            NSApplication.shared.delegate = delegate
            NSApplication.shared.run()
            return 1
        }

        if let index = CommandLine.arguments.firstIndex(of: "--audio-test"),
           index + 1 < CommandLine.arguments.count {
            let relative = CommandLine.arguments[index + 1]
            let file = (AudioPlayer.audioRoot as NSString).appendingPathComponent(relative)
            do {
                let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: file))
                print("ok duration=\(String(format: "%.2f", player.duration))s file=\(relative)")
                return 0
            } catch {
                print("FAILED: \(error.localizedDescription) file=\(relative)")
                return 1
            }
        }

        if let index = CommandLine.arguments.firstIndex(of: "--dict-test"),
           index + 1 < CommandLine.arguments.count {
            let query = CommandLine.arguments[index + 1]
            let entries = OfflineDictionary.shared.lookup(query)
            print("candidates=\(OfflineDictionary.candidates(for: query))")
            print("hits=\(entries.count)")
            for entry in entries {
                print("[\(entry.source)] \(entry.headword) /\(entry.phonetic ?? "-")/ audio=\(entry.audioPath ?? "-")")
                for line in entry.lines.prefix(10) {
                    print("   ", line)
                }
            }
            return entries.isEmpty ? 1 : 0
        }

        if let index = CommandLine.arguments.firstIndex(of: "--translate-test"),
           index + 1 < CommandLine.arguments.count {
            let query = CommandLine.arguments[index + 1]
            let semaphore = DispatchSemaphore(value: 0)
            TranslateService.fetchRaw(query) { translation, message in
                if let translation = translation {
                    print("query=\(translation.query)")
                    print("phonetic=\(translation.phonetic ?? "-")")
                    print("lines=\(translation.lines.count) web=\(translation.webLines.count)")
                    print(translation.displayText)
                } else {
                    print("FAILED: \(message ?? "unknown")")
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 15)
            return 0
        }

        if CommandLine.arguments.contains("--tiling-selftest") {
            return runTilingSelfTest()
        }

        if CommandLine.arguments.contains("--probe-tiling") {
            print("ax_trusted=\(AX.isTrusted ? 1 : 0) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
            for line in WindowActions.describeTiling() {
                print(line)
            }
            return 0
        }

        if CommandLine.arguments.contains("--transform-selftest") {
            return runTransformSelfTest()
        }

        if CommandLine.arguments.contains("--selftest") {
            return runSelfTest()
        }

        if CommandLine.arguments.contains("--login-item-enable") {
            let ok = LoginItem.enable()
            print("login-item-enable \(ok ? "ok" : "fail")")
            return ok ? 0 : 1
        }

        if CommandLine.arguments.contains("--login-item-disable") {
            let ok = LoginItem.disable()
            print("login-item-disable \(ok ? "ok" : "fail")")
            return ok ? 0 : 1
        }


        return nil
    }
}

final class PanelSelfTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let entry = DictEntry(source: "oalecd9", headword: "hello", phonetic: "həˈləʊ",
                              body: "verb\t打招呼\nnoun\t你好", audioBre: nil, audioAme: nil, html: nil)
        TranslatePanel.shared.show(entry: entry, audio: nil)
        let firstOrigin = TranslatePanel.shared.debugOrigin
        let firstTop = TranslatePanel.shared.debugTop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            // 模拟"结果回来再渲染一次"：位置必须原地不动
            let longer = DictEntry(source: "oalecd9", headword: "hello", phonetic: "həˈləʊ",
                                   body: "verb\t打招呼\nnoun\t你好\nnoun\t喂\n例\thello there 你好呀", audioBre: nil, audioAme: nil, html: nil)
            TranslatePanel.shared.show(entry: longer, audio: nil)
            let secondOrigin = TranslatePanel.shared.debugOrigin
            let secondTop = TranslatePanel.shared.debugTop
            print("origin1=\(firstOrigin) origin2=\(secondOrigin) top1=\(firstTop) top2=\(secondTop)")
            print("appActive=\(NSApp.isActive ? 1 : 0) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") panelKey=\(TranslatePanel.shared.isKeyWindow ? 1 : 0)")
            let expected = "verb  打招呼\nnoun  你好\nnoun  喂\n例  hello there 你好呀"
            let report = TranslatePanel.shared.debugSelectAllBody()
            print("expected=\(expected.debugDescription)")
            print(report)
            let picked = TranslatePanel.shared.selectionText
            // 顶边和横坐标不动即可：内容变长应该向下长，底部 origin.y 变化是正常的
            let stable = abs(firstOrigin.x - secondOrigin.x) < 0.5 && abs(firstTop - secondTop) < 0.5
            print("stable=\(stable ? 1 : 0)")

            // 关掉浮层后必须把 App 激活状态还回去，否则目标 App 会把 AX 选区清空
            TranslatePanel.shared.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let active = NSApp.isActive ? 1 : 0
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
                print("afterDismiss active=\(active) frontmost=\(front)")
                let restored = active == 0
                exit((picked == expected && stable && restored) ? 0 : 1)
            }
        }
    }
}


final class PanelHTMLSelfTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let query = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "hello"
        let wantedSource = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
        let entries = OfflineDictionary.shared.lookup(query)
        guard let entry = entries.first(where: { $0.html != nil && (wantedSource == nil || $0.source == wantedSource) }) else {
            print("FAIL no html entry (hits=\(entries.count))")
            exit(1)
        }
        print("entry=\(entry.source) htmlLen=\(entry.html?.count ?? 0) assets=\(DictEntry.assetsDirectory(for: entry.source))")
        TranslatePanel.shared.show(entry: entry, audio: entry.audioPath)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            print(TranslatePanel.shared.debugSelectAllWeb())
            let picked = TranslatePanel.shared.selectionText ?? ""
            TranslatePanel.shared.dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                print("afterDismiss active=\(NSApp.isActive ? 1 : 0) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
                exit(picked.isEmpty ? 1 : 0)
            }
        }
    }
}

/// 只看焦点元素，不递归——给会卡死客户端的浏览器（Firefox）用
/// 给前台 App 发一次 Cmd+A 造出选区，再读 AX——用来分辨"浏览器不暴露选区"还是"当时没选区"
func runSelectAllProbe(bundleID: String) -> Int32 {
    var lines: [String] = []
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        try? "app not running".write(toFile: "/tmp/axselectall.txt", atomically: true, encoding: .utf8)
        return 2
    }
    app.activate(options: [])
    usleep(300_000)
    if let source = CGEventSource(stateID: .combinedSessionState),
       let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
       let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
    usleep(600_000)
    lines.append("trusted=\(AXIsProcessTrusted() ? 1 : 0)")
    let direct = AX.selectedText(forPID: app.processIdentifier)
    lines.append("directLen=\(direct?.count ?? -1)")
    let deep = AX.selectedTextDeep(forPID: app.processIdentifier)
    lines.append("deepLen=\(deep?.count ?? -1)")
    lines.append("deepHead=\((deep ?? "nil").prefix(40))")
    try? lines.joined(separator: "\n").write(toFile: "/tmp/axselectall.txt", atomically: true, encoding: .utf8)
    return 0
}

/// 扫一遍当前前台 App 集合，报告每个 App 的选区可读性（不需要事先有选区，看属性是否存在）
func runAXMatrixProbe() -> Int32 {
    let outPath = "/tmp/axmatrix.txt"
    var lines: [String] = []
    func flush() { try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8) }
    let selfPID = ProcessInfo.processInfo.processIdentifier
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && $0.processIdentifier != selfPID }
        .sorted { ($0.bundleIdentifier ?? "") < ($1.bundleIdentifier ?? "") }

    lines.append("bundle\tmanual\trole\tselectedText\tmarker\tvalueLen")
    flush()
    for app in apps {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let manual = AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        usleep(250_000)

        var role = "-", hasText = "-", hasMarker = "-", valueLen = "-"
        if let element = AX.elementAttribute(ax, kAXFocusedUIElementAttribute as CFString) {
            let list = AX.attributeNames(of: element)
            role = AX.stringAttribute(element, kAXRoleAttribute as CFString) ?? "-"
            hasText = list.contains(kAXSelectedTextAttribute as String) ? "yes" : "no"
            hasMarker = list.contains("AXSelectedTextMarkerRange") ? "yes" : "no"
            if let text = AX.copyAttribute(element, kAXSelectedTextAttribute as CFString).value as? String {
                valueLen = String(text.count)
            }
        } else {
            role = "no-focused"
        }
        lines.append("\(app.bundleIdentifier ?? "?")\t\(manual.rawValue)\t\(role)\t\(hasText)\t\(hasMarker)\t\(valueLen)")
        flush()
    }
    return 0
}

func runAXLightProbe(bundleID: String) -> Int32 {
    var lines: [String] = []
    let outPath = "/tmp/axlight.txt"
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        try? "app not running".write(toFile: outPath, atomically: true, encoding: .utf8)
        return 2
    }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    lines.append("manualA11y=\(AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue)")
    lines.append("enhancedUI=\(AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)")
    let front = NSWorkspace.shared.frontmostApplication
    lines.append("front=\(front?.bundleIdentifier ?? "?") frontpid=\(front?.processIdentifier ?? 0) targetpid=\(app.processIdentifier)")
    usleep(700_000)   // Chromium 建树是异步的，设完属性马上读会拿到 -25212
    let focused = AX.copyAttribute(ax, kAXFocusedUIElementAttribute as CFString)
    lines.append("focusedErr=\(focused.status.rawValue)")
    if let raw = focused.value, CFGetTypeID(raw) == AXUIElementGetTypeID() {
        let element = raw as! AXUIElement
        lines.append("attrs=\(AX.attributeNames(of: element))")
        let selected = AX.copyAttribute(element, kAXSelectedTextAttribute as CFString)
        lines.append("AXSelectedText err=\(selected.status.rawValue) value=\((selected.value as? String) ?? "-")")
        let marker = AX.copyAttribute(element, "AXSelectedTextMarkerRange" as CFString)
        lines.append("markerRange err=\(marker.status.rawValue)")
        if marker.status == .success, let parameter = marker.value {
            let text = AX.copyParameterized(element, "AXStringForTextMarkerRange" as CFString, parameter)
            lines.append("markerText err=\(text.status.rawValue) value=\((text.value as? String) ?? "-")")
        }
    }
    lines.append("reader=\(AX.selectedText(forPID: app.processIdentifier) ?? "nil")")
    try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    return 0
}

func runAXProbe(bundleID: String) -> Int32 {
    var lines: [String] = []
    let outPath = "/tmp/axprobe.txt"
    func flush() {
        try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    }
    lines.append("started pid=\(ProcessInfo.processInfo.processIdentifier) target=\(bundleID)")
    flush()
    lines.append("trusted=\(AXIsProcessTrusted() ? 1 : 0)")
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        lines.append("app not running")
        try? lines.joined(separator: "\n").write(toFile: "/tmp/axprobe.txt", atomically: true, encoding: .utf8)
        return 2
    }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    lines.append("enhancedUI=\(AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue)")
    lines.append("manualA11y=\(AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue)")

    // 不依赖焦点：把 Safari 的窗口树走一遍，找任何带选区的元素
    var scanned = 0
    var hits: [String] = []
    func walk(_ el: AXUIElement, _ depth: Int) {
        guard scanned < 2000, depth <= 8 else { return }
        scanned += 1
        let role = AX.stringAttribute(el, kAXRoleAttribute as CFString) ?? "?"
        if role == "AXWebArea" || role == "AXStaticText" || role == "AXTextField" || role == "AXTextArea" {
            let selected = AX.copyAttribute(el, kAXSelectedTextAttribute as CFString)
            let text = (selected.value as? String) ?? ""
            var markerInfo = ""
            let marker = AX.copyAttribute(el, "AXSelectedTextMarkerRange" as CFString)
            if marker.status == .success, let parameter = marker.value {
                let text = AX.copyParameterized(el, "AXStringForTextMarkerRange" as CFString, parameter)
                markerInfo = " markerStatus=\(text.status.rawValue) markerText=\((text.value as? String) ?? "-")"
            } else {
                markerInfo = " marker=none"
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hits.append("HIT role=\(role) selected=\(text.prefix(40))")
            } else if role == "AXWebArea" {
                hits.append("WEBAREA empty selErr=\(selected.status.rawValue)\(markerInfo) attrs=\(AX.attributeNames(of: el))")
            }
        }
        for child in AX.elementArrayAttribute(el, kAXChildrenAttribute as CFString) ?? [] {
            walk(child, depth + 1)
        }
    }
    for window in AX.elementArrayAttribute(ax, kAXWindowsAttribute as CFString) ?? [] {
        let title = AX.stringAttribute(window, kAXTitleAttribute as CFString) ?? "-"
        lines.append("window: \(title)")
        flush()
        walk(window, 0)
        flush()
    }
    lines.append("scanned=\(scanned)")
    let readerResult = AX.selectedTextDeep(forPID: app.processIdentifier)
    lines.append("readerResult=\(readerResult ?? "nil")")
    flush()
    lines.append(contentsOf: hits.prefix(6))
    try? lines.joined(separator: "\n").write(toFile: "/tmp/axprobe.txt", atomically: true, encoding: .utf8)
    return 0
}

func runSelfTest() -> Int32 {
    var failures: [String] = []
    var seen = Set<KeyCombo>()

    for (chordText, actionText) in Config.defaultPairs {
        guard let combo = ChordParser.parse(chordText) else {
            failures.append("bad chord \(chordText)")
            continue
        }
        if !seen.insert(combo).inserted {
            failures.append("duplicate chord \(chordText)")
        }
        if Action.parse(actionText) == nil {
            failures.append("unknown action \(actionText)")
        }
    }
    if TapAction(rawValue: "toggleCapsLock") == nil {
        failures.append("unknown tap action")
    }

    // 往返自检：动作的 name 必须能被 parse 回同一个动作。
    // 这条是防"新增动作时忘了同步 name 或解析表"——两处手工映射，漏一处编译照样过。
    for (key, action) in Action.fixedTable {
        guard let roundTrip = Action.parse(action.name) else {
            failures.append("name not parseable key=\(key) name=\(action.name)")
            continue
        }
        if roundTrip != action {
            failures.append("name drift key=\(key) name=\(action.name) -> \(roundTrip.name)")
        }
    }

    // HUD 夹取：主屏、副屏、超长输入法名字都不能露到屏幕外
    let screens = [CGRect(x: 0, y: 0, width: 1440, height: 875),
                   CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                   CGRect(x: 0, y: 0, width: 320, height: 240)]
    let sizes = [CGSize(width: 40, height: 18), CGSize(width: 260, height: 18),
                 CGSize(width: 4000, height: 18)]
    for visible in screens {
        for size in sizes {
            let frame = StatusToast.frame(textSize: size, visible: visible,
                                          paddingX: StatusToast.Metrics.paddingX,
                                          height: StatusToast.Metrics.height)
            if !visible.contains(frame) {
                failures.append("toast out of visible \(Int(size.width)) in \(Int(visible.width))x\(Int(visible.height))")
            }
            // 文字必须放得下（左右各 8pt 内边距），否则界面上就是 "A…"
            // 只在"没被最大宽度夹住"时断言：超长文字本来就该截断
            let roomNeeded = ceil(size.width) + StatusToast.Metrics.paddingX * 2 + 6
            if roomNeeded <= visible.width - 40 {
                let textRoom = frame.width - StatusToast.Metrics.textInset * 2
                if textRoom < ceil(size.width) {
                    failures.append("toast text clipped \(Int(size.width)) -> \(Int(textRoom))")
                }
            }
            // 居中：横竖中心都要贴着屏幕中心（夹取没触发的前提下）
            if visible.width > 400 && abs(frame.midX - visible.midX) > 0.5 {
                failures.append("toast not centered x")
            }
        }
    }

    if failures.isEmpty {
        print("selftest OK (\(seen.count) bindings)")
        return 0
    }
    for failure in failures {
        FileHandle.standardError.write(Data("selftest FAILED: \(failure)\n".utf8))
    }
    return 1
}

func runTransformSelfTest() -> Int32 {
    let cases: [(String, String, String)] = [
        ("upper", "Hello world", "HELLO WORLD"),
        ("lower", "Hello World", "hello world"),
        ("title", "hello world", "Hello World"),
        ("camel", "user profile name", "userProfileName"),
        ("camel", "user_profile_name", "userProfileName"),
        ("camel", "userProfileID", "userProfileId"),
        ("pascal", "user-profile name", "UserProfileName"),
        ("snake", "userProfileName", "user_profile_name"),
        ("kebab", "userProfileName", "user-profile-name"),
        ("constant", "userProfileName", "USER_PROFILE_NAME"),
        ("sort", "b\na\nc", "a\nb\nc"),
        ("sortdesc", "a\nc\nb", "c\nb\na"),
        ("unique", "a\na\nb", "a\nb"),
        ("reverse", "a\nb\nc", "c\nb\na"),
        ("trim", "  a  \n  b  ", "a\nb"),
        ("jsonmin", "{\"a\": 1, \"b\": [2, 3]}", "{\"a\":1,\"b\":[2,3]}"),
        ("urlencode", "a b&c", "a%20b%26c"),
        ("urldecode", "a%20b", "a b"),
        ("ascii2cjk", "Hello, world! (yes)", "Hello， world！ （yes）"),
        ("cjk2ascii", "Hello， world！", "Hello, world!"),
        ("punctoggle", "Hello, world!", "Hello， world！"),
        ("punctoggle", "Hello， world！", "Hello, world!"),
        ("punctoggle", "他说：\"好的\"", "他说:\"好的\"")
    ]

    var failures = 0
    for (kind, input, expected) in cases {
        guard let output = TextTransform.apply(kind, to: input) else {
            print("FAIL \(kind): nil (unknown kind)")
            failures += 1
            continue
        }
        if output != expected {
            print("FAIL \(kind): got \(output.debugDescription) want \(expected.debugDescription)")
            failures += 1
        }
    }

    // json 类对非法输入返回 nil 是预期行为，所以只校验"未知 kind 必须被拒绝"
    if TextTransform.apply("nosuchkind", to: "x") != nil {
        print("FAIL: 未知 kind 没有被拒绝")
        failures += 1
    }

    if failures == 0 {
        print("transform selftest OK (\(cases.count) cases, \(TextTransform.kinds.count) kinds)")
        return 0
    }
    print("transform selftest FAILED: \(failures)")
    return 1
}

func runTilingSelfTest() -> Int32 {
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let window = CGRect(x: 100, y: 100, width: 400, height: 300)
    let cases: [(String, CGRect)] = [
        ("left", CGRect(x: 0, y: 0, width: 500, height: 800)),
        ("right", CGRect(x: 500, y: 0, width: 500, height: 800)),
        ("top", CGRect(x: 0, y: 0, width: 1000, height: 400)),
        ("bottom", CGRect(x: 0, y: 400, width: 1000, height: 400)),
        ("maximize", CGRect(x: 0, y: 0, width: 1000, height: 800)),
        ("center", CGRect(x: 300, y: 250, width: 400, height: 300))
    ]
    var failures = 0
    for (kind, expected) in cases {
        guard let got = WindowActions.targetRect(kind: kind, windowFrame: window, visible: visible) else {
            print("FAIL \(kind): nil")
            failures += 1
            continue
        }
        if got != expected {
            print("FAIL \(kind): got \(got) want \(expected)")
            failures += 1
        }
    }
    // 奇数宽度不能出现缝或重叠
    let odd = CGRect(x: 0, y: 0, width: 1001, height: 801)
    if let l = WindowActions.targetRect(kind: "left", windowFrame: window, visible: odd),
       let r = WindowActions.targetRect(kind: "right", windowFrame: window, visible: odd) {
        if l.maxX != r.minX || r.maxX != odd.maxX || l.width + r.width != odd.width {
            print("FAIL odd width seam: left=\(l) right=\(r) visible=\(odd)")
            failures += 1
        }
    } else {
        print("FAIL odd width: nil")
        failures += 1
    }
    if WindowActions.targetRect(kind: "diagonal", windowFrame: window, visible: visible) != nil {
        print("FAIL: 未知 kind 没有被拒绝")
        failures += 1
    }

    if failures == 0 {
        print("tiling selftest OK (\(cases.count) cases + odd width + unknown kind)")
        return 0
    }
    print("tiling selftest FAILED: \(failures)")
    return 1
}

final class PanelClampSelfTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let entry = DictEntry(source: "oalecd9", headword: "hello", phonetic: "həˈləʊ",
                              body: "verb\t打招呼\nnoun\t你好", audioBre: nil, audioAme: nil, html: nil)
        TranslatePanel.shared.show(entry: entry, audio: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let result = TranslatePanel.shared.debugForceOffscreenAndClamp() else {
                print("FAIL no screen")
                exit(1)
            }
            let inside = result.after.minY >= result.visible.minY - 0.5
                && result.after.maxY <= result.visible.maxY + 0.5
                && result.after.maxX <= result.visible.maxX + 0.5
                && result.after.minX >= result.visible.minX - 0.5
            print("before=\(result.before) after=\(result.after) visible=\(result.visible) inside=\(inside ? 1 : 0)")
            TranslatePanel.shared.dismiss()
            exit(inside ? 0 : 1)
        }
    }
}


// MARK: - AX 树形状探针
//
// 用途：某个 App"读不到选区"时，先看它到底暴露了多少节点、有没有 AXWebArea。
// Gecko（Firefox）只有在检测到无障碍客户端后才建树，构建是异步的，所以这里
// 分别在"什么都没做 / 设过 AXManualAccessibility / 设过 AXEnhancedUserInterface"之后各走一遍。
func runAXTree(bundleID: String) -> String {
    var lines: [String] = []
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        return "not-running bundle=\(bundleID)"
    }
    let pid = app.processIdentifier
    let element = AXUIElementCreateApplication(pid)
    lines.append("bundle=\(bundleID) pid=\(pid) trusted=\(AXIsProcessTrusted() ? 1 : 0)")

    func walk(_ tag: String) {
        var total = 0
        var webAreas: [String] = []
        var roles: [String: Int] = [:]
        func rec(_ node: AXUIElement, _ depth: Int) {
            guard total < 600, depth <= 8 else { return }
            total += 1
            let role = AX.stringAttribute(node, kAXRoleAttribute as CFString) ?? "?"
            roles[role, default: 0] += 1
            if role == "AXWebArea" {
                let text = AX.stringAttribute(node, kAXSelectedTextAttribute as CFString) ?? "nil"
                webAreas.append("sel=\(text.count)")
            }
            for child in AX.elementArrayAttribute(node, kAXChildrenAttribute as CFString) ?? [] {
                rec(child, depth + 1)
            }
        }
        rec(element, 0)
        let top = roles.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        lines.append("\(tag) total=\(total) webAreas=\(webAreas.count) [\(webAreas.joined(separator: ","))] roles: \(top)")
    }

    func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    walk("before")
    let manual = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    lines.append("set AXManualAccessibility=\(manual.rawValue)")
    pump(1.2)
    walk("after-manual")
    let enhanced = AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    lines.append("set AXEnhancedUserInterface=\(enhanced.rawValue)")
    pump(1.2)
    walk("after-enhanced")

    if let focused = AX.elementAttribute(element, kAXFocusedUIElementAttribute as CFString) {
        let role = AX.stringAttribute(focused, kAXRoleAttribute as CFString) ?? "?"
        let attrs = AX.attributeNames(of: focused).prefix(14).joined(separator: ",")
        lines.append("focused role=\(role) attrs=[\(attrs)]")
    } else {
        lines.append("focused=nil")
    }
    lines.append("reader=\(AX.selectedText() ?? "nil")")
    return lines.joined(separator: "\n")
}


// MARK: - 进度条组件自检
//
// 只断言几何，不比对像素：像素断言在不同缩放下必然脆。
func runProgressSelfTest() -> Int32 {
    var failures: [String] = []
    let metrics = ProgressGlyph.Metrics()
    let rect = ProgressGlyph.trackRect(in: NSRect(origin: .zero, size: metrics.size), metrics: metrics)

    func expect(_ name: String, _ condition: Bool, _ detail: String = "") {
        if !condition { failures.append("\(name) \(detail)") }
    }

    // 填充：0 也要看得见，1 正好铺满，中间值线性
    let zero = ProgressGlyph.fillRect(fraction: 0, in: rect, metrics: metrics)
    expect("fill0", zero.width == metrics.minFill && zero.minX == rect.minX, "w=\(zero.width)")
    let full = ProgressGlyph.fillRect(fraction: 1, in: rect, metrics: metrics)
    expect("fill1", abs(full.width - rect.width) < 0.001, "w=\(full.width) want=\(rect.width)")
    let half = ProgressGlyph.fillRect(fraction: 0.5, in: rect, metrics: metrics)
    expect("fillHalf", abs(half.width - rect.width / 2) < 0.001, "w=\(half.width)")
    // 超界夹紧，不能画到轨道外面
    expect("fillClampLow", ProgressGlyph.fillRect(fraction: -3, in: rect, metrics: metrics).width == metrics.minFill)
    expect("fillClampHigh", ProgressGlyph.fillRect(fraction: 9, in: rect, metrics: metrics).maxX <= rect.maxX + 0.001)

    // 滑动块：整圈都在轨道内，且首尾真的走完全程
    var outOfBounds: [Double] = []
    var phase = 0.0
    while phase <= 1.0 {
        let bar = ProgressGlyph.marqueeRect(phase: phase, in: rect, metrics: metrics)
        if bar.minX < rect.minX - 0.001 || bar.maxX > rect.maxX + 0.001 { outOfBounds.append(phase) }
        phase += 0.025
    }
    expect("marqueeBounds", outOfBounds.isEmpty, "phases=\(outOfBounds.prefix(3))")
    let start = ProgressGlyph.marqueeRect(phase: 0, in: rect, metrics: metrics)
    let nearEnd = ProgressGlyph.marqueeRect(phase: 0.999, in: rect, metrics: metrics)
    expect("marqueeStart", abs(start.minX - rect.minX) < 0.001, "x=\(start.minX)")
    expect("marqueeEnd", abs(nearEnd.maxX - rect.maxX) < 1.0, "maxX=\(nearEnd.maxX) want=\(rect.maxX)")
    // 负数相位也不能翻到左边去
    expect("marqueeNegativePhase",
           ProgressGlyph.marqueeRect(phase: -0.5, in: rect, metrics: metrics).minX >= rect.minX - 0.001)

    // 渲染冒烟：两种形态都能出图，且尺寸就是菜单栏那个尺寸
    let determinate = ProgressGlyph.image(fraction: 0.42, phase: 0)
    let indeterminate = ProgressGlyph.image(fraction: nil, phase: 0.3)
    expect("imageSize", determinate.size == metrics.size && indeterminate.size == metrics.size,
           "d=\(determinate.size) i=\(indeterminate.size)")
    expect("imagePixels", determinate.tiffRepresentation != nil && indeterminate.tiffRepresentation != nil)

    // 生命周期：句柄 end 幂等、deinit 兜底、并发时上层结束能落回下层
    let indicator = MenuBarProgressIndicator()
    let a = indicator.begin(label: "A")
    let b = indicator.begin(label: "B")
    expect("stackTwo", indicator.isActive)
    b.update(0.5)
    b.end()
    expect("stackOneAfterEnd", indicator.isActive)
    b.end()                                    // 幂等
    a.update(0.2)
    a.end()
    expect("stackEmptyAfterEnd", !indicator.isActive)
    // 拿到句柄后立刻丢掉引用：模拟"忘了 end"，应该靠 deinit 收尾
    indicator.begin(label: "C")
    expect("deinitEnds", !indicator.isActive)

    // 回归：end() 在后台队列异步收尾时，句柄可能立刻被释放。
    // 这里就是之前"转完图标卡住不变回来"的真凶：异步闭包弱持有 self，句柄一释放，finish 永远不执行。
    func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    let asyncIndicator = MenuBarProgressIndicator()
    // 生产代码的真实时序：后台队列里 begin → end，句柄随即离开作用域被释放，
    // 而 finish 还排在主线程队列上。弱引用版本在这里会丢掉收尾，图标就停在进度条上。
    DispatchQueue.global().async {
        let task = asyncIndicator.begin(label: "async")
        task.end()
    }
    pump(0.3)
    expect("asyncEndAfterRelease", !asyncIndicator.isActive)

    let leakIndicator = MenuBarProgressIndicator()
    // 拿到句柄直接丢弃：deinit 发生在后台线程，收尾同样得回到主线程
    DispatchQueue.global().async {
        _ = leakIndicator.begin(label: "doomed")
    }
    pump(0.3)
    expect("deinitOnBackgroundThread", !leakIndicator.isActive)

    if failures.isEmpty {
        print("progress selftest OK (\(9) 组几何 + \(6) 组生命周期)")
        return 0
    }
    for failure in failures { print("FAIL \(failure)") }
    return 1
}
