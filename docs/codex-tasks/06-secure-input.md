# 工单 06 — 处理 Secure Input（密码框导致热键静默失效）

## 背景

macOS 的 Secure Input：任何 app 在密码框等敏感输入时会打开它，系统随即**不再把键盘事件投递给
event tap**。用户的表现就是"caps+f 突然没反应了"，而且我们现在的状态机可能停在 down=true，
解除后继续吞键。

Capslox 的做法（从它的 Localizable.strings 读到）：菜单栏提示
"☝️ Capslox' hotkeys is temporarily disabled due to Secure Input is turned on by the app below:"，
解除后自动恢复。我们要做同等的最小版本。

## 现状（本仓库还没有任何相关代码）

`grep -ri secureinput Sources/` 为空。需要新增。

## 要做的

新增 `Sources/CapslockPlusMac/Support/SecureInput.swift`，并改
`AppDelegate.swift`、`KeyLayer/CapsState.swift`（只加一个方法）。

### 1. `SecureInput.swift`

```swift
enum SecureInput {
    static func isEnabled() -> Bool            // IsSecureEventInputEnabled()，来自 Carbon
    static func ownerPID() -> pid_t?           // 私有 API，取不到就返回 nil
    static func ownerName() -> String?         // NSRunningApplication.localizedName
}
```

- `isEnabled`：`import Carbon` 后用 `IsSecureEventInputEnabled()`。
- `ownerPID`：`CGSessionCopyCurrentDictionary()`（私有，用 `@_silgen_name` 声明，
  返回 `Unmanaged<CFDictionary>?`），从字典里取 key `"kCGSSessionSecureInputPID"` 的整数。
  **取不到/崩溃风险要在代码里兜住**：用 `unsafeBitCast` 前先判空，失败返回 nil，不要崩。
  如果这一条实现起来不放心，可以退化成：只返回 nil，菜单里显示"某个 App"。
- `ownerName`：`NSRunningApplication(processIdentifier:)?.localizedName`。

### 2. `CapsState`

新增：

```swift
func forceReset(reason: String)   // down = false, usedAction = false，日志 "prefix reset reason=\(reason)"
```
不改其他行为。

### 3. `AppDelegate`

- 起一个 1 秒的 `Timer`（`Timer.scheduledTimer`，`tolerance = 0.2`），只在状态**变化**时做事：
  - 变 on：`Log.warn("secureInput on app=\(name ?? "?") pid=\(pid)")`；
    `caps.forceReset(reason: "secureInput")`；状态栏图标改成 `lock.fill`（取不到就用 `lock`），
    tooltip 写明"因 X 开启安全输入，热键暂停"。
  - 变 off：`Log.info("secureInput off")`；图标换回 `capsule.portrait`；
    `engine?.ensureHealthy()`（系统可能在期间禁用了 tap）。
- 菜单里加一项只读状态：`安全输入：关 / 开（XxxApp）`，`isEnabled = false`。
- `applicationWillTerminate` 里 invalidate timer。

## 日志要求

```
[W] secureInput on app=Terminal pid=1234
[I] prefix reset reason=secureInput
[I] secureInput off
```

## 验收（我在 Mac 上跑）

```
swift build -c release --arch arm64
./scripts/build.sh
./dist/CapslockPlusMac.app/Contents/MacOS/CapslockPlusMac --selftest
```
真机：终端里执行 `sudo -k; sudo ls` 触发密码框 → 日志应出现 secureInput on 且菜单栏图标变锁；
输完密码后出现 secureInput off 且 caps+f 恢复。

## 不要做

- 不要改 EventTapEngine / KeyPost / Actions/ / Config / KeyRemap / SystemEvents
- 不要引入依赖、不要联网、不要试 `swift build`（本机无工具链）
- 不要在 Timer 里做重活；私有 API 失败必须降级而不是崩溃

## 结束

3 行以内：ownerPID 用什么取的、取不到时怎么降级、Timer 在什么情况下会被 invalidate。
