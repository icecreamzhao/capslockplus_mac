import Foundation
import AppKit

enum WindowActions {
    private static var bindingsStorage: [Int: WindowBinding]?
    private static var bindings: [Int: WindowBinding]? {
        get {
            if let stored = bindingsStorage { return stored }
            let loaded = WindowStore.load()
            bindingsStorage = loaded
            Log.info("window.store loaded n=\(loaded.count)")
            return loaded
        }
        set {
            bindingsStorage = newValue
        }
    }

    static func preload() {
        _ = bindings
    }

    // MARK: - 平铺

    /// 把聚焦窗口贴到当前屏幕可视区的左/右/上/下半屏、最大化或居中。
    /// 全屏（Full Screen Space）窗口无法移动，AX 会失败，这里如实记录。
    static func tile(_ kind: String) {
        guard let windowFrame = AX.focusedWindowFrame() else {
            Log.warn("tile failed reason=no-window kind=\(kind)")
            return
        }
        guard let screen = screenContaining(windowFrame) else {
            Log.warn("tile failed reason=no-screen kind=\(kind)")
            return
        }
        let visible = axVisibleFrame(of: screen)

        guard let target = targetRect(kind: kind, windowFrame: windowFrame, visible: visible) else {
            Log.warn("tile unknown kind=\(kind)")
            return
        }

        let ok = AX.setFocusedWindowFrame(target)
        Log.info("tile \(kind.lowercased()) rect=\(Int(target.minX)),\(Int(target.minY)) \(Int(target.width))x\(Int(target.height)) ok=\(ok ? 1 : 0)")
    }

    /// 纯计算：给定窗口 frame 和屏幕可视区，算出目标 frame。便于离线校验坐标换算。
    static func targetRect(kind: String, windowFrame: CGRect, visible: CGRect) -> CGRect? {
        switch kind.lowercased() {
        case "left":
            return CGRect(x: visible.minX, y: visible.minY,
                          width: (visible.width / 2).rounded(), height: visible.height)
        case "right":
            let half = (visible.width / 2).rounded()
            return CGRect(x: visible.minX + half, y: visible.minY,
                          width: visible.width - half, height: visible.height)
        case "top":
            return CGRect(x: visible.minX, y: visible.minY,
                          width: visible.width, height: (visible.height / 2).rounded())
        case "bottom":
            let half = (visible.height / 2).rounded()
            return CGRect(x: visible.minX, y: visible.minY + half,
                          width: visible.width, height: visible.height - half)
        case "maximize":
            return visible
        case "center":
            let width = min(windowFrame.width, visible.width)
            let height = min(windowFrame.height, visible.height)
            return CGRect(
                x: visible.minX + ((visible.width - width) / 2).rounded(),
                y: visible.minY + ((visible.height - height) / 2).rounded(),
                width: width,
                height: height
            )
        default:
            return nil
        }
    }

    /// 只读：给 CLI 探针用，打印当前窗口与各平铺目标，不改任何窗口。
    static func describeTiling() -> [String] {
        guard let windowFrame = AX.focusedWindowFrame() else { return ["window=nil"] }
        guard let screen = screenContaining(windowFrame) else { return ["window=\(windowFrame) screen=nil"] }
        let visible = axVisibleFrame(of: screen)
        var lines = [
            "window=\(Int(windowFrame.minX)),\(Int(windowFrame.minY)) \(Int(windowFrame.width))x\(Int(windowFrame.height))",
            "screen=\(screen.localizedName) frame=\(Int(screen.frame.minX)),\(Int(screen.frame.minY)) \(Int(screen.frame.width))x\(Int(screen.frame.height))",
            "visible=\(Int(visible.minX)),\(Int(visible.minY)) \(Int(visible.width))x\(Int(visible.height))"
        ]
        for kind in ["left", "right", "top", "bottom", "maximize", "center"] {
            guard let rect = targetRect(kind: kind, windowFrame: windowFrame, visible: visible) else { continue }
            lines.append("\(kind)=\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))")
        }
        return lines
    }

