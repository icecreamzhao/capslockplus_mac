import Foundation
import AppKit
import ApplicationServices

private func handleTerminationSignal(_: Int32) {
    KeyRemap.remove()
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let caps = CapsState()
    private var engine: EventTapEngine?
    private var statusItem: NSStatusItem?
    private var permissionItem: NSMenuItem?
    private var remapItem: NSMenuItem?
    private var secureInputItem: NSMenuItem?
    private var windowBindingsMenu: NSMenu?
    private var secureInputTimer: Timer?
    private var secureInputOn = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("app=start")
        installSignalHandlers()
        Config.shared.loadOrCreate()
        AX.requestPermission()
        setupStatusItem()
        startSecureInputMonitor()
        WindowActions.preload()

        let engine = EventTapEngine(caps: caps)
        self.engine = engine
        if !engine.start() {
            removeStaleRemapIfNeeded()
            showTapFailureAlert()
        } else {
            removeStaleRemapIfNeeded()
            if !KeyRemap.apply() {
                Log.error("keyremap failed")
                showRemapFailureAlert()
            }
        }

        let systemEvents = SystemEvents.shared
        systemEvents.onWake = { [weak self] in
            self?.recover(reason: "wake")
        }
        systemEvents.onHIDDeviceChange = { [weak self] in
            self?.recover(reason: "hidchange")
        }
        systemEvents.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        secureInputTimer?.invalidate()
        secureInputTimer = nil
        SystemEvents.shared.stop()
        KeyRemap.remove()
        engine?.stop()
        Log.info("app=stop")
    }

    func menuWillOpen(_ menu: NSMenu) {
        permissionItem?.title = "辅助功能权限状态：\(AX.isTrusted ? "已授权" : "未授权")"
        remapItem?.title = remapTitle
        secureInputItem?.title = secureInputTitle
        refreshWindowBindingsMenu()
    }

    private func installSignalHandlers() {
        _ = signal(SIGTERM, handleTerminationSignal)
        _ = signal(SIGINT, handleTerminationSignal)
        _ = signal(SIGHUP, handleTerminationSignal)
    }

    private func removeStaleRemapIfNeeded() {
        guard KeyRemap.isApplied() else { return }
        KeyRemap.remove()
        Log.info("keyremap stale removed")
    }

    private func recover(reason: String) {
        if reason == "wake" && !AX.isTrusted {
            Log.error("ax revoked")
            engine?.stop()
            if let engine = engine {
                let ok = engine.start()
                Log.info("tap=recreated \(ok ? "ok" : "fail")")
            }
        } else {
            engine?.ensureHealthy()
        }

        if !KeyRemap.isApplied() {
            _ = KeyRemap.apply()
            Log.info("remap reapplied reason=\(reason)")
        } else {
            Log.info("remap ok reason=\(reason)")
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = normalStatusImage()
        item.button?.image = image
        item.button?.toolTip = "Capslock+"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(menuItem("重载键位 (Caps+F5)", action: #selector(reloadKeymap)))
        menu.addItem(menuItem("打开键位配置", action: #selector(openKeymap)))
        menu.addItem(menuItem("打开日志", action: #selector(openLog)))
        let remap = menuItem("重映射 Caps→F18：未知", action: #selector(toggleRemap))
        menu.addItem(remap)
        remapItem = remap

        let permission = NSMenuItem(title: "辅助功能权限状态：未知", action: nil, keyEquivalent: "")
        permission.isEnabled = false
        menu.addItem(permission)
        permissionItem = permission

        let secureInput = NSMenuItem(title: secureInputTitle, action: nil, keyEquivalent: "")
        secureInput.isEnabled = false
        menu.addItem(secureInput)
        secureInputItem = secureInput

        let windowBindings = NSMenuItem(title: "窗口绑定", action: nil, keyEquivalent: "")
        let windowBindingsSubmenu = NSMenu(title: "窗口绑定")
        windowBindings.submenu = windowBindingsSubmenu
        menu.addItem(windowBindings)
        windowBindingsMenu = windowBindingsSubmenu

        menu.addItem(.separator())
        menu.addItem(menuItem("退出", action: #selector(quit)))

        item.menu = menu
        statusItem = item
    }

    private func refreshWindowBindingsMenu() {
        guard let submenu = windowBindingsMenu else { return }
        submenu.removeAllItems()
        let lines = WindowActions.statusLines()
        if lines.isEmpty {
            let item = NSMenuItem(
                title: "（未绑定，Caps+Option+数字 绑定当前窗口）",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            submenu.addItem(item)
        } else {
            for line in lines {
                let item = NSMenuItem(title: line.text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            }
        }
        submenu.addItem(.separator())
        submenu.addItem(menuItem("清除全部绑定", action: #selector(clearWindowBindings)))
    }

    private func startSecureInputMonitor() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.pollSecureInput()
        }
        timer.tolerance = 0.2
        secureInputTimer = timer
    }

    private func pollSecureInput() {
        let on = SecureInput.isEnabled()
        guard on != secureInputOn else { return }
        secureInputOn = on
        secureInputItem?.title = secureInputTitle

        if on {
            let name = SecureInput.ownerName()
            let pid = SecureInput.ownerPID() ?? 0
            Log.warn("secureInput on app=\(name ?? "?") pid=\(pid)")
            caps.forceReset(reason: "secureInput")
            let image = statusImage(["lock.fill", "lock"], description: "安全输入")
            statusItem?.button?.image = image
            statusItem?.button?.toolTip = "因 \(name ?? "某个 App") 开启安全输入，热键暂停"
        } else {
            Log.info("secureInput off")
            let image = normalStatusImage()
            statusItem?.button?.image = image
            statusItem?.button?.toolTip = "Capslock+"
            engine?.ensureHealthy()
        }
    }

    private func normalStatusImage() -> NSImage? {
        if let path = Bundle.main.path(forResource: "MenuCat", ofType: "pdf") {
            if let image = NSImage(contentsOfFile: path) {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                return image
            }
            Log.warn("menuIcon fallback reason=loadFailed path=\(path)")
        } else {
            Log.warn("menuIcon fallback reason=resourceMissing name=MenuCat.pdf")
        }

        let image = statusImage(["cat.fill", "capsule.portrait", "command"], description: "Capslock+")
        if image == nil {
            Log.warn("menuIcon fallback reason=symbolMissing")
        }
        return image
    }

    private func statusImage(_ names: [String], description: String) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                return image
            }
        }
        return nil
    }

    private var secureInputTitle: String {
        guard secureInputOn else { return "安全输入：关" }
        return "安全输入：开（\(SecureInput.ownerName() ?? "某个 App")）"
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

    private func showRemapFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "无法把 Caps Lock 重映射为 F18"
        alert.informativeText = "请在终端执行 scripts/keyremap.sh on，或手动运行 hidutil，然后重新启动。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private var remapTitle: String {
        "重映射 Caps→F18：\(KeyRemap.isApplied() ? "开" : "关")"
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

    @objc private func toggleRemap() {
        if KeyRemap.isApplied() {
            KeyRemap.remove()
        } else if !KeyRemap.apply() {
            Log.error("keyremap failed")
        }
        remapItem?.title = remapTitle
    }

    @objc private func clearWindowBindings() {
        WindowActions.clearAll()
        refreshWindowBindingsMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
