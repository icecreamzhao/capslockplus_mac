import Foundation
import AppKit

private struct WindowBindingInfo {
    let bundleID: String
    let title: String?
}

enum WindowActions {
    private static var bindings: [Int: WindowBindingInfo] = [:]

    static func bind(_ index: Int) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            Log.warn("window.bind failed n=\(index) reason=no-frontmost-app")
            return
        }
        let title = AX.focusedWindowTitle()
        bindings[index] = WindowBindingInfo(bundleID: bundleID, title: title)
        Log.info("window.bind n=\(index) app=\(bundleID) title=\(title ?? "")")
    }

    static func activate(_ index: Int) {
        guard let info = bindings[index] else {
            Log.warn("window.activate n=\(index) reason=unbound")
            return
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleID).first else {
            Log.warn("window.activate n=\(index) reason=not-running app=\(info.bundleID)")
            return
        }

        let pid = running.processIdentifier
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
        Log.info("window.activate n=\(index) app=\(info.bundleID)")

        guard let title = info.title, !title.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            AX.raiseWindow(pid: pid, title: title)
        }
    }
}
