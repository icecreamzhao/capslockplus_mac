import Foundation
import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let caps = CapsState()
    private var engine: EventTapEngine?
    private var statusItem: NSStatusItem?
    private var permissionItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("app=start")
        Config.shared.loadOrCreate()
        AX.requestPermission()
        setupStatusItem()

        let engine = EventTapEngine(caps: caps)
        self.engine = engine
        if !engine.start() {
            showTapFailureAlert()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
        Log.info("app=stop")
    }

    func menuWillOpen(_ menu: NSMenu) {
        permissionItem?.title = "辅助功能权限状态：\(AX.isTrusted ? "已授权" : "未授权")"
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "capsule.portrait", accessibilityDescription: "Capslock+")
            ?? NSImage(systemSymbolName: "command", accessibilityDescription: "Capslock+")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Capslock+"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(menuItem("重载键位 (Caps+F5)", action: #selector(reloadKeymap)))
        menu.addItem(menuItem("打开键位配置", action: #selector(openKeymap)))
        menu.addItem(menuItem("打开日志", action: #selector(openLog)))

        let permission = NSMenuItem(title: "辅助功能权限状态：未知", action: nil, keyEquivalent: "")
        permission.isEnabled = false
        menu.addItem(permission)
        permissionItem = permission

        menu.addItem(.separator())
        menu.addItem(menuItem("退出", action: #selector(quit)))

        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func showTapFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "无法监听键盘事件"
        alert.informativeText = "请在「系统设置 > 隐私与安全性 > 辅助功能 / 输入监控」中允许 CapslockPlusMac，然后重新启动。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func reloadKeymap() {
        Config.shared.reload()
    }

    @objc private func openKeymap() {
        Config.shared.ensureExists()
        NSWorkspace.shared.open(Config.shared.fileURL)
    }

    @objc private func openLog() {
        Log.shared.ensureFile()
        NSWorkspace.shared.open(Log.shared.fileURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