    private static func screenContaining(_ axFrame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let primaryHeight = screens[0].frame.height
        let center = CGPoint(x: axFrame.midX, y: axFrame.midY)

        // 先找包含窗口中心的屏幕，找不到就取重叠面积最大的
        for screen in screens where axBounds(of: screen).contains(center) {
            return screen
        }
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let intersection = axBounds(of: screen).intersection(axFrame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        _ = primaryHeight
        return best ?? screens[0]
    }

    private static func axBounds(of screen: NSScreen) -> CGRect {
        flipped(screen.frame)
    }

    private static func axVisibleFrame(of screen: NSScreen) -> CGRect {
        flipped(screen.visibleFrame)
    }

    /// NSScreen 用左下原点，AX 用左上原点，转换需要主屏高度。
    private static func flipped(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func bind(_ index: Int) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            Log.warn("window.bind failed n=\(index) reason=no-frontmost-app")
            return
        }
        let appName = app.localizedName ?? bundleID
        let titleHint = AX.focusedWindowTitle() ?? ""
        var slots = bindings ?? [:]
        slots[index] = WindowBinding(
            bundleID: bundleID,
            appName: appName,
            titleHint: titleHint,
            boundAt: Date().timeIntervalSince1970
        )
        bindings = slots
        WindowStore.save(slots)
        Log.info("window.bind n=\(index) app=\(appName) title=\(titleHint) saved=ok")
    }

    static func activate(_ index: Int) {
        guard let info = bindings?[index] else {
            Log.warn("window.activate n=\(index) reason=unbound")
            return
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleID).first {
            running.activate(options: [.activateAllWindows])
            Log.info("window.activate n=\(index) app=\(info.bundleID) running=1")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                raise(index: index, pid: running.processIdentifier, hint: info.titleHint)
            }
            return
        }

        Log.info("window.launch n=\(index) app=\(info.bundleID) reason=not-running")
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: info.bundleID) else {
            Log.warn("window.launch n=\(index) failed reason=no-url")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            if let error {
                Log.warn("window.launch n=\(index) failed reason=\(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                if let running = launchedApp(bundleID: info.bundleID, fallback: app) {
                    activateLaunched(index: index, running: running, hint: info.titleHint)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        guard let running = launchedApp(bundleID: info.bundleID, fallback: app) else {
                            Log.warn("window.launch n=\(index) failed reason=not-running")
                            return
                        }
                        activateLaunched(index: index, running: running, hint: info.titleHint)
                    }
                }
            }
        }
    }

    static func statusLines() -> [(slot: Int, text: String)] {
        guard let slots = bindings else { return [] }
        return slots.keys.sorted().map { slot in
            let binding = slots[slot]!
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: binding.bundleID).first != nil
            let suffix = running ? "" : "（未运行）"
            return (slot: slot, text: "\(slot)  \(binding.appName)\(suffix)")
        }
    }

    static func clearAll() {
        bindings = [:]
        WindowStore.clear()
        Log.info("window.clear all")
    }

    private static func activateLaunched(index: Int, running: NSRunningApplication, hint: String) {
        running.activate(options: [.activateAllWindows])
        Log.info("window.launch n=\(index) ok pid=\(running.processIdentifier)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            raise(index: index, pid: running.processIdentifier, hint: hint)
        }
    }

    private static func raise(index: Int, pid: pid_t, hint: String) {
        if AX.raiseWindow(pid: pid, titleHint: hint) {
            Log.info("window.activate n=\(index) raised=1")
        } else {
            Log.warn("window.activate n=\(index) raised=0 reason=title-miss hint=\(hint)")
        }
    }

    private static func launchedApp(bundleID: String, fallback: NSRunningApplication?) -> NSRunningApplication? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running
        }
        if let fallback, fallback.processIdentifier > 0 {
            return fallback
        }
        return nil
    }
}
