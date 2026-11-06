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
