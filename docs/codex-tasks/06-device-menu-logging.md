# 工单 06 — 给设备下拉框装日志（定位模式被打回本机）

## 背景

用户在活动监视器里选中远端设备（ubuntu）后，过一会儿自动跳回「本机」，
`UserDefaults["systemWindow.device"]` 变回 `__local__`。

已经做过一次修复（重建菜单时把 target 置 nil + suppressDeviceAction 抑制 action），
`--device-menu-selftest` 连续重建 3 次模式稳定，但**真机上仍然会跳回**。

所以：不要继续猜根因，先把事实记录下来。**这一步只加日志，不改任何行为。**

## 要做的事

只改 `Sources/CapslockPlusMac/UI/SystemWindow.swift`（如需在 `DebugCLI.swift` 加个开关也可以）。

### 1. 一个极简的文件日志

```swift
private func debugLog(_ message: String) {
    guard UserDefaults.standard.bool(forKey: "debugDeviceMenu") else { return }
    let line = "[\(Date())] \(message)\n"
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/CapslockPlusDevice.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        try? handle.close()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
}
```

要求：
- 只有 `UserDefaults["debugDeviceMenu"] == true` 时才写（默认关，安装后我用 `defaults write` 打开）
- 文件不存在就创建；写失败不要崩、不要抛给用户
- 必须带调用栈摘要：`debugLog("xxx", stack: true)` 时追加 `Thread.callStackSymbols.prefix(8)`（每行前加 "    "）

### 2. 在这些地方打点（每处都要能看出"谁改的"）

| 位置 | 要记录的字段 |
|---|---|
| `devicePopUpChanged` 开头 | `changed target=<representedObject> suppress=<suppressDeviceAction> remote=<remoteHostname ?? "local">` + stack |
| `devicePopUpChanged` 的幂等 return 分支 | `changed noop target=<x>` |
| `switchToLocal` 入口 | `switchToLocal from=<remoteHostname ?? "local">` + stack |
| `switchToRemote` 入口 | `switchToRemote to=<hostname> from=<remoteHostname ?? "local">` + stack |
| `rebuildDeviceMenu` 入口/出口 | `rebuild start devices=<n> remote=<x>` / `rebuild end remote=<x> popup=<titleOfSelectedItem ?? "nil">` |
| `updateDeviceMenuInPlace` 入口 | `updateInPlace devices=<n> remote=<x>` |
| `menuWillOpen` / `menuDidClose` | `menuWillOpen` / `menuDidClose needsRebuild=<b>` |
| `selectCurrentInDeviceMenu` 末尾 | `select target=<x> got=<titleOfSelectedItem ?? "nil">` |
| `show()` 开头 | `show remote=<remoteHostname ?? "local"> saved=<UserDefaults systemWindow.device>` |
| `hide()` 开头 | `hide remote=<remoteHostname ?? "local">` |
| `loadDevices` 完成回调 | `devices loaded n=<count> menuOpen=<b>` / 失败时 `devices failed <summary>` |
| `fetchRemote` 的失败分支 | `fetchRemote failed <summary>` |
| 每处写 `UserDefaults["systemWindow.device"]` | `write device=<value>` + stack |

- 全部用一个小工具函数包装写 UserDefaults 那一处（`storeDevice(_:)`），避免漏点。
- 日志里**不要**记录 token、服务器地址可以记（是本机内网地址）。

### 3. 加一个命令行开关（可选但推荐）

`--device-menu-log-reset`：清空 `~/Library/Logs/CapslockPlusDevice.log` 后 exit(0)，
方便我在复现前清一次、复现后直接看新增内容。

## 约束

- 本机是 Linux，没有 macOS SDK：不要 `swift build`、不要联网
- 不要改任何现有逻辑、不要"顺手修"任何东西——这一版只观测
- 日志量大不是问题（这是临时诊断版本，定位完就撤）

## 交付总结要求

4 行以内：改了哪几处、日志文件路径、开关名字、以及你确认每一处 UserDefaults 写入都被包住了。
